package com.nousresearch.hermes

import android.os.Handler
import android.os.Looper
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * Manages the node WS server as a persistent proot process.
 *
 * Unlike runInProot (synchronous, kills child on exit), this keeps
 * the WS server running as a long-lived background process — the same
 * approach used by GatewayService for `hermes gateway run`.
 *
 * Architecture:
 *   NodeWsServerManager.start() → proot → python node_ws_server.py
 *                                   ↓
 *   Flutter (NodeWsService) ──→ ws://127.0.0.1:18780 ←── Phone App
 */
object NodeWsServerManager {

    private var process: Process? = null
    private var watchdogThread: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private const val READY_FILE = "/tmp/node_ws_server.ready"
    private const val LOG_FILE = "/tmp/node_ws_server.log"
    private const val PORT = 18780

    @Volatile
    var isRunning = false
        private set

    /**
     * Start the WS server as a persistent proot process.
     * Returns true if the process was spawned (port readiness is async).
     */
    fun start(filesDir: String, nativeLibDir: String): Boolean {
        if (isRunning && process?.isAlive == true) {
            return true
        }

        // Kill any existing instance
        stop(filesDir, nativeLibDir)

        val pm = ProcessManager(filesDir, nativeLibDir)

        // Build command: ensure websockets installed, then start server
        val cmd = buildString {
            append("pkill -f node_ws_server.py 2>/dev/null; ")
            append("sleep 0.5; ")
            append("rm -f $READY_FILE; ")
            // Ensure websockets is installed
            append("/root/.hermes/hermes-agent/venv/bin/python -c 'import websockets' 2>/dev/null ")
            append("|| /root/.hermes/hermes-agent/venv/bin/pip install websockets -q 2>/dev/null; ")
            // Start the WS server (foreground in this proot session)
            append("exec /root/.hermes/hermes-agent/venv/bin/python ")
            append("/root/.hermes/scripts/node_ws_server.py")
        }

        try {
            process = pm.startProotProcess(cmd)
            isRunning = true

            // Start watchdog to detect crashes
            startWatchdog()

            return true
        } catch (e: Exception) {
            isRunning = false
            return false
        }
    }

    /**
     * Stop the WS server process.
     */
    fun stop(filesDir: String, nativeLibDir: String) {
        isRunning = false
        watchdogThread?.interrupt()
        watchdogThread = null

        val proc = process ?: run {
            // Even if we don't have a process reference, try killing by pattern
            killByPattern(filesDir, nativeLibDir)
            return
        }

        try {
            val pm = ProcessManager(filesDir, nativeLibDir)
            pm.killProcessTree(proc, force = false)
        } catch (e: Exception) {
            try { proc.destroyForcibly() } catch (_: Exception) {}
        }

        try { proc.waitFor(3, java.util.concurrent.TimeUnit.SECONDS) } catch (_: Exception) {}
        process = null

        // Clean up residual
        killByPattern(filesDir, nativeLibDir)
    }

    /**
     * Check if the WS server process is alive.
     */
    fun isProcessAlive(): Boolean {
        val proc = process
        if (proc != null && proc.isAlive) return true
        // Also check via port probe as fallback
        return isPortListening()
    }

    /**
     * Check if the WS server port is accepting connections.
     */
    private fun isPortListening(): Boolean {
        return try {
            java.net.Socket().use { socket ->
                socket.connect(java.net.InetSocketAddress("127.0.0.1", PORT), 1000)
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Wait for the WS server port to become ready.
     * Returns true if port is listening within timeout.
     */
    fun waitForPort(timeoutMs: Long = 15000): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (isPortListening()) return true
            Thread.sleep(300)
        }
        return false
    }

    private fun startWatchdog() {
        watchdogThread?.interrupt()
        watchdogThread = Thread {
            try {
                // Wait 10s before first check — give server time to start
                Thread.sleep(10_000)
                while (isRunning) {
                    val proc = process
                    if (proc != null && !proc.isAlive) {
                        isRunning = false
                        break
                    }
                    Thread.sleep(10_000)
                }
            } catch (_: InterruptedException) {}
        }.apply { isDaemon = true; start() }
    }

    private fun killByPattern(filesDir: String, nativeLibDir: String) {
        try {
            val pm = ProcessManager(filesDir, nativeLibDir)
            val killProcess = pm.startProotProcess(
                "pkill -f node_ws_server.py 2>/dev/null; true"
            )
            killProcess.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)
        } catch (_: Exception) {}
    }
}
