#!/usr/bin/env python3
"""
Hermes ↔ 手机节点 MCP 桥接服务器 (v2 — 持久连接方案)

架构:
  Hermes Agent  ←→  本桥接器 (MCP stdio + WS Client)  ←→  手机 App (WS Server)

v2 改进: 启动时立即连接手机并保持长连接，手机端可实时感知桥接状态。

配置方式 (config.yaml):
  mcp_servers:
    phone_companion:
      command: "python3"
      args: ["/root/.hermes/scripts/phone_bridge_mcp_server.py"]
      env:
        PHONE_WS_URL: "ws://127.0.0.1:18790"
      timeout: 60
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from typing import Any

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# 配置（可通过环境变量覆盖）
# ---------------------------------------------------------------------------
PHONE_WS_URL = os.getenv("PHONE_WS_URL", "ws://127.0.0.1:18790")
PHONE_WS_TOKEN = os.getenv("PHONE_WS_TOKEN", "")
CONNECT_TIMEOUT = float(os.getenv("PHONE_CONNECT_TIMEOUT", "10"))
CALL_TIMEOUT = float(os.getenv("PHONE_CALL_TIMEOUT", "30"))
RECONNECT_DELAY = float(os.getenv("PHONE_RECONNECT_DELAY", "3"))
MAX_RECONNECT_DELAY = float(os.getenv("PHONE_MAX_RECONNECT_DELAY", "30"))

# ---------------------------------------------------------------------------
# MCP 工具定义
# ---------------------------------------------------------------------------
TOOL_DEFS: dict[str, dict[str, Any]] = {
    # ── Camera ──────────────────────────────────────────────
    "camera_snap": {
        "command": "camera.snap",
        "description": "用手机摄像头拍一张照片",
        "schema": {
            "type": "object",
            "properties": {
                "camera": {
                    "type": "string",
                    "enum": ["back", "front"],
                    "description": "摄像头：后置(back) 或 前置(front)",
                    "default": "back",
                }
            },
        },
        "transform": lambda a: {"camera": a.get("camera", "back")},
    },
    "camera_list": {
        "command": "camera.list",
        "description": "列出手机所有可用的摄像头",
        "schema": {"type": "object", "properties": {}},
    },
    "camera_clip": {
        "command": "camera.clip",
        "description": "录制一段短视频",
        "schema": {
            "type": "object",
            "properties": {
                "camera": {
                    "type": "string",
                    "enum": ["back", "front"],
                    "default": "back",
                },
                "duration": {
                    "type": "integer",
                    "description": "录制时长（秒）",
                    "default": 10,
                },
            },
        },
        "transform": lambda a: {"camera": a.get("camera", "back"), "duration": a.get("duration", 10)},
    },
    # ── Canvas ──────────────────────────────────────────────
    "canvas_navigate": {
        "command": "canvas.navigate",
        "description": "在手机浏览器中打开一个 URL",
        "schema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "要打开的网址"},
            },
            "required": ["url"],
        },
        "transform": lambda a: {"url": a["url"]},
    },
    "canvas_eval": {
        "command": "canvas.eval",
        "description": "在手机浏览器中执行 JavaScript 代码",
        "schema": {
            "type": "object",
            "properties": {
                "code": {"type": "string", "description": "要执行的 JavaScript"},
            },
            "required": ["code"],
        },
        "transform": lambda a: {"code": a["code"]},
    },
    "canvas_snapshot": {
        "command": "canvas.snapshot",
        "description": "截图手机浏览器当前页面",
        "schema": {"type": "object", "properties": {}},
    },
    # ── Flash ───────────────────────────────────────────────
    "flash_on": {
        "command": "flash.on",
        "description": "打开手机闪光灯/手电筒",
        "schema": {"type": "object", "properties": {}},
    },
    "flash_off": {
        "command": "flash.off",
        "description": "关闭手机闪光灯/手电筒",
        "schema": {"type": "object", "properties": {}},
    },
    "flash_toggle": {
        "command": "flash.toggle",
        "description": "切换手机闪光灯开关状态",
        "schema": {"type": "object", "properties": {}},
    },
    "flash_status": {
        "command": "flash.status",
        "description": "查询手机闪光灯当前状态",
        "schema": {"type": "object", "properties": {}},
    },
    # ── Location ────────────────────────────────────────────
    "location_get": {
        "command": "location.get",
        "description": "获取手机当前 GPS 位置",
        "schema": {"type": "object", "properties": {}},
    },
    # ── Screen ──────────────────────────────────────────────
    "screen_record": {
        "command": "screen.record",
        "description": "录制手机屏幕",
        "schema": {
            "type": "object",
            "properties": {
                "duration": {"type": "integer", "default": 30},
                "show_taps": {"type": "boolean", "default": True},
            },
        },
        "transform": lambda a: {"duration": a.get("duration", 30), "show_taps": a.get("show_taps", True)},
    },
    # ── Sensors ─────────────────────────────────────────────
    "sensor_list": {
        "command": "sensor.list",
        "description": "列出手机所有可用的传感器",
        "schema": {"type": "object", "properties": {}},
    },
    "sensor_read": {
        "command": "sensor.read",
        "description": "读取指定的手机传感器数据",
        "schema": {
            "type": "object",
            "properties": {
                "sensor": {"type": "string", "default": "accelerometer"},
            },
        },
        "transform": lambda a: {"sensor": a.get("sensor", "accelerometer")},
    },
    # ── Haptic ──────────────────────────────────────────────
    "haptic_vibrate": {
        "command": "haptic.vibrate",
        "description": "触发手机震动",
        "schema": {
            "type": "object",
            "properties": {
                "duration_ms": {"type": "integer", "default": 200},
                "pattern": {
                    "type": "array",
                    "items": {"type": "integer"},
                },
            },
        },
        "transform": lambda a: {"duration_ms": a.get("duration_ms", 200), "pattern": a.get("pattern")},
    },
    # ── Serial ──────────────────────────────────────────────
    "serial_list": {
        "command": "serial.list",
        "description": "列出手机可用的串行端口",
        "schema": {"type": "object", "properties": {}},
    },
    "serial_connect": {
        "command": "serial.connect",
        "description": "连接手机串行端口",
        "schema": {
            "type": "object",
            "properties": {
                "port": {"type": "string"},
                "baud_rate": {"type": "integer", "default": 9600},
            },
            "required": ["port"],
        },
        "transform": lambda a: {"port": a["port"], "baud_rate": a.get("baud_rate", 9600)},
    },
    "serial_disconnect": {
        "command": "serial.disconnect",
        "description": "断开手机串行端口连接",
        "schema": {
            "type": "object",
            "properties": {"port": {"type": "string"}},
            "required": ["port"],
        },
        "transform": lambda a: {"port": a["port"]},
    },
    "serial_write": {
        "command": "serial.write",
        "description": "向串行端口写入数据",
        "schema": {
            "type": "object",
            "properties": {
                "port": {"type": "string"},
                "data": {"type": "string"},
            },
            "required": ["port", "data"],
        },
        "transform": lambda a: {"port": a["port"], "data": a["data"]},
    },
    "serial_read": {
        "command": "serial.read",
        "description": "从串行端口读取数据",
        "schema": {
            "type": "object",
            "properties": {
                "port": {"type": "string"},
                "timeout": {"type": "number", "default": 5.0},
            },
            "required": ["port"],
        },
        "transform": lambda a: {"port": a["port"], "timeout": a.get("timeout", 5.0)},
    },
}


# ---------------------------------------------------------------------------
# WS 客户端（连接手机 App）— v2 持久连接
# ---------------------------------------------------------------------------

class PhoneWsClient:
    """
    WebSocket 客户端，连接手机 App 的命令端口。
    v2: 启动时立即连接，保持长连接，自动重连。
    """

    def __init__(self) -> None:
        self._ws: Any = None
        self._lock = asyncio.Lock()
        self._connected_event = asyncio.Event()
        self._reconnect_task: asyncio.Task | None = None
        self._stop_reconnect = False

    @property
    def is_connected(self) -> bool:
        return self._ws is not None

    async def connect_and_stay(self) -> None:
        """启动时立即连接手机，并保持长连接（自动重连）。"""
        self._stop_reconnect = False
        await self._do_connect()
        # 启动后台重连任务
        self._reconnect_task = asyncio.create_task(self._reconnect_loop())

    async def _do_connect(self) -> bool:
        """尝试连接手机。成功返回 True。"""
        try:
            import websockets
            logger.info("Connecting to phone app at %s ...", PHONE_WS_URL)
            ws = await asyncio.wait_for(
                websockets.connect(PHONE_WS_URL, ping_interval=20, ping_timeout=10),
                timeout=CONNECT_TIMEOUT,
            )
            # 发送 hello 消息，告知手机桥接器已连接
            await ws.send(json.dumps({
                "type": "bridge.hello",
                "id": "hello",
                "payload": {"source": "gateway-bridge"},
            }))
            self._ws = ws
            self._connected_event.set()
            logger.info("Phone app connected!")
            return True
        except Exception as e:
            logger.warning("Failed to connect to phone: %s", e)
            self._ws = None
            self._connected_event.clear()
            return False

    async def _reconnect_loop(self) -> None:
        """后台重连循环：连接断开时自动重连。"""
        delay = RECONNECT_DELAY
        while not self._stop_reconnect:
            # 等待连接断开
            if self._ws is not None:
                try:
                    # 检测连接是否还活着
                    await asyncio.wait_for(self._ws.ping(), timeout=5)
                    await asyncio.sleep(5)
                    continue
                except Exception:
                    logger.warning("Phone connection lost, reconnecting...")
                    self._ws = None
                    self._connected_event.clear()

            # 尝试重连
            if await self._do_connect():
                delay = RECONNECT_DELAY  # 重置延迟
            else:
                delay = min(delay * 1.5, MAX_RECONNECT_DELAY)
            await asyncio.sleep(delay)

    async def close(self) -> None:
        self._stop_reconnect = True
        if self._reconnect_task:
            self._reconnect_task.cancel()
        ws, self._ws = self._ws, None
        if ws is not None:
            try:
                await ws.close()
            except Exception:
                pass
        self._connected_event.clear()

    async def call(self, command: str, payload: dict[str, Any]) -> dict[str, Any]:
        """发送命令并等待响应。"""
        req_id = uuid.uuid4().hex
        request = {
            "type": command,
            "id": req_id,
            "payload": payload,
        }
        if PHONE_WS_TOKEN:
            request["token"] = PHONE_WS_TOKEN

        async with self._lock:
            if self._ws is None:
                raise ConnectionError("Phone not connected")
            await self._ws.send(json.dumps(request, separators=(",", ":"), ensure_ascii=False))

            response = await asyncio.wait_for(
                self._ws.recv(), timeout=CALL_TIMEOUT,
            )
            if isinstance(response, bytes):
                response = response.decode("utf-8")

        msg = json.loads(response)

        if msg.get("type") == "error":
            raise RuntimeError(f"Phone error for {command}: {msg.get('error', 'unknown')}")
        if msg.get("id") != req_id:
            logger.warning("Mismatched response id: expected %s, got %s", req_id, msg.get("id"))

        return msg.get("payload", {})


# ---------------------------------------------------------------------------
# MCP Server + 桥接主类
# ---------------------------------------------------------------------------

class PhoneNodeBridge:

    def __init__(self) -> None:
        self._phone = PhoneWsClient()

    async def run(self) -> None:
        import mcp.types as types
        from mcp.server.lowlevel import Server as LowLevelServer
        from mcp.server.stdio import stdio_server

        server = LowLevelServer("phone-companion")

        @server.list_tools()
        async def list_tools() -> list[types.Tool]:
            return [
                types.Tool(
                    name=name,
                    description=tdef["description"],
                    inputSchema=tdef["schema"],
                )
                for name, tdef in TOOL_DEFS.items()
            ]

        @server.call_tool()
        async def call_tool(name: str, arguments: dict[str, Any]) -> list[types.TextContent | types.ImageContent]:
            tdef = TOOL_DEFS.get(name)
            if tdef is None:
                raise ValueError(f"Unknown tool: {name}")

            command = tdef["command"]
            transform = tdef.get("transform")
            params = transform(arguments) if transform else (arguments or {})

            if not self._phone.is_connected:
                return [types.TextContent(
                    type="text",
                    text=json.dumps({
                        "error": "NO_PHONE_CONNECTED",
                        "message": f"无法连接手机 App ({PHONE_WS_URL}): 桥接器未连接到手机",
                    }, ensure_ascii=False),
                )]

            try:
                result = await self._phone.call(command, params)
            except RuntimeError as e:
                return [types.TextContent(
                    type="text",
                    text=json.dumps({"error": "CALL_FAILED", "message": str(e)}, ensure_ascii=False),
                )]
            except ConnectionError:
                return [types.TextContent(
                    type="text",
                    text=json.dumps({
                        "error": "DISCONNECTED",
                        "message": "手机 App 连接断开",
                    }, ensure_ascii=False),
                )]

            # 相机/截图 → 图片
            if command in ("camera.snap", "canvas.snapshot"):
                image_b64 = result.get("image") or result.get("data")
                if image_b64:
                    mime = result.get("mime", "image/jpeg")
                    return [types.ImageContent(type="image", data=image_b64, mimeType=mime)]

            return [types.TextContent(
                type="text",
                text=json.dumps(result, ensure_ascii=False, default=str),
            )]

        # ★ v2: 启动时立即连接手机（后台任务，不阻塞 MCP server 启动）
        asyncio.create_task(self._phone.connect_and_stay())
        logger.info("Phone bridge starting, connecting to %s ...", PHONE_WS_URL)

        async with stdio_server() as (read_stream, write_stream):
            logger.info("MCP stdio server ready")
            await server.run(read_stream, write_stream, server.create_initialization_options())


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )
    try:
        asyncio.run(PhoneNodeBridge().run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
