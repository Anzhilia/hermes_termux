package com.nousresearch.hermes

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Point
import android.media.AudioManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Toast
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * 无障碍服务 — 从 control-app (AutoServer) 移植
 *
 * 提供 UI 自动化能力：tap/swipe/input/scroll/find/screenshot 等，
 * 通过 MethodChannel 暴露给 Flutter 层的 AccessibilityCapability 使用。
 */
class AutoService : AccessibilityService() {

    companion object {
        private val _instance = AtomicReference<AutoService?>(null)
        var instance: AutoService?
            get() = _instance.get()
            private set(value) = _instance.set(value)

        private const val TAG = "AutoService"
        private const val MAX_TREE_DEPTH = 50

        /** 判断无障碍服务是否已连接 */
        fun isConnected(): Boolean = _instance.get() != null
    }

    private val executor = Executors.newSingleThreadExecutor()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "Accessibility Service connected")

        serviceInfo = serviceInfo.apply {
            eventTypes = AccessibilityEvent.TYPES_ALL_MASK
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            flags = AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                    AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
                    AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
            notificationTimeout = 100
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    // ========================================================================
    // UI Tree
    // ========================================================================

    fun dumpUITree(): String {
        val root = rootInActiveWindow ?: return "<error>No active window>"
        val sb = StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        try {
            dumpNode(root, sb, 0)
        } finally {
            root.recycle()
        }
        return sb.toString()
    }

    private fun dumpNode(node: AccessibilityNodeInfo, sb: StringBuilder, depth: Int) {
        if (depth > MAX_TREE_DEPTH) {
            sb.append("${"  ".repeat(depth)}<node class=\"MAX_DEPTH_REACHED\"/>\n")
            return
        }

        val indent = "  ".repeat(depth)
        val className = node.className?.toString()?.substringAfterLast('.') ?: "Unknown"
        val text = xmlEscape(node.text?.toString() ?: "")
        val resId = node.viewIdResourceName ?: ""
        val desc = xmlEscape(node.contentDescription?.toString() ?: "")
        val bounds = android.graphics.Rect()
        node.getBoundsInScreen(bounds)
        val clickable = node.isClickable
        val editable = node.isEditable
        val scrollable = node.isScrollable

        sb.append(
            "$indent<node class=\"$className\" text=\"$text\" resource-id=\"$resId\" " +
                    "content-desc=\"$desc\" bounds=[${bounds.left},${bounds.top}][${bounds.right},${bounds.bottom}] " +
                    "clickable=$clickable editable=$editable scrollable=$scrollable>\n"
        )

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            dumpNode(child, sb, depth + 1)
            child.recycle()
        }
    }

    private fun xmlEscape(s: String): String {
        return s.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&apos;")
    }

    // ========================================================================
    // Tap / Swipe
    // ========================================================================

    fun tap(x: Int, y: Int): Boolean = tapViaGesture(x, y)

    fun tapViaGesture(x: Int, y: Int): Boolean {
        val path = android.graphics.Path().apply {
            moveTo(x.toFloat(), y.toFloat())
            lineTo(x.toFloat() + 1, y.toFloat() + 1)
        }
        val gesture = android.accessibilityservice.GestureDescription.Builder()
            .addStroke(
                android.accessibilityservice.GestureDescription.StrokeDescription(path, 0, 100)
            )
            .build()
        return dispatchGesture(gesture, null, null)
    }

    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long = 300): Boolean {
        val path = android.graphics.Path().apply {
            moveTo(x1.toFloat(), y1.toFloat())
            lineTo(x2.toFloat(), y2.toFloat())
        }
        val gesture = android.accessibilityservice.GestureDescription.Builder()
            .addStroke(
                android.accessibilityservice.GestureDescription.StrokeDescription(path, 0, durationMs)
            )
            .build()
        return dispatchGesture(gesture, null, null)
    }

    // ========================================================================
    // Text Input
    // ========================================================================

    fun inputText(text: String, append: Boolean = false): Boolean {
        val root = rootInActiveWindow ?: return false
        try {
            var editable = findEditableNode(root, focusedOnly = true)

            if (editable == null) {
                editable = findEditableNode(root, focusedOnly = false)
                if (editable != null) {
                    editable.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    Thread.sleep(200)
                }
            }

            if (editable == null) return false

            return try {
                val arguments = android.os.Bundle()
                val finalText = if (append) {
                    (editable.text?.toString() ?: "") + text
                } else {
                    text
                }
                arguments.putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    finalText
                )
                editable.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
            } catch (e: Exception) {
                Log.e(TAG, "inputText failed", e)
                false
            } finally {
                editable.recycle()
            }
        } finally {
            root.recycle()
        }
    }

    private fun findEditableNode(
        root: AccessibilityNodeInfo,
        focusedOnly: Boolean
    ): AccessibilityNodeInfo? {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.addLast(root)
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            if (node.isEditable) {
                if (!focusedOnly || node.isFocused) {
                    drainAndRecycle(queue, root)
                    return node
                }
            }
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                queue.addLast(child)
            }
        }
        return null
    }

    private fun drainAndRecycle(
        queue: ArrayDeque<AccessibilityNodeInfo>,
        root: AccessibilityNodeInfo
    ) {
        while (queue.isNotEmpty()) {
            val n = queue.removeFirst()
            if (n !== root) n.recycle()
        }
    }

    // ========================================================================
    // Global Actions
    // ========================================================================

    fun pressBack(): Boolean = performGlobalAction(GLOBAL_ACTION_BACK)
    fun pressHome(): Boolean = performGlobalAction(GLOBAL_ACTION_HOME)
    fun pressRecents(): Boolean = performGlobalAction(GLOBAL_ACTION_RECENTS)
    fun openNotifications(): Boolean = performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)

    // ========================================================================
    // Scroll
    // ========================================================================

    fun scrollDown(): Boolean {
        if (Build.VERSION.SDK_INT >= 33) return performGlobalAction(17)
        return scrollVertical("down")
    }

    fun scrollUp(): Boolean {
        if (Build.VERSION.SDK_INT >= 33) return performGlobalAction(16)
        return scrollVertical("up")
    }

    fun scrollLeft(): Boolean = scrollHorizontal("left")
    fun scrollRight(): Boolean = scrollHorizontal("right")

    private fun scrollVertical(direction: String): Boolean {
        val swiped = swipeScroll(direction)
        if (swiped) return true

        val root = rootInActiveWindow ?: return false
        try {
            val scrollable = findVerticalScrollableNode(root)
            if (scrollable != null) {
                val action = if (direction == "down")
                    AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                else
                    AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                return scrollable.performAction(action)
            }
        } finally {
            root.recycle()
        }
        return false
    }

    private fun scrollHorizontal(direction: String): Boolean {
        val swiped = swipeScroll(direction)
        if (swiped) return true

        val root = rootInActiveWindow ?: return false
        try {
            val scrollable = findHorizontalScrollableNode(root)
            if (scrollable != null) {
                val action = if (direction == "right")
                    AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                else
                    AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                return scrollable.performAction(action)
            }
        } finally {
            root.recycle()
        }
        return false
    }

    private fun swipeScroll(direction: String): Boolean {
        val size = getScreenSize()
        val cx = size.x / 2
        val cy = size.y / 2
        val padX = (size.x * 0.15f).toInt()
        val padY = (size.y * 0.15f).toInt()
        val left = padX
        val right = size.x - padX
        val top = padY
        val bottom = size.y - padY

        return when (direction) {
            "up" -> swipe(cx, top, cx, bottom, 300)
            "down" -> swipe(cx, bottom, cx, top, 300)
            "left" -> swipe(right, cy, left, cy, 300)
            "right" -> swipe(left, cy, right, cy, 300)
            else -> false
        }
    }

    private fun findVerticalScrollableNode(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        return findScrollableNodeByDirection(root, vertical = true)
    }

    private fun findHorizontalScrollableNode(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        return findScrollableNodeByDirection(root, vertical = false)
    }

    private fun findScrollableNodeByDirection(
        root: AccessibilityNodeInfo,
        vertical: Boolean
    ): AccessibilityNodeInfo? {
        data class Candidate(val node: AccessibilityNodeInfo, val depth: Int, val vScore: Int)

        val candidates = mutableListOf<Candidate>()
        val pending = ArrayDeque<Pair<AccessibilityNodeInfo, Int>>()
        pending.addLast(Pair(root, 0))

        while (pending.isNotEmpty()) {
            val (node, depth) = pending.removeFirst()
            if (node.isScrollable) {
                val score = scoreVerticalDirection(node)
                candidates.add(Candidate(node, depth, score))
                continue
            }
            for (i in 0 until node.childCount) {
                val child = node.getChild(i) ?: continue
                pending.addLast(Pair(child, depth + 1))
            }
        }

        if (candidates.isEmpty()) return null

        val best = if (vertical) {
            candidates.filter { it.vScore > 0 }.maxByOrNull { it.depth }
                ?: candidates.minByOrNull { it.depth }
        } else {
            candidates.filter { it.vScore < 0 }.maxByOrNull { it.depth }
                ?: candidates.minByOrNull { it.depth }
        }

        for (c in candidates) {
            if (c.node !== best?.node) c.node.recycle()
        }
        return best?.node
    }

    private fun scoreVerticalDirection(node: AccessibilityNodeInfo): Int {
        val childCount = node.childCount
        if (childCount < 2) return scoreByBounds(node)

        val bounds = android.graphics.Rect()
        node.getBoundsInScreen(bounds)
        val childBoundsList = mutableListOf<android.graphics.Rect>()
        val maxChildren = minOf(childCount, 10)

        for (i in 0 until maxChildren) {
            val child = node.getChild(i) ?: continue
            val cb = android.graphics.Rect()
            child.getBoundsInScreen(cb)
            childBoundsList.add(cb)
            child.recycle()
        }

        if (childBoundsList.size < 2) return scoreByBounds(node)

        var leftDiffs = 0
        var topDiffs = 0
        for (i in 1 until childBoundsList.size) {
            val prev = childBoundsList[i - 1]
            val curr = childBoundsList[i]
            if (kotlin.math.abs(curr.left - prev.left) > 20) leftDiffs++
            if (kotlin.math.abs(curr.top - prev.top) > 20) topDiffs++
        }

        if (leftDiffs > childBoundsList.size / 2 && topDiffs <= childBoundsList.size / 4) return -3
        if (topDiffs > childBoundsList.size / 2 && leftDiffs <= childBoundsList.size / 4) return 3

        val containerTop = bounds.top
        val containerBottom = bounds.bottom
        val containerLeft = bounds.left
        val containerRight = bounds.right

        val minChildTop = childBoundsList.minOf { it.top }
        val maxChildBottom = childBoundsList.maxOf { it.bottom }
        val minChildLeft = childBoundsList.minOf { it.left }
        val maxChildRight = childBoundsList.maxOf { it.right }

        val verticalOverflow =
            minChildTop < containerTop - 10 || maxChildBottom > containerBottom + 10
        val horizontalOverflow =
            minChildLeft < containerLeft - 10 || maxChildRight > containerRight + 10

        if (verticalOverflow && !horizontalOverflow) return 2
        if (horizontalOverflow && !verticalOverflow) return -2
        if (verticalOverflow && horizontalOverflow) {
            val vOverflow =
                (containerTop - minChildTop) + (maxChildBottom - containerBottom)
            val hOverflow =
                (containerLeft - minChildLeft) + (maxChildRight - containerRight)
            return if (vOverflow >= hOverflow) 1 else -1
        }

        return scoreByBounds(node)
    }

    private fun scoreByBounds(node: AccessibilityNodeInfo): Int {
        val bounds = android.graphics.Rect()
        node.getBoundsInScreen(bounds)
        val h = bounds.height()
        val w = bounds.width()
        return when {
            h > w * 1.5 -> 1
            w > h * 1.5 -> -1
            else -> 0
        }
    }

    // ========================================================================
    // Find Elements
    // ========================================================================

    fun findElements(
        text: String? = null,
        id: String? = null,
        description: String? = null,
        className: String? = null,
        clickableOnly: Boolean = false
    ): List<Map<String, Any>> {
        val root = rootInActiveWindow ?: return emptyList()
        val results = mutableListOf<Map<String, Any>>()
        val seen = mutableSetOf<String>()

        try {
            val nodes = mutableListOf<AccessibilityNodeInfo>()

            if (!text.isNullOrEmpty()) {
                nodes.addAll(root.findAccessibilityNodeInfosByText(text))
            }
            if (!id.isNullOrEmpty()) {
                nodes.addAll(root.findAccessibilityNodeInfosByViewId(id))
            }
            if (!description.isNullOrEmpty()) {
                collectNodesByDescription(root, description, nodes)
            }
            if (text.isNullOrEmpty() && id.isNullOrEmpty() && description.isNullOrEmpty()) {
                return emptyList()
            }

            for (node in nodes) {
                if (clickableOnly && !node.isClickable) continue
                if (!className.isNullOrEmpty() && node.className?.toString() != className) continue

                val bounds = android.graphics.Rect()
                node.getBoundsInScreen(bounds)
                val key = "${bounds}|${node.text}|${node.viewIdResourceName}"
                if (key in seen) continue
                seen.add(key)

                results.add(
                    mapOf(
                        "text" to (node.text?.toString() ?: ""),
                        "resource_id" to (node.viewIdResourceName ?: ""),
                        "content_desc" to (node.contentDescription?.toString() ?: ""),
                        "class" to (node.className?.toString() ?: ""),
                        "bounds" to mapOf(
                            "left" to bounds.left,
                            "top" to bounds.top,
                            "right" to bounds.right,
                            "bottom" to bounds.bottom
                        ),
                        "clickable" to node.isClickable,
                        "scrollable" to node.isScrollable,
                        "editable" to node.isEditable,
                        "enabled" to node.isEnabled,
                        "focused" to node.isFocused
                    )
                )

                if (results.size >= 50) break
            }
            nodes.forEach { it.recycle() }
        } finally {
            root.recycle()
        }

        return results
    }

    private fun collectNodesByDescription(
        node: AccessibilityNodeInfo,
        target: String,
        out: MutableList<AccessibilityNodeInfo>
    ) {
        val desc = node.contentDescription?.toString()
        if (desc != null && desc.contains(target, ignoreCase = true)) {
            out.add(node)
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            collectNodesByDescription(child, target, out)
            child.recycle()
        }
    }

    fun waitForElement(
        text: String? = null,
        id: String? = null,
        description: String? = null,
        timeoutMs: Long = 5000,
        pollIntervalMs: Long = 300
    ): Map<String, Any>? {
        val deadline = System.currentTimeMillis() + timeoutMs

        while (System.currentTimeMillis() < deadline) {
            val found = findElements(
                text = text,
                id = id,
                description = description,
                clickableOnly = false
            )
            if (found.isNotEmpty()) {
                return mapOf(
                    "found" to true,
                    "elapsed_ms" to (timeoutMs - (deadline - System.currentTimeMillis())),
                    "node" to found[0]
                )
            }
            Thread.sleep(pollIntervalMs)
        }

        return null
    }

    // ========================================================================
    // Click by Text / ID
    // ========================================================================

    fun clickText(text: String): Boolean {
        val root = rootInActiveWindow ?: return false
        try {
            val nodes = root.findAccessibilityNodeInfosByText(text)
            if (nodes.isNotEmpty()) {
                val node = nodes[0]
                val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                nodes.forEach { it.recycle() }
                return ok
            }
        } finally {
            root.recycle()
        }
        return false
    }

    fun clickById(resourceId: String): Boolean {
        val root = rootInActiveWindow ?: return false
        try {
            val nodes = root.findAccessibilityNodeInfosByViewId(resourceId)
            if (nodes.isNotEmpty()) {
                val node = nodes[0]
                val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                nodes.forEach { it.recycle() }
                return ok
            }
        } finally {
            root.recycle()
        }
        return false
    }

    // ========================================================================
    // Toast
    // ========================================================================

    fun showToast(message: String, durationLong: Boolean = false) {
        val duration = if (durationLong) Toast.LENGTH_LONG else Toast.LENGTH_SHORT
        Handler(Looper.getMainLooper()).post {
            Toast.makeText(applicationContext, message, duration).show()
        }
    }

    // ========================================================================
    // Current App
    // ========================================================================

    fun getCurrentApp(): Map<String, String>? {
        val myPkg = applicationContext.packageName

        // 方法1: UsageStatsManager
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                val usm = getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
                if (usm != null) {
                    val now = System.currentTimeMillis()
                    val events = usm.queryEvents(now - 10_000, now)
                    if (events != null) {
                        var lastPkg: String? = null
                        var lastActivity: String? = null
                        val event = UsageEvents.Event()
                        while (events.hasNextEvent()) {
                            events.getNextEvent(event)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                if (event.eventType == UsageEvents.Event.ACTIVITY_RESUMED) {
                                    lastPkg = event.packageName
                                    lastActivity = event.className
                                }
                            } else {
                                @Suppress("DEPRECATION")
                                if (event.eventType == UsageEvents.Event.MOVE_TO_FOREGROUND) {
                                    lastPkg = event.packageName
                                    lastActivity = event.className
                                }
                            }
                        }
                        if (lastPkg != null && lastPkg != myPkg) {
                            return mapOf(
                                "package_name" to lastPkg,
                                "app_name" to getAppName(lastPkg),
                                "activity" to (lastActivity ?: "")
                            )
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "getCurrentApp via UsageStats failed", e)
        }

        // 方法2: AccessibilityService windows
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                val windows = windows
                if (windows != null) {
                    for (i in windows.indices.reversed()) {
                        val window = windows[i]
                        val root = window.root ?: continue
                        val pkg = root.packageName?.toString()
                        if (pkg != null && pkg != myPkg) {
                            root.recycle()
                            return mapOf(
                                "package_name" to pkg,
                                "app_name" to getAppName(pkg),
                                "activity" to ""
                            )
                        }
                        root.recycle()
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "getCurrentApp via windows failed", e)
        }

        // 方法3: rootInActiveWindow
        try {
            val root = rootInActiveWindow
            if (root != null) {
                val pkg = root.packageName?.toString()
                root.recycle()
                if (pkg != null && pkg != myPkg) {
                    return mapOf(
                        "package_name" to pkg,
                        "app_name" to getAppName(pkg),
                        "activity" to ""
                    )
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "getCurrentApp via rootInActiveWindow failed", e)
        }

        return null
    }

    fun hasUsageStatsPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return false
        val usm =
            getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager ?: return false
        val now = System.currentTimeMillis()
        val stats = usm.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, now - 1000, now)
        return stats != null && stats.isNotEmpty()
    }

    fun openUsageStatsSettings() {
        val intent = Intent(android.provider.Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun getAppName(packageName: String): String {
        return try {
            val pm = applicationContext.packageManager
            val info = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(info).toString()
        } catch (e: Exception) {
            packageName
        }
    }

    // ========================================================================
    // Installed Apps
    // ========================================================================

    fun getInstalledApps(): List<Map<String, String>> {
        val pm = applicationContext.packageManager
        val apps = mutableListOf<Map<String, String>>()
        val packages = pm.getInstalledApplications(PackageManager.GET_META_DATA)
        for (pkg in packages) {
            val launchIntent = pm.getLaunchIntentForPackage(pkg.packageName)
            if (launchIntent != null) {
                apps.add(
                    mapOf(
                        "package_name" to pkg.packageName,
                        "app_name" to pm.getApplicationLabel(pkg).toString()
                    )
                )
            }
        }
        return apps.sortedBy { it["app_name"]?.lowercase() }
    }

    // ========================================================================
    // Device Info
    // ========================================================================

    fun getDeviceInfo(): Map<String, Any> {
        val info = mutableMapOf<String, Any>()

        val batteryManager = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        info["battery_level"] =
            batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val batteryStatus = registerReceiver(
            null,
            android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        )
        if (batteryStatus != null) {
            val status = batteryStatus.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            info["charging"] = when (status) {
                BatteryManager.BATTERY_STATUS_CHARGING -> true
                BatteryManager.BATTERY_STATUS_FULL -> true
                else -> false
            }
            val plugged = batteryStatus.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1)
            info["charge_type"] = when (plugged) {
                BatteryManager.BATTERY_PLUGGED_AC -> "AC"
                BatteryManager.BATTERY_PLUGGED_USB -> "USB"
                BatteryManager.BATTERY_PLUGGED_WIRELESS -> "Wireless"
                else -> "None"
            }
        }

        val size = getScreenSize()
        info["screen_width"] = size.x
        info["screen_height"] = size.y

        val metrics = resources.displayMetrics
        info["density"] = metrics.density
        info["density_dpi"] = metrics.densityDpi

        info["model"] = Build.MODEL
        info["manufacturer"] = Build.MANUFACTURER
        info["brand"] = Build.BRAND
        info["device"] = Build.DEVICE
        info["sdk_version"] = Build.VERSION.SDK_INT
        info["android_version"] = Build.VERSION.RELEASE
        info["network_type"] = getNetworkType()

        return info
    }

    // ========================================================================
    // Clipboard
    // ========================================================================

    fun readClipboard(): String? {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        return if (cm.hasPrimaryClip()) {
            cm.primaryClip?.getItemAt(0)?.text?.toString()
        } else null
    }

    fun writeClipboard(text: String): Boolean {
        return try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = android.content.ClipData.newPlainText("HermesA11y", text)
            cm.setPrimaryClip(clip)
            true
        } catch (e: Exception) {
            Log.e(TAG, "writeClipboard failed", e)
            false
        }
    }

    // ========================================================================
    // Volume
    // ========================================================================

    fun getVolumeInfo(): Map<String, Any> {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return mapOf(
            "music" to mapOf(
                "current" to am.getStreamVolume(AudioManager.STREAM_MUSIC),
                "max" to am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            ),
            "ring" to mapOf(
                "current" to am.getStreamVolume(AudioManager.STREAM_RING),
                "max" to am.getStreamMaxVolume(AudioManager.STREAM_RING)
            ),
            "alarm" to mapOf(
                "current" to am.getStreamVolume(AudioManager.STREAM_ALARM),
                "max" to am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
            ),
            "notification" to mapOf(
                "current" to am.getStreamVolume(AudioManager.STREAM_NOTIFICATION),
                "max" to am.getStreamMaxVolume(AudioManager.STREAM_NOTIFICATION)
            ),
            "call" to mapOf(
                "current" to am.getStreamVolume(AudioManager.STREAM_VOICE_CALL),
                "max" to am.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)
            ),
            "ringer_mode" to when (am.ringerMode) {
                AudioManager.RINGER_MODE_SILENT -> "silent"
                AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
                AudioManager.RINGER_MODE_NORMAL -> "normal"
                else -> "unknown"
            }
        )
    }

    fun setVolume(stream: String, level: Int): Boolean {
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val streamType = when (stream.lowercase()) {
                "music" -> AudioManager.STREAM_MUSIC
                "ring" -> AudioManager.STREAM_RING
                "alarm" -> AudioManager.STREAM_ALARM
                "notification" -> AudioManager.STREAM_NOTIFICATION
                "call" -> AudioManager.STREAM_VOICE_CALL
                else -> AudioManager.STREAM_MUSIC
            }
            val maxVol = am.getStreamMaxVolume(streamType)
            val targetLevel = level.coerceIn(0, maxVol)
            am.setStreamVolume(streamType, targetLevel, 0)
            true
        } catch (e: Exception) {
            Log.e(TAG, "setVolume failed", e)
            false
        }
    }

    // ========================================================================
    // Pixel Color
    // ========================================================================

    fun getPixelColor(x: Int, y: Int): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null

        val tempFile = File(applicationContext.cacheDir, "color_temp.jpg")
        var colorResult: String? = null

        try {
            val latch = java.util.concurrent.CountDownLatch(1)
            takeScreenshot(tempFile.absolutePath, latch)
            if (!latch.await(5, java.util.concurrent.TimeUnit.SECONDS)) {
                return null
            }

            if (!tempFile.exists() || tempFile.length() == 0L) return null

            val bitmap =
                android.graphics.BitmapFactory.decodeFile(tempFile.absolutePath) ?: return null

            val size = getScreenSize()
            val sx =
                (x.toFloat() / size.x * bitmap.width).toInt().coerceIn(0, bitmap.width - 1)
            val sy =
                (y.toFloat() / size.y * bitmap.height).toInt().coerceIn(0, bitmap.height - 1)

            val pixel = bitmap.getPixel(sx, sy)
            colorResult = String.format("#%08X", pixel)
            bitmap.recycle()
        } catch (e: Exception) {
            Log.e(TAG, "getPixelColor failed", e)
        } finally {
            tempFile.delete()
        }
        return colorResult
    }

    // ========================================================================
    // Screenshot
    // ========================================================================

    fun takeScreenshot(
        savePath: String,
        latch: java.util.concurrent.CountDownLatch? = null
    ): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            takeScreenshot(
                Display.DEFAULT_DISPLAY,
                executor,
                object : TakeScreenshotCallback {
                    override fun onSuccess(result: ScreenshotResult) {
                        try {
                            val hardwareBuffer = result.hardwareBuffer
                            val colorSpace = result.colorSpace
                            val bitmap =
                                Bitmap.wrapHardwareBuffer(hardwareBuffer, colorSpace)
                            if (bitmap != null) {
                                val file = File(savePath)
                                file.parentFile?.mkdirs()
                                file.outputStream().use { out ->
                                    bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
                                }
                                bitmap.recycle()
                            }
                            hardwareBuffer.close()
                        } catch (e: Exception) {
                            Log.e(TAG, "Screenshot save failed", e)
                        } finally {
                            latch?.countDown()
                        }
                    }

                    override fun onFailure(errorCode: Int) {
                        Log.e(TAG, "Screenshot failed: errorCode=$errorCode")
                        latch?.countDown()
                    }
                }
            )
            return true
        }
        return false
    }

    // ========================================================================
    // Launch App
    // ========================================================================

    fun launchApp(
        packageName: String?,
        action: String? = null,
        uri: String? = null,
        type: String? = null,
        component: String? = null,
        extras: Map<String, Any>? = null,
        flags: Int = -1
    ): Boolean {
        return try {
            val intent = Intent()

            if (!action.isNullOrEmpty()) intent.action = action

            if (!component.isNullOrEmpty()) {
                val cn = if (component.contains("/")) {
                    val parts = component.split("/", limit = 2)
                    val cls = if (parts[1].startsWith(".")) parts[0] + parts[1] else parts[1]
                    android.content.ComponentName(parts[0], cls)
                } else {
                    android.content.ComponentName(packageName ?: "", component)
                }
                intent.component = cn
            }

            if (!uri.isNullOrEmpty()) intent.data = android.net.Uri.parse(uri)
            if (!type.isNullOrEmpty()) {
                if (!uri.isNullOrEmpty()) {
                    intent.setDataAndType(android.net.Uri.parse(uri), type)
                } else {
                    intent.type = type
                }
            }

            extras?.forEach { (key, value) ->
                when (value) {
                    is Boolean -> intent.putExtra(key, value)
                    is Int -> intent.putExtra(key, value)
                    is Long -> intent.putExtra(key, value)
                    is Double -> intent.putExtra(key, value)
                    is String -> intent.putExtra(key, value)
                }
            }

            if (flags >= 0) intent.addFlags(flags)
            else intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

            if (component.isNullOrEmpty() && !packageName.isNullOrEmpty()) {
                intent.setPackage(packageName)
                val launchIntent = applicationContext.packageManager.getLaunchIntentForPackage(
                    packageName
                )
                if (launchIntent != null) {
                    applicationContext.startActivity(launchIntent)
                    return true
                }
            }

            applicationContext.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.e(TAG, "launchApp failed", e)
            false
        }
    }

    // ========================================================================
    // Utils
    // ========================================================================

    fun getScreenSize(): Point {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = wm.currentWindowMetrics.bounds
            Point(bounds.width(), bounds.height())
        } else {
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(metrics)
            Point(metrics.widthPixels, metrics.heightPixels)
        }
    }

    private fun getNetworkType(): String {
        val cm =
            getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val network = cm.activeNetwork
            val caps = cm.getNetworkCapabilities(network)
            when {
                caps == null -> "None"
                caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> "WiFi"
                caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "Cellular"
                caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
                caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
                else -> "Other"
            }
        } else {
            @Suppress("DEPRECATION")
            val info = cm.activeNetworkInfo
            @Suppress("DEPRECATION")
            info?.typeName ?: "None"
        }
    }
}
