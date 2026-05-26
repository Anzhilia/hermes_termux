"""
MCP Adapter for Node Capabilities

Exposes connected node (phone app) commands as MCP tools so Hermes Agent
can invoke camera, location, screen, etc. through the standard MCP protocol.

Usage in config.yaml:
  mcp_servers:
    phone_node:
      command: python3
      args: ["/root/.hermes/scripts/node_mcp_adapter.py"]
      env:
        NODE_WS_URL: "ws://127.0.0.1:18780"
        NODE_AUTH_TOKEN: "<token>"
      timeout: 60
"""

from __future__ import annotations

import asyncio
import json
import os
import socket
import sys
import logging
import time

logger = logging.getLogger(__name__)

# ── websockets import (兼容 v11 ~ v14+) ──────────────────────────────────────
try:
    import websockets
    _WS_VERSION = tuple(int(x) for x in websockets.__version__.split(".")[:2])
    logger.info(f"websockets version: {websockets.__version__} (parsed: {_WS_VERSION})")
except ImportError:
    print(
        "ERROR: websockets package required. Install:\n"
        "  /root/.hermes/hermes-agent/venv/bin/pip install websockets",
        file=sys.stderr,
    )
    sys.exit(1)

NODE_WS_URL = os.getenv("NODE_WS_URL", "ws://127.0.0.1:18780")
NODE_AUTH_TOKEN = os.getenv("NODE_AUTH_TOKEN", "")
CONNECT_TIMEOUT = float(os.getenv("NODE_CONNECT_TIMEOUT", "15"))
INVOKE_TIMEOUT = float(os.getenv("NODE_INVOKE_TIMEOUT", "30"))
# Retry settings for initial connection (node_ws_server may start after gateway)
CONNECT_RETRIES = int(os.getenv("NODE_CONNECT_RETRIES", "50"))
CONNECT_RETRY_DELAY = float(os.getenv("NODE_CONNECT_RETRY_DELAY", "2"))
# How long to wait for WS server port to become available (seconds)
PORT_WAIT_TIMEOUT = float(os.getenv("NODE_PORT_WAIT_TIMEOUT", "90"))
# Startup handshake timeout
HANDSHAKE_TIMEOUT = float(os.getenv("NODE_HANDSHAKE_TIMEOUT", "15"))


def _wait_for_port(host: str, port: int, timeout: float) -> bool:
    """Block until a TCP port is accepting connections, or timeout."""
    deadline = time.monotonic() + timeout
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        try:
            with socket.create_connection((host, port), timeout=3):
                logger.info(f"Port {host}:{port} is ready (attempt {attempt})")
                return True
        except (OSError, ConnectionRefusedError) as e:
            if attempt <= 3 or attempt % 10 == 0:
                logger.info(f"Port {host}:{port} not ready (attempt {attempt}): {e}")
            time.sleep(1)
    logger.error(f"Port {host}:{port} not ready after {timeout}s ({attempt} attempts)")
    return False


# Tool definitions matching the node's capability commands
TOOL_DEFS: dict[str, dict] = {
    "camera_snap": {
        "command": "camera.snap",
        "description": "Take a photo with the phone camera",
        "schema": {
            "type": "object",
            "properties": {
                "camera": {
                    "type": "string",
                    "enum": ["back", "front"],
                    "description": "Camera: back or front",
                    "default": "back",
                }
            },
        },
    },
    "location_get": {
        "command": "location.get",
        "description": "Get current GPS location of the phone",
        "schema": {"type": "object", "properties": {}},
    },
    "screen_share": {
        "command": "screen.share",
        "description": "Capture phone screen",
        "schema": {"type": "object", "properties": {}},
    },
    "flash_toggle": {
        "command": "flash.toggle",
        "description": "Toggle phone flashlight",
        "schema": {
            "type": "object",
            "properties": {
                "on": {"type": "boolean", "description": "Turn on or off"},
            },
        },
    },
    "vibration_trigger": {
        "command": "vibration.trigger",
        "description": "Make the phone vibrate",
        "schema": {"type": "object", "properties": {}},
    },
    "sensor_read": {
        "command": "sensor.read",
        "description": "Read phone sensors (accelerometer, gyroscope, etc.)",
        "schema": {"type": "object", "properties": {}},
    },
}


