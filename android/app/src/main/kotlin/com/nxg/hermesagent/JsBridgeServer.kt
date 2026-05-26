package com.nousresearch.hermes

import android.util.Log
import org.java_websocket.WebSocket
import org.java_websocket.handshake.ClientHandshake
import org.java_websocket.server.WebSocketServer
import org.json.JSONObject
import java.net.InetSocketAddress
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * JS Bridge WebSocket Server — 从 control-app (EventServer) 移植并简化
 *
 * 架构:
 *   浏览器 (油猴脚本) ──WS──► JsBridgeServer (:8767)
 *                                    ▲
 *   hermes-app (AccessibilityCapability) ──┘
 *       ▲
 *   Gateway AI (Node Protocol)
 *
 * 浏览器连接后注册为 "browser" 类型客户端，
 * Gateway 通过 Node Protocol → AccessibilityCapability → 本服务器
 * 向浏览器发送 JS 代码并等待执行结果。
 */
class JsBridgeServer(port: Int) : WebSocketServer(InetSocketAddress(port)) {

    companion object {
        private const val TAG = "JsBridgeServer"
        private var instance: JsBridgeServer? = null

        fun getInstance(): JsBridgeServer? = instance

        fun isRunning(): Boolean = instance != null
    }

    // ws -> clientType ("browser" | "default")
    private val clientTypes = ConcurrentHashMap<WebSocket, String>()
    private val pendingJsResults = ConcurrentHashMap<String, CompletableFuture<JSONObject>>()

    init {
        instance = this
        isReuseAddr = true
    }

    override fun onOpen(conn: WebSocket, handshake: ClientHandshake) {
        clientTypes[conn] = "default"
        Log.i(TAG, "Client connected: ${conn.remoteSocketAddress}")

        sendTo(conn, mapOf(
            "type" to "connected",
            "server" to "HermesJsBridge",
            "timestamp" to System.currentTimeMillis().toString()
        ))
    }

    override fun onClose(conn: WebSocket, code: Int, reason: String?, remote: Boolean) {
        clientTypes.remove(conn)
        Log.i(TAG, "Client disconnected (code=$code, reason=$reason)")
    }

    override fun onMessage(conn: WebSocket, message: String) {
        try {
            val json = JSONObject(message)
            val type = json.optString("type", "")

            when (type) {
                "ping" -> sendTo(conn, mapOf(
                    "type" to "pong",
                    "timestamp" to System.currentTimeMillis().toString()
                ))

                // 浏览器客户端注册
                "register" -> {
                    val clientType = json.optString("client_type", "default")
                    clientTypes[conn] = clientType
                    Log.i(TAG, "Client registered as: $clientType")
                    sendTo(conn, mapOf(
                        "type" to "registered",
                        "client_type" to "clientType",
                        "timestamp" to System.currentTimeMillis().toString()
                    ))
                }

                // 浏览器回传 JS 执行结果
                "js_result" -> {
                    val id = json.optString("id", "")
                    if (id.isNotEmpty()) {
                        val future = pendingJsResults.remove(id)
                        if (future != null) {
                            future.complete(json)
                            Log.d(TAG, "JS result received for id=$id")
                        }
                    }
                }

                else -> sendTo(conn, mapOf("type" to "ack", "received" to type))
            }
        } catch (e: Exception) {
            sendTo(conn, mapOf("type" to "error", "message" to "Invalid JSON"))
        }
    }

    override fun onError(conn: WebSocket?, ex: Exception) {
        Log.e(TAG, "WebSocket error: ${ex.message}", ex)
    }

    override fun onStart() {
        Log.i(TAG, "JsBridgeServer started on port ${port}")
    }

    override fun stop(timeout: Int) {
        instance = null
        super.stop(timeout)
    }

    // ====================================================================
    // JS Bridge API — 供 AccessibilityCapability 调用
    // ====================================================================

    /**
     * 向所有已注册的 browser 客户端发送 JS 执行命令
     * @return 执行结果 JSON
     */
    fun execJs(code: String, timeoutMs: Long = 10000L): JSONObject {
        val id = "js_${System.currentTimeMillis()}_${(Math.random() * 10000).toInt()}"
        val future = CompletableFuture<JSONObject>()
        pendingJsResults[id] = future

        val browserClients = clientTypes.filter { it.value == "browser" }.keys
        if (browserClients.isEmpty()) {
            pendingJsResults.remove(id)
            return JSONObject(mapOf(
                "ok" to false,
                "error" to "No browser clients connected. Install the userscript and open a page."
            ))
        }

        val command = JSONObject(mapOf(
            "type" to "js_exec",
            "id" to id,
            "code" to code
        )).toString()

        Log.i(TAG, "Sending JS exec to ${browserClients.size} browser(s), id=$id")
        browserClients.forEach { ws ->
            try {
                if (ws.isOpen) ws.send(command)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send JS exec", e)
            }
        }

        return try {
            future.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: Exception) {
            pendingJsResults.remove(id)
            JSONObject(mapOf(
                "ok" to false,
                "error" to "Timeout: no response from browser (${timeoutMs}ms)"
            ))
        }
    }

    /**
     * 获取已连接的 browser 客户端数量
     */
    fun getBrowserClientCount(): Int {
        return clientTypes.count { it.value == "browser" }
    }

    /**
     * 获取连接状态信息
     */
    fun getInfo(): Map<String, Any> {
        return mapOf(
            "total_clients" to clientTypes.size,
            "browser_clients" to getBrowserClientCount(),
            "status" to "running"
        )
    }

    private fun sendTo(conn: WebSocket, data: Map<String, String>) {
        try {
            if (conn.isOpen) {
                conn.send(JSONObject(data as Map<*, *>).toString())
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send", e)
        }
    }
}