class NodeMcpAdapter:
    """Connects to the node WS server and forwards MCP tool calls."""

    def __init__(self):
        self._ws = None
        self._connected = False
        self._commands: list[str] = []

    async def connect(self):
        """Connect to the node WS server and register as a pseudo-node.

        Retries up to CONNECT_RETRIES times with CONNECT_RETRY_DELAY between
        attempts, because the node_ws_server may start after the gateway.
        """
        last_error = None
        for attempt in range(1, CONNECT_RETRIES + 1):
            try:
                logger.info(
                    f"MCP adapter connecting to {NODE_WS_URL} "
                    f"(attempt {attempt}/{CONNECT_RETRIES})"
                )

                # Use websockets.connect() — works across v11 ~ v16+
                # v13+: connect() returns an async context manager
                # v11-12: connect() returns an awaitable
                ws_ctx = websockets.connect(
                    NODE_WS_URL,
                    ping_interval=30,
                    ping_timeout=10,
                    close_timeout=5,
                )
                # Try async context manager first (v13+), then fallback
                try:
                    self._ws = await asyncio.wait_for(
                        ws_ctx.__aenter__(),
                        timeout=CONNECT_TIMEOUT,
                    )
                    # Store context manager for proper cleanup
                    self._ws_ctx = ws_ctx
                except AttributeError:
                    # Older websockets: connect() is directly awaitable
                    self._ws = await asyncio.wait_for(
                        ws_ctx,
                        timeout=CONNECT_TIMEOUT,
                    )
                    self._ws_ctx = None

                # Wait for challenge
                logger.info("Waiting for challenge from WS server...")
                raw = await asyncio.wait_for(self._ws.recv(), timeout=HANDSHAKE_TIMEOUT)
                challenge = json.loads(raw)
                nonce = challenge.get("payload", {}).get("nonce", "")
                logger.info(f"Received challenge (nonce={nonce[:8]}...)")

                # Send connect (use auth token if available)
                connect_payload = {
                    "type": "request",
                    "id": "mcp-connect",
                    "request": "connect",
                    "payload": {
                        "minProtocol": 3,
                        "maxProtocol": 3,
                        "client": {
                            "id": "node-mcp-adapter",
                            "displayName": "Node MCP Adapter",
                            "version": "1.0.0",
                            "platform": "mcp",
                            "mode": "node",
                        },
                        "role": "node",
                        "scopes": ["node.device"],
                        "caps": [],
                        "commands": [],
                        "auth": {"token": NODE_AUTH_TOKEN} if NODE_AUTH_TOKEN else {},
                        "device": {
                            "id": "mcp-adapter",
                            "publicKey": "",
                            "signature": "",
                            "nonce": nonce,
                            "signedAt": 0,
                        },
                    },
                }
                await self._ws.send(json.dumps(connect_payload))
                logger.info("Sent connect request, waiting for response...")

                # Wait for response
                raw = await asyncio.wait_for(self._ws.recv(), timeout=HANDSHAKE_TIMEOUT)
                response = json.loads(raw)
                if response.get("ok"):
                    self._connected = True
                    logger.info(
                        f"✓ MCP adapter connected to node server "
                        f"(attempt {attempt}, websockets {websockets.__version__})"
                    )
                    return
                else:
                    error = response.get("error", {})
                    logger.error(f"MCP adapter connect rejected: {error}")
                    last_error = str(error)
                    await self._cleanup_ws()

            except asyncio.TimeoutError as e:
                last_error = f"Timeout: {e}"
                logger.warning(
                    f"MCP adapter connection attempt {attempt} timed out: {e}"
                )
                await self._cleanup_ws()
            except ConnectionRefusedError as e:
                last_error = f"ConnectionRefused: {e}"
                logger.warning(
                    f"MCP adapter connection attempt {attempt} refused: {e}"
                )
                await self._cleanup_ws()
            except OSError as e:
                last_error = f"OSError: {e}"
                logger.warning(
                    f"MCP adapter connection attempt {attempt} OS error: {e}"
                )
                await self._cleanup_ws()
            except Exception as e:
                last_error = f"{type(e).__name__}: {e}"
                logger.warning(
                    f"MCP adapter connection attempt {attempt} failed: "
                    f"{type(e).__name__}: {e}"
                )
                await self._cleanup_ws()

            # Wait before retry (except on last attempt)
            if attempt < CONNECT_RETRIES:
                delay = min(CONNECT_RETRY_DELAY * (1 + attempt * 0.1), 10)
                logger.info(f"Retrying in {delay:.1f}s...")
                await asyncio.sleep(delay)

        logger.error(
            f"MCP adapter connection failed after {CONNECT_RETRIES} attempts: {last_error}"
        )
        self._connected = False

    async def _cleanup_ws(self):
        """Safely close WebSocket connection."""
        if self._ws:
            try:
                if hasattr(self, '_ws_ctx') and self._ws_ctx is not None:
                    await self._ws_ctx.__aexit__(None, None, None)
                else:
                    await self._ws.close()
            except Exception:
                pass
            self._ws = None
            self._ws_ctx = None

    async def invoke(self, command: str, params: dict | None = None) -> dict:
        """Invoke a command on the connected node via the WS server."""
        if not self._connected or not self._ws:
            raise RuntimeError("Not connected to node server")

        invoke_id = f"mcp-inv-{id(command)}"
        payload = {
            "id": invoke_id,
            "nodeId": "*",  # Let server pick any node with this command
            "command": command,
            "paramsJSON": json.dumps(params or {}),
            "timeoutMs": int(INVOKE_TIMEOUT * 1000),
        }

        await self._ws.send(json.dumps({
            "type": "event",
            "event": "node.invoke.request",
            "payload": payload,
        }))

        # Wait for invoke result
        deadline = asyncio.get_event_loop().time() + INVOKE_TIMEOUT
        while asyncio.get_event_loop().time() < deadline:
            try:
                raw = await asyncio.wait_for(self._ws.recv(), timeout=INVOKE_TIMEOUT)
                msg = json.loads(raw)
                if msg.get("request") == "node.invoke.result":
                    result = msg.get("payload", {})
                    if result.get("id") == invoke_id:
                        if result.get("ok") is False:
                            raise RuntimeError(
                                result.get("error", {}).get("message", "Invoke failed")
                            )
                        # Parse payloadJSON
                        payload_json = result.get("payloadJSON")
                        if payload_json:
                            return json.loads(payload_json)
                        return result
            except asyncio.TimeoutError:
                raise RuntimeError(f"Invoke timed out: {command}")

        raise RuntimeError(f"Invoke timed out: {command}")

    async def disconnect(self):
        await self._cleanup_ws()
        self._connected = False


# ── MCP stdio protocol handler ──────────────────────────────────────────────

async def run_mcp_server():
    """Run the MCP stdio server, forwarding tool calls to the node."""
    # Parse host:port from NODE_WS_URL for port-readiness check
    try:
        from urllib.parse import urlparse
        parsed = urlparse(NODE_WS_URL)
        ws_host = parsed.hostname or "127.0.0.1"
        ws_port = parsed.port or 18780
    except Exception:
        ws_host, ws_port = "127.0.0.1", 18780

    # Step 0: Wait for WS server port to be reachable (blocking, in thread)
    logger.info(
        f"Waiting for WS server at {ws_host}:{ws_port} "
        f"(timeout {PORT_WAIT_TIMEOUT}s)..."
    )
    loop = asyncio.get_event_loop()
    port_ready = await loop.run_in_executor(
        None, _wait_for_port, ws_host, ws_port, PORT_WAIT_TIMEOUT
    )
    if not port_ready:
        print(
            f"ERROR: WS server port {ws_host}:{ws_port} not reachable "
            f"after {PORT_WAIT_TIMEOUT}s",
            file=sys.stderr,
        )
        sys.exit(1)
    logger.info(f"WS server port {ws_host}:{ws_port} is ready")

    # Small delay to ensure WS server is fully initialized (not just port open)
    await asyncio.sleep(0.5)

    adapter = NodeMcpAdapter()
    await adapter.connect()

    if not adapter._connected:
        print(
            "ERROR: Failed to connect to node WS server after retries.\n"
            "Check: /tmp/node_ws_server.log",
            file=sys.stderr,
        )
        sys.exit(1)

    # Read MCP requests from stdin, write responses to stdout
    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader()
    try:
        await loop.connect_read_pipe(
            lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer
        )
    except Exception as e:
        logger.warning(f"connect_read_pipe failed ({e}), falling back to sys.stdin reads")
        reader = None

    tool_names = list(TOOL_DEFS.keys())

    async def handle_request(request: dict) -> dict:
        method = request.get("method", "")
        req_id = request.get("id")

        if method == "initialize":
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "hermes-node-bridge", "version": "1.0.0"},
                },
            }

        if method == "tools/list":
            tools = []
            for name, defn in TOOL_DEFS.items():
                tools.append({
                    "name": name,
                    "description": defn["description"],
                    "inputSchema": defn["schema"],
                })
            return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": tools}}

        if method == "tools/call":
            params = request.get("params", {})
            tool_name = params.get("name", "")
            arguments = params.get("arguments", {})

            tool_def = TOOL_DEFS.get(tool_name)
            if not tool_def:
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": f"Unknown tool: {tool_name}"}],
                        "isError": True,
                    },
                }

            try:
                result = await adapter.invoke(tool_def["command"], arguments)
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"content": [{"type": "text", "text": json.dumps(result)}]},
                }
            except Exception as e:
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"content": [{"type": "text", "text": str(e)}], "isError": True},
                }

        # Unknown method
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Unknown method: {method}"},
        }

    # Process stdin line by line (MCP stdio protocol uses JSON-RPC)
    logger.info("MCP adapter ready, waiting for requests on stdin...")
    buffer = ""
    while True:
        try:
            if reader is not None:
                line = await reader.readline()
            else:
                # Fallback: read from stdin in executor to avoid blocking
                line = await loop.run_in_executor(None, sys.stdin.buffer.readline)
            if not line:
                break
            buffer += line.decode("utf-8")
            # MCP messages are newline-delimited JSON
            while "\n" in buffer:
                line_str, buffer = buffer.split("\n", 1)
                line_str = line_str.strip()
                if not line_str:
                    continue
                try:
                    request = json.loads(line_str)
                    response = await handle_request(request)
                    sys.stdout.write(json.dumps(response) + "\n")
                    sys.stdout.flush()
                except json.JSONDecodeError:
                    pass
        except Exception as e:
            logger.error(f"MCP server error: {e}")
            break

    await adapter.disconnect()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )
    asyncio.run(run_mcp_server())
