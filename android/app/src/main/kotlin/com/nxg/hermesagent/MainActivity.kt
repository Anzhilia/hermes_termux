package com.nousresearch.hermes

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.FileProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import android.app.Activity
import android.content.Context
import android.os.Environment
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.projection.MediaProjectionManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.OpenableColumns
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.nousresearch.hermes/native"
    private val EVENT_CHANNEL = "com.nousresearch.hermes/gateway_logs"
    private val SETUP_LOG_EVENT_CHANNEL = "com.nousresearch.hermes/setup_logs"

    private lateinit var bootstrapManager: BootstrapManager
    private lateinit var processManager: ProcessManager
    private var setupLogSink: EventChannel.EventSink? = null
    private var screenCaptureResult: MethodChannel.Result? = null
    private var screenCaptureDurationMs: Long = 5000L
    private var snapshotPickResult: MethodChannel.Result? = null
    private var snapshotSaveResult: MethodChannel.Result? = null
    private var pendingSnapshotContent: String? = null
    private var pendingSnapshotName: String? = null
    private var backupPickResult: MethodChannel.Result? = null
    private var bootstrapArchivePickResult: MethodChannel.Result? = null
    private var workspaceBackupSaveResult: MethodChannel.Result? = null
    private var pendingWorkspaceBackupName: String? = null
    private var pendingWorkspaceBackupAppVersion: String? = null
    private var pendingWorkspaceBackupHermesVersion: String? = null
    private var pendingApkInstallResult: MethodChannel.Result? = null
    private var pendingApkInstallPath: String? = null
    private var setupDone = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val filesDir = applicationContext.filesDir.absolutePath
        val nativeLibDir = applicationContext.applicationInfo.nativeLibraryDir

        bootstrapManager = BootstrapManager(applicationContext, filesDir, nativeLibDir)
        processManager = ProcessManager(filesDir, nativeLibDir)
        processManager.installLogEmitter = { line ->
            runOnUiThread {
                setupLogSink?.success(line)
            }
        }

        // Ensure directories and resolv.conf exist on every app start.
        // Android may clear filesDir during APK update (#40).
        if (!setupDone) {
            setupDone = true
            Thread {
                try { bootstrapManager.setupDirectories() } catch (_: Exception) {}
                try { bootstrapManager.writeResolvConf() } catch (_: Exception) {}
                // ★ Fix hermes_cli/__main__.py on every app start.
                // Official install.sh doesn't create it, causing
                // "No module named hermes_cli.__main__" errors.
                try { fixHermesMainPy(filesDir) } catch (_: Exception) {}
            }.start()
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getProotPath" -> {
                    result.success(processManager.getProotPath())
                }
                "getArch" -> {
                    result.success(ArchUtils.getArch())
                }
                "getAndroidApiLevel" -> {
                    result.success(Build.VERSION.SDK_INT.toString())
                }
                "getFilesDir" -> {
                    result.success(filesDir)
                }
                "getNativeLibDir" -> {
                    result.success(nativeLibDir)
                }
                "getWebViewPackageInfo" -> {
                    result.success(getWebViewPackageInfo())
                }
                "isBootstrapComplete" -> {
                    result.success(bootstrapManager.isBootstrapComplete())
                }
                "getBootstrapStatus" -> {
                    result.success(bootstrapManager.getBootstrapStatus())
                }
                "extractRootfs" -> {
                    val tarPath = call.argument<String>("tarPath")
                    if (tarPath != null) {
                        Thread {
                            try {
                                bootstrapManager.extractRootfs(tarPath)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("EXTRACT_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "tarPath required", null)
                    }
                }
                "runInProot" -> {
                    val command = call.argument<String>("command")
                    val timeout = call.argument<Int>("timeout")?.toLong() ?: 900L
                    if (command != null) {
                        Thread {
                            try {
                                bootstrapManager.setupDirectories()
                                bootstrapManager.writeResolvConf()
                                val output = processManager.runInProotSync(command, timeout)
                                runOnUiThread { result.success(output) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("PROOT_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "command required", null)
                    }
                }
                "startGateway" -> {
                    try {
                        GatewayService.start(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "stopGateway" -> {
                    Thread {
                        try {
                            val stopped = GatewayService.stopAndWait(applicationContext)
                            runOnUiThread { result.success(stopped) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("SERVICE_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }
                "isGatewayRunning" -> {
                    Thread {
                        try {
                            val running = GatewayService.isProcessAlive()
                            runOnUiThread { result.success(running) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("SERVICE_ERROR", e.message, null)
                            }
                        }
                    }.start()
                }
                "isGatewayLogPersistenceEnabled" -> {
                    result.success(
                        GatewayLogPersistence.isEnabled(applicationContext)
                    )
                }
                "setGatewayLogPersistenceEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    GatewayLogPersistence.setEnabled(applicationContext, enabled)
                    result.success(true)
                }
                "startTerminalService" -> {
                    try {
                        TerminalSessionService.start(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "stopTerminalService" -> {
                    try {
                        TerminalSessionService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "isTerminalServiceRunning" -> {
                    result.success(TerminalSessionService.isRunning)
                }
                "startNodeService" -> {
                    try {
                        NodeForegroundService.start(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "stopNodeService" -> {
                    try {
                        NodeForegroundService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "isNodeServiceRunning" -> {
                    result.success(NodeForegroundService.isRunning)
                }
                "startNodeWsServer" -> {
                    Thread {
                        try {
                            val started = NodeWsServerManager.start(filesDir, nativeLibDir)
                            if (started) {
                                val ready = NodeWsServerManager.waitForPort(15000)
                                runOnUiThread { result.success(ready) }
                            } else {
                                runOnUiThread { result.success(false) }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("WS_SERVER_ERROR", e.message, null) }
                        }
                    }.start()
                }
                "stopNodeWsServer" -> {
                    Thread {
                        try {
                            NodeWsServerManager.stop(filesDir, nativeLibDir)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("WS_SERVER_ERROR", e.message, null) }
                        }
                    }.start()
                }
                "isNodeWsServerRunning" -> {
                    result.success(NodeWsServerManager.isProcessAlive())
                }
                "updateNodeNotification" -> {
                    val text = call.argument<String>("text") ?: "Node connected"
                    NodeForegroundService.updateStatus(text)
                    result.success(true)
                }
                "startCpolarService" -> {
                    val binaryPath = call.argument<String>("binaryPath")
                    val configPath = call.argument<String>("configPath")
                    val logPath = call.argument<String>("logPath")
                    val webPort = call.argument<Int>("webPort") ?: 9200

                    if (binaryPath != null && configPath != null && logPath != null) {
                        try {
                            CpolarForegroundService.start(
                                applicationContext,
                                binaryPath,
                                configPath,
                                logPath,
                                webPort
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SERVICE_ERROR", e.message, null)
                        }
                    } else {
                        result.error(
                            "INVALID_ARGS",
                            "binaryPath, configPath, and logPath required",
                            null
                        )
                    }
                }
                "stopCpolarService" -> {
                    try {
                        CpolarForegroundService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "isCpolarServiceRunning" -> {
                    result.success(CpolarForegroundService.isRunning)
                }
                "startLocalModelService" -> {
                    val binaryPath = call.argument<String>("binaryPath")
                    val modelPath = call.argument<String>("modelPath")
                    val logPath = call.argument<String>("logPath")
                    val port = call.argument<Int>("port") ?: 18080
                    val alias = call.argument<String>("alias") ?: "local-model"
                    val contextSize = call.argument<Int>("contextSize") ?: 4096
                    val threads = call.argument<Int>("threads") ?: 4
                    val threadsBatch = call.argument<Int>("threadsBatch") ?: threads
                    val batchSize = call.argument<Int>("batchSize") ?: 512
                    val ubatchSize = call.argument<Int>("ubatchSize") ?: minOf(batchSize, 256)

                    if (binaryPath != null && modelPath != null && logPath != null) {
                        try {
                            LocalModelForegroundService.start(
                                applicationContext,
                                binaryPath,
                                modelPath,
                                logPath,
                                port,
                                alias,
                                contextSize,
                                threads,
                                threadsBatch,
                                batchSize,
                                ubatchSize
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SERVICE_ERROR", e.message, null)
                        }
                    } else {
                        result.error(
                            "INVALID_ARGS",
                            "binaryPath, modelPath, and logPath required",
                            null
                        )
                    }
                }
                "stopLocalModelService" -> {
                    try {
                        LocalModelForegroundService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "isLocalModelServiceRunning" -> {
                    result.success(LocalModelForegroundService.isRunning)
                }
                "getLocalModelRuntimeStats" -> {
                    Thread {
                        try {
                            val stats = LocalModelForegroundService.snapshotRuntimeStats(applicationContext)
                            runOnUiThread { result.success(stats) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SERVICE_ERROR", e.message, null) }
                        }
                    }.start()
                }
                "startSshd" -> {
                    val port = call.argument<Int>("port") ?: 8022
                    try {
                        SshForegroundService.start(applicationContext, port)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "stopSshd" -> {
                    try {
                        SshForegroundService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "isSshdRunning" -> {
                    result.success(SshForegroundService.isRunning)
                }
                "getSshdPort" -> {
                    result.success(SshForegroundService.currentPort)
                }
                "getDeviceIps" -> {
                    result.success(SshForegroundService.getDeviceIps())
                }
                "setRootPassword" -> {
                    val password = call.argument<String>("password")
                    if (password != null) {
                        Thread {
                            try {
                                // Fix #1: Use stdin pipe to chpasswd instead of shell
                                // string interpolation to prevent command injection.
                                val cmd = processManager.buildInstallCommand("chpasswd")
                                val pb = ProcessBuilder(cmd)
                                // Must match ProcessManager.prootEnv() exactly —
                                // proot requires PROOT_LOADER to intercept execve.
                                pb.environment().clear()
                                pb.environment().putAll(mapOf(
                                    "PROOT_TMP_DIR" to "$filesDir/tmp",
                                    "PROOT_LOADER" to "$nativeLibDir/libprootloader.so",
                                    "PROOT_LOADER_32" to "$nativeLibDir/libprootloader32.so",
                                    "LD_LIBRARY_PATH" to listOf(
                                        "$filesDir/lib", nativeLibDir, "$filesDir/native"
                                    ).distinct().joinToString(":"),
                                    "PYTHONPATH" to "",
                                    "PYTHONHOME" to "",
                                ))
                                pb.redirectErrorStream(true)
                                val process = pb.start()
                                process.outputStream.bufferedWriter(Charsets.UTF_8).use { writer ->
                                    writer.write("root:$password\n")
                                }
                                val exited = process.waitFor(15, java.util.concurrent.TimeUnit.SECONDS)
                                if (!exited) {
                                    process.destroyForcibly()
                                    throw RuntimeException("chpasswd timed out")
                                }
                                if (process.exitValue() != 0) {
                                    val err = process.inputStream.bufferedReader().readText()
                                    throw RuntimeException("chpasswd failed: ${err.take(200)}")
                                }
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("SSH_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "password required", null)
                    }
                }
                "requestBatteryOptimization" -> {
                    try {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                            data = Uri.parse("package:${packageName}")
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("BATTERY_ERROR", e.message, null)
                    }
                }
                "isBatteryOptimized" -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(!pm.isIgnoringBatteryOptimizations(packageName))
                }
                "setupDirs" -> {
                    Thread {
                        try {
                            bootstrapManager.setupDirectories()
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SETUP_ERROR", e.message, null) }
                        }
                    }.start()
                }
                "installBionicBypass" -> {
                    Thread {
                        try {
                            bootstrapManager.installBionicBypass()
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("BYPASS_ERROR", e.message, null) }
                        }
                    }.start()
                }
                "writeResolv" -> {
                    Thread {
                        try {
                            bootstrapManager.writeResolvConf()
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("RESOLV_ERROR", e.message, null) }
                        }
                    }.start()
                }
                "setupProotFromTermux" -> {
                    val arch = call.argument<String>("arch") ?: ArchUtils.getArch()
                    Thread {
                        try {
                            bootstrapManager.setupProotFromTermux(arch)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PROOT_DOWNLOAD_ERROR", e.message, null) }
                        }
                    }.start()
                }
                "copyBundledAssetToFile" -> {
                    val assetPath = call.argument<String>("assetPath")
                    val destinationPath = call.argument<String>("destinationPath")
                    if (!assetPath.isNullOrBlank() && !destinationPath.isNullOrBlank()) {
                        Thread {
                            try {
                                bootstrapManager.copyBundledAssetToFile(assetPath, destinationPath)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("ASSET_COPY_ERROR", e.message, null)
                                }
                            }
                        }.start()
                    } else {
                        result.error(
                            "INVALID_ARGS",
                            "assetPath and destinationPath required",
                            null
                        )
                    }
                }
                "extractDebPackages" -> {
                    Thread {
                        try {
                            val count = bootstrapManager.extractDebPackages()
                            runOnUiThread { result.success(count) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("DEB_EXTRACT_ERROR", e.message, null) }
                        }
                    }.start()
                }
                "extractPythonTarball" -> {
                    val tarPath = call.argument<String>("tarPath")
                    if (tarPath != null) {
                        Thread {
                            try {
                                bootstrapManager.extractPythonTarball(tarPath)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("PYTHON_EXTRACT_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "tarPath required", null)
                    }
                }
                "ensureHermesEntryPoint" -> {
                    val entryPoint = call.argument<String>("entryPoint") ?: "hermes"
                    if (entryPoint != null) {
                        Thread {
                            try {
                                bootstrapManager.ensureHermesEntryPoint(entryPoint)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("ENTRY_POINT_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "entryPoint required", null)
                    }
                }
                "startSetupService" -> {
                    try {
                        SetupService.start(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "updateSetupNotification" -> {
                    val text = call.argument<String>("text")
                    val progress = call.argument<Int>("progress") ?: -1
                    if (text != null) {
                        SetupService.updateNotification(text, progress)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "text required", null)
                    }
                }
                "stopSetupService" -> {
                    try {
                        SetupService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "showUrlNotification" -> {
                    val url = call.argument<String>("url")
                    val title = call.argument<String>("title") ?: "URL Detected"
                    if (url != null) {
                        showUrlNotification(url, title)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "url required", null)
                    }
                }
                "pickSnapshotFile" -> {
                    snapshotPickResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(
                            Intent.EXTRA_MIME_TYPES,
                            arrayOf("application/json", "text/json", "text/plain")
                        )
                    }
                    startActivityForResult(intent, SNAPSHOT_PICK_REQUEST)
                }
                "saveSnapshotFile" -> {
                    val suggestedName = call.argument<String>("suggestedName")
                    val content = call.argument<String>("content")
                    if (suggestedName.isNullOrBlank() || content == null) {
                        result.error(
                            "INVALID_ARGS",
                            "suggestedName and content required",
                            null
                        )
                    } else {
                        snapshotSaveResult = result
                        pendingSnapshotContent = content
                        pendingSnapshotName = suggestedName
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/json"
                            putExtra(Intent.EXTRA_TITLE, suggestedName)
                        }
                        startActivityForResult(intent, SNAPSHOT_SAVE_REQUEST)
                    }
                }
                "pickBackupFile" -> {
                    backupPickResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(
                            Intent.EXTRA_MIME_TYPES,
                            arrayOf(
                                "application/json",
                                "text/json",
                                "text/plain",
                                "application/zip",
                                "application/x-zip-compressed",
                                "application/octet-stream"
                            )
                        )
                    }
                    startActivityForResult(intent, BACKUP_PICK_REQUEST)
                }
                "pickBootstrapArchiveFile" -> {
                    bootstrapArchivePickResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(
                            Intent.EXTRA_MIME_TYPES,
                            arrayOf(
                                "application/gzip",
                                "application/x-gzip",
                                "application/x-gtar",
                                "application/x-tar",
                                "application/x-xz",
                                "application/octet-stream"
                            )
                        )
                    }
                    startActivityForResult(intent, BOOTSTRAP_ARCHIVE_PICK_REQUEST)
                }
                "exportWorkspaceBackup" -> {
                    val suggestedName = call.argument<String>("suggestedName")
                    val appVersion = call.argument<String>("appVersion")
                    val hermesVersion = call.argument<String>("hermesVersion")
                    if (suggestedName.isNullOrBlank() || appVersion.isNullOrBlank()) {
                        result.error(
                            "INVALID_ARGS",
                            "suggestedName and appVersion required",
                            null
                        )
                    } else {
                        workspaceBackupSaveResult = result
                        pendingWorkspaceBackupName = suggestedName
                        pendingWorkspaceBackupAppVersion = appVersion
                        pendingWorkspaceBackupHermesVersion = hermesVersion
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/zip"
                            putExtra(Intent.EXTRA_TITLE, suggestedName)
                        }
                        startActivityForResult(intent, WORKSPACE_BACKUP_SAVE_REQUEST)
                    }
                }
                "inspectWorkspaceBackup" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        Thread {
                            try {
                                val metadata = bootstrapManager.inspectWorkspaceBackup(path)
                                runOnUiThread { result.success(metadata) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "WORKSPACE_BACKUP_INSPECT_ERROR",
                                        e.message,
                                        null
                                    )
                                }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "path required", null)
                    }
                }
                "restoreWorkspaceBackup" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        Thread {
                            try {
                                bootstrapManager.restoreWorkspaceBackup(path)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "WORKSPACE_BACKUP_RESTORE_ERROR",
                                        e.message,
                                        null
                                    )
                                }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "path required", null)
                    }
                }
                "copyToClipboard" -> {
                    val text = call.argument<String>("text")
                    if (text != null) {
                        val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newPlainText("URL", text))
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGS", "text required", null)
                    }
                }
                "requestScreenCapture" -> {
                    val durationMs = call.argument<Int>("durationMs")?.toLong() ?: 5000L
                    screenCaptureResult = result
                    screenCaptureDurationMs = durationMs
                    ScreenCaptureService.clearResult()
                    val projectionManager =
                        getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                    startActivityForResult(
                        projectionManager.createScreenCaptureIntent(),
                        SCREEN_CAPTURE_REQUEST
                    )
                }
                "stopScreenCapture" -> {
                    try {
                        stopService(Intent(applicationContext, ScreenCaptureService::class.java))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "vibrate" -> {
                    val durationMs = call.argument<Int>("durationMs")?.toLong() ?: 200L
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val vibratorManager =
                                getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                            val vibrator = vibratorManager.defaultVibrator
                            vibrator.vibrate(
                                VibrationEffect.createOneShot(durationMs, VibrationEffect.DEFAULT_AMPLITUDE)
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                vibrator.vibrate(
                                    VibrationEffect.createOneShot(durationMs, VibrationEffect.DEFAULT_AMPLITUDE)
                                )
                            } else {
                                @Suppress("DEPRECATION")
                                vibrator.vibrate(durationMs)
                            }
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("VIBRATE_ERROR", e.message, null)
                    }
                }
                "requestStoragePermission" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            // Android 11+: MANAGE_EXTERNAL_STORAGE
                            if (!Environment.isExternalStorageManager()) {
                                val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                startActivity(intent)
                            }
                        } else {
                            // Android 10 and below: READ/WRITE_EXTERNAL_STORAGE
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(
                                    Manifest.permission.READ_EXTERNAL_STORAGE,
                                    Manifest.permission.WRITE_EXTERNAL_STORAGE
                                ),
                                STORAGE_PERMISSION_REQUEST
                            )
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STORAGE_ERROR", e.message, null)
                    }
                }
                "hasStoragePermission" -> {
                    val hasPermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Environment.isExternalStorageManager()
                    } else {
                        ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
                    }
                    result.success(hasPermission)
                }
                "getExternalStoragePath" -> {
                    result.success(Environment.getExternalStorageDirectory().absolutePath)
                }
                "installApk" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath != null) {
                        try {
                            installApk(apkPath, result)
                        } catch (e: Exception) {
                            result.error("APK_INSTALL_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_ARGS", "apkPath required", null)
                    }
                }
                "readRootfsFile" -> {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        Thread {
                            try {
                                val content = bootstrapManager.readRootfsFile(path)
                                runOnUiThread { result.success(content) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("ROOTFS_READ_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "path required", null)
                    }
                }
                "writeRootfsFile" -> {
                    val path = call.argument<String>("path")
                    val content = call.argument<String>("content")
                    if (path != null && content != null) {
                        Thread {
                            try {
                                bootstrapManager.writeRootfsFile(path, content)
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("ROOTFS_WRITE_ERROR", e.message, null) }
                            }
                        }.start()
                    } else {
                        result.error("INVALID_ARGS", "path and content required", null)
                    }
                }
                "bringToForeground" -> {
                    try {
                        val intent = Intent(applicationContext, MainActivity::class.java).apply {
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                        }
                        applicationContext.startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("FOREGROUND_ERROR", e.message, null)
                    }
                }
                "readSensor" -> {
                    val sensorType = call.argument<String>("sensor") ?: "accelerometer"
                    Thread {
                        try {
                            val sensorManager =
                                getSystemService(Context.SENSOR_SERVICE) as SensorManager
                            val type = when (sensorType) {
                                "accelerometer" -> Sensor.TYPE_ACCELEROMETER
                                "gyroscope" -> Sensor.TYPE_GYROSCOPE
                                "magnetometer" -> Sensor.TYPE_MAGNETIC_FIELD
                                "barometer" -> Sensor.TYPE_PRESSURE
                                else -> Sensor.TYPE_ACCELEROMETER
                            }
                            val sensor = sensorManager.getDefaultSensor(type)
                            if (sensor == null) {
                                runOnUiThread {
                                    result.error("SENSOR_ERROR", "Sensor $sensorType not available", null)
                                }
                                return@Thread
                            }
                            // Fix #8: Use AtomicBoolean to prevent double result submission
                            val replied = AtomicBoolean(false)
                            val listener = object : SensorEventListener {
                                override fun onSensorChanged(event: SensorEvent?) {
                                    if (!replied.compareAndSet(false, true) || event == null) return
                                    sensorManager.unregisterListener(this)
                                    val data = hashMapOf<String, Any>(
                                        "sensor" to sensorType,
                                        "timestamp" to event.timestamp,
                                        "accuracy" to event.accuracy
                                    )
                                    when (sensorType) {
                                        "accelerometer", "gyroscope", "magnetometer" -> {
                                            data["x"] = event.values[0].toDouble()
                                            data["y"] = event.values[1].toDouble()
                                            data["z"] = event.values[2].toDouble()
                                        }
                                        "barometer" -> {
                                            data["pressure"] = event.values[0].toDouble()
                                        }
                                    }
                                    runOnUiThread { result.success(data) }
                                }
                                override fun onAccuracyChanged(s: Sensor?, accuracy: Int) {}
                            }
                            sensorManager.registerListener(
                                listener, sensor, SensorManager.SENSOR_DELAY_NORMAL
                            )
                            // Timeout after 3 seconds
                            Thread.sleep(3000)
                            if (replied.compareAndSet(false, true)) {
                                sensorManager.unregisterListener(listener)
                                runOnUiThread {
                                    result.error("SENSOR_ERROR", "Sensor read timed out", null)
                                }
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SENSOR_ERROR", e.message, null) }
                        }
                    }.start()
                }

                // =====================================================================
                // Accessibility Service — UI Automation
                // =====================================================================

                "isAccessibilityServiceRunning" -> {
                    result.success(AutoService.isConnected())
                }

                "openAccessibilitySettings" -> {
                    try {
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("A11Y_ERROR", e.message, null)
                    }
                }

                "a11yDumpTree" -> {
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val xml = service.dumpUITree()
                                runOnUiThread { result.success(xml) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yTap" -> {
                    val x = call.argument<Int>("x") ?: -1
                    val y = call.argument<Int>("y") ?: -1
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val ok = service.tapViaGesture(x, y)
                                runOnUiThread { result.success(ok) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11ySwipe" -> {
                    val x1 = call.argument<Int>("x1") ?: -1
                    val y1 = call.argument<Int>("y1") ?: -1
                    val x2 = call.argument<Int>("x2") ?: -1
                    val y2 = call.argument<Int>("y2") ?: -1
                    val duration = call.argument<Int>("duration")?.toLong() ?: 300L
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val ok = service.swipe(x1, y1, x2, y2, duration)
                                runOnUiThread { result.success(ok) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yInput" -> {
                    val text = call.argument<String>("text") ?: ""
                    val append = call.argument<Boolean>("append") ?: false
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val ok = service.inputText(text, append)
                                runOnUiThread { result.success(ok) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yKey" -> {
                    val key = call.argument<String>("key") ?: ""
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val ok = when (key.lowercase()) {
                                    "back" -> service.pressBack()
                                    "home" -> service.pressHome()
                                    "recents", "recent" -> service.pressRecents()
                                    "notifications" -> service.openNotifications()
                                    else -> false
                                }
                                runOnUiThread { result.success(ok) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yScroll" -> {
                    val direction = call.argument<String>("direction") ?: "down"
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val ok = when (direction.lowercase()) {
                                    "up" -> service.scrollUp()
                                    "down" -> service.scrollDown()
                                    "left" -> service.scrollLeft()
                                    "right" -> service.scrollRight()
                                    else -> service.scrollDown()
                                }
                                runOnUiThread { result.success(ok) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yFind" -> {
                    val text = call.argument<String>("text")?.ifEmpty { null }
                    val id = call.argument<String>("id")?.ifEmpty { null }
                    val desc = call.argument<String>("description")?.ifEmpty { null }
                    val className = call.argument<String>("class_name")?.ifEmpty { null }
                    val clickableOnly = call.argument<Boolean>("clickable_only") ?: false
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val nodes = service.findElements(
                                    text = text, id = id, description = desc,
                                    className = className, clickableOnly = clickableOnly
                                )
                                runOnUiThread { result.success(nodes) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yWait" -> {
                    val text = call.argument<String>("text")?.ifEmpty { null }
                    val id = call.argument<String>("id")?.ifEmpty { null }
                    val desc = call.argument<String>("description")?.ifEmpty { null }
                    val timeout = call.argument<Int>("timeout")?.toLong() ?: 5000L
                    val pollInterval = call.argument<Int>("poll_interval")?.toLong() ?: 300L
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val found = service.waitForElement(
                                    text = text, id = id, description = desc,
                                    timeoutMs = timeout, pollIntervalMs = pollInterval
                                )
                                runOnUiThread { result.success(found != null) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yClickText" -> {
                    val text = call.argument<String>("text") ?: ""
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val ok = service.clickText(text)
                                runOnUiThread { result.success(ok) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yClickId" -> {
                    val id = call.argument<String>("id") ?: ""
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val ok = service.clickById(id)
                                runOnUiThread { result.success(ok) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yScreenshot" -> {
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val file = java.io.File(cacheDir, "a11y_screenshot.jpg")
                                val latch = java.util.concurrent.CountDownLatch(1)
                                val ok = service.takeScreenshot(file.absolutePath, latch)
                                if (!ok) {
                                    runOnUiThread { result.error("A11Y_ERROR", "Screenshot failed (requires Android 11+)", null) }
                                    return@Thread
                                }
                                latch.await(5, java.util.concurrent.TimeUnit.SECONDS)
                                if (file.exists() && file.length() > 0) {
                                    val bytes = file.readBytes()
                                    val b64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
                                    file.delete()
                                    runOnUiThread { result.success(b64) }
                                } else {
                                    file.delete()
                                    runOnUiThread { result.error("A11Y_ERROR", "Screenshot file not ready", null) }
                                }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yCurrentApp" -> {
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val app = service.getCurrentApp()
                                runOnUiThread {
                                    result.success(hashMapOf(
                                        "package_name" to (app?.get("package_name") ?: ""),
                                        "app_name" to (app?.get("app_name") ?: ""),
                                        "activity" to (app?.get("activity") ?: "")
                                    ))
                                }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yDeviceInfo" -> {
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val info = service.getDeviceInfo()
                                runOnUiThread { result.success(info.mapValues { it.value.toString() }) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yClipboardRead" -> {
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        try {
                            val text = service.readClipboard()
                            result.success(text ?: "")
                        } catch (e: Exception) {
                            result.error("A11Y_ERROR", e.message, null)
                        }
                    }
                }

                "a11yClipboardWrite" -> {
                    val text = call.argument<String>("text") ?: ""
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        try {
                            val ok = service.writeClipboard(text)
                            result.success(ok)
                        } catch (e: Exception) {
                            result.error("A11Y_ERROR", e.message, null)
                        }
                    }
                }

                "a11yVolume" -> {
                    val stream = call.argument<String>("stream") ?: ""
                    val level = call.argument<Int>("level") ?: -1
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        try {
                            if (stream.isEmpty() && level < 0) {
                                val info = service.getVolumeInfo()
                                result.success(info.mapValues { it.value.toString() })
                            } else if (stream.isNotEmpty() && level >= 0) {
                                val ok = service.setVolume(stream, level)
                                result.success(ok)
                            } else {
                                result.error("A11Y_INVALID_ARGS", "Provide 'stream'+'level' to set, or empty to get", null)
                            }
                        } catch (e: Exception) {
                            result.error("A11Y_ERROR", e.message, null)
                        }
                    }
                }

                "a11yColor" -> {
                    val x = call.argument<Int>("x") ?: -1
                    val y = call.argument<Int>("y") ?: -1
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val color = service.getPixelColor(x, y)
                                runOnUiThread { result.success(color ?: "") }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yInstalledApps" -> {
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val apps = service.getInstalledApps()
                                runOnUiThread { result.success(apps) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yLaunchApp" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    val action = call.argument<String>("action") ?: ""
                    val uri = call.argument<String>("uri") ?: ""
                    val type = call.argument<String>("type") ?: ""
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val ok = service.launchApp(
                                    packageName = pkg.ifEmpty { null },
                                    action = action.ifEmpty { null },
                                    uri = uri.ifEmpty { null },
                                    type = type.ifEmpty { null }
                                )
                                runOnUiThread { result.success(ok) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yOcr" -> {
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        Thread {
                            try {
                                val file = java.io.File(cacheDir, "a11y_ocr_temp.jpg")
                                val latch = java.util.concurrent.CountDownLatch(1)
                                val ok = service.takeScreenshot(file.absolutePath, latch)
                                if (!ok) {
                                    runOnUiThread { result.error("A11Y_ERROR", "Screenshot failed (requires Android 11+)", null) }
                                    return@Thread
                                }
                                latch.await(5, java.util.concurrent.TimeUnit.SECONDS)
                                if (!file.exists() || file.length() == 0L) {
                                    file.delete()
                                    runOnUiThread { result.error("A11Y_ERROR", "Screenshot file not ready", null) }
                                    return@Thread
                                }
                                val blocks = OcrHelper.recognizeFromFile(file.absolutePath)
                                val json = OcrHelper.blocksToJsonString(blocks)
                                file.delete()
                                runOnUiThread { result.success(json) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("A11Y_ERROR", e.message, null) }
                            }
                        }.start()
                    }
                }

                "a11yHasUsageStatsPermission" -> {
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        result.success(service.hasUsageStatsPermission())
                    }
                }

                "a11yOpenUsageStatsSettings" -> {
                    val service = AutoService.instance
                    if (service == null) {
                        result.error("A11Y_NOT_RUNNING", "Accessibility service not connected", null)
                    } else {
                        service.openUsageStatsSettings()
                        result.success(true)
                    }
                }

                // =====================================================================
                // Toast
                // =====================================================================

                "showToast" -> {
                    val message = call.argument<String>("message") ?: ""
                    val isLong = call.argument<Boolean>("long") ?: false
                    if (message.isEmpty()) {
                        result.error("INVALID_ARGS", "message required", null)
                    } else {
                        try {
                            val duration = if (isLong) android.widget.Toast.LENGTH_LONG
                                           else android.widget.Toast.LENGTH_SHORT
                            android.os.Handler(android.os.Looper.getMainLooper()).post {
                                android.widget.Toast.makeText(applicationContext, message, duration).show()
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("TOAST_ERROR", e.message, null)
                        }
                    }
                }

                // =====================================================================
                // JS Bridge — WebSocket Server for browser JS injection
                // =====================================================================

                "startJsBridge" -> {
                    val port = call.argument<Int>("port") ?: 8767
                    Thread {
                        try {
                            if (JsBridgeServer.getInstance() != null) {
                                runOnUiThread { result.success(true) }
                                return@Thread
                            }
                            val server = JsBridgeServer(port)
                            server.start()
                            // 等待端口就绪
                            Thread.sleep(500)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            Log.e("MainActivity", "Failed to start JsBridgeServer", e)
                            runOnUiThread { result.error("JS_BRIDGE_ERROR", e.message, null) }
                        }
                    }.start()
                }

                "stopJsBridge" -> {
                    try {
                        JsBridgeServer.getInstance()?.stop(1000)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("JS_BRIDGE_ERROR", e.message, null)
                    }
                }

                "isJsBridgeRunning" -> {
                    result.success(JsBridgeServer.getInstance() != null)
                }

                "jsBridgeInfo" -> {
                    val server = JsBridgeServer.getInstance()
                    if (server == null) {
                        result.success(hashMapOf(
                            "status" to "stopped",
                            "browser_clients" to "0"
                        ))
                    } else {
                        val info = server.getInfo()
                        result.success(info.mapValues { it.value.toString() })
                    }
                }

                "execJsOnBrowser" -> {
                    val code = call.argument<String>("code") ?: ""
                    val timeoutMs = call.argument<Int>("timeout_ms")?.toLong() ?: 10000L
                    if (code.isBlank()) {
                        result.error("INVALID_ARGS", "code required", null)
                    } else {
                        val server = JsBridgeServer.getInstance()
                        if (server == null) {
                            result.error("JS_BRIDGE_NOT_RUNNING", "JS Bridge server not started", null)
                        } else {
                            Thread {
                                try {
                                    val jsResult = server.execJs(code, timeoutMs)
                                    val ok = jsResult.optBoolean("ok", false)
                                    if (ok) {
                                        val resValue = jsResult.opt("result")?.toString() ?: ""
                                        runOnUiThread { result.success(resValue) }
                                    } else {
                                        val err = jsResult.optString("error", "Unknown error")
                                        runOnUiThread { result.error("JS_EXEC_ERROR", err, null) }
                                    }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("JS_EXEC_ERROR", e.message, null) }
                                }
                            }.start()
                        }
                    }
                }

                "getJsBridgeUserscript" -> {
                    val serverIp = call.argument<String>("server_ip") ?: "127.0.0.1"
                    val serverPort = call.argument<Int>("server_port") ?: 8767
                    val script = generateJsUserscript(serverIp, serverPort)
                    result.success(script)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }

        createUrlNotificationChannel()
        requestNotificationPermission()

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    GatewayService.logSink = events
                }
                override fun onCancel(arguments: Any?) {
                    GatewayService.logSink = null
                }
            }
        )

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SETUP_LOG_EVENT_CHANNEL
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    setupLogSink = events
                }

                override fun onCancel(arguments: Any?) {
                    setupLogSink = null
                }
            }
        )
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_REQUEST
                )
            }
        }
    }

    private fun createUrlNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                URL_CHANNEL_ID,
                "Hermes URLs",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications for detected URLs"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun getWebViewPackageInfo(): Map<String, Any?> {
        return try {
            val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WebView.getCurrentWebViewPackage()
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo("com.google.android.webview", 0)
            }
            hashMapOf(
                "packageName" to packageInfo?.packageName,
                "versionName" to packageInfo?.versionName,
                "majorVersion" to parseMajorVersion(packageInfo?.versionName)
            )
        } catch (_: Exception) {
            hashMapOf(
                "packageName" to null,
                "versionName" to null,
                "majorVersion" to null
            )
        }
    }

    private fun parseMajorVersion(versionName: String?): Int? {
        if (versionName.isNullOrBlank()) {
            return null
        }
        return versionName.substringBefore('.').toIntOrNull()
    }

    private var urlNotificationId = 100

    private fun showUrlNotification(url: String, title: String) {
        val openIntent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        val openPending = PendingIntent.getActivity(
            this, urlNotificationId, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, URL_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(url)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentIntent(openPending)
                .setAutoCancel(true)
                .setStyle(Notification.BigTextStyle().bigText(url))
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle(title)
                .setContentText(url)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentIntent(openPending)
                .setAutoCancel(true)
                .build()
        }

        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(urlNotificationId++, notification)
    }

    private fun installApk(apkPath: String, result: MethodChannel.Result) {
        val apkFile = File(apkPath)
        if (!apkFile.exists()) {
            throw IllegalArgumentException("APK not found: $apkPath")
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            pendingApkInstallResult = result
            pendingApkInstallPath = apkPath

            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            )
            startActivityForResult(intent, INSTALL_UNKNOWN_APP_SOURCES_REQUEST)
            return
        }

        launchApkInstaller(apkFile)
        result.success(true)
    }

    private fun launchApkInstaller(apkFile: File) {
        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apkFile
        )

        val installIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        startActivity(installIntent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == INSTALL_UNKNOWN_APP_SOURCES_REQUEST) {
            val pendingResult = pendingApkInstallResult
            val pendingPath = pendingApkInstallPath
            pendingApkInstallResult = null
            pendingApkInstallPath = null

            if (pendingResult == null || pendingPath == null) {
                return
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                pendingResult.error(
                    "APK_INSTALL_PERMISSION_DENIED",
                    "Install unknown apps permission not granted.",
                    null
                )
                return
            }

            try {
                val apkFile = File(pendingPath)
                if (!apkFile.exists()) {
                    pendingResult.error(
                        "APK_INSTALL_ERROR",
                        "APK not found: $pendingPath",
                        null
                    )
                    return
                }

                launchApkInstaller(apkFile)
                pendingResult.success(true)
            } catch (e: Exception) {
                pendingResult.error("APK_INSTALL_ERROR", e.message, null)
            }
            return
        }

        if (requestCode == SCREEN_CAPTURE_REQUEST) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val intent = Intent(applicationContext, ScreenCaptureService::class.java).apply {
                    putExtra("resultCode", resultCode)
                    putExtra("data", data)
                    putExtra("durationMs", screenCaptureDurationMs)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(intent)
                } else {
                    startService(intent)
                }
                // Poll for result
                Thread {
                    val startTime = System.currentTimeMillis()
                    val timeout = screenCaptureDurationMs + 5000L
                    while (ScreenCaptureService.resultPath == null &&
                        System.currentTimeMillis() - startTime < timeout
                    ) {
                        Thread.sleep(200)
                    }
                    val path = ScreenCaptureService.resultPath
                    runOnUiThread {
                        screenCaptureResult?.success(path)
                        screenCaptureResult = null
                    }
                }.start()
            } else {
                screenCaptureResult?.success(null)
                screenCaptureResult = null
            }
            return
        }

        if (requestCode == SNAPSHOT_PICK_REQUEST) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                try {
                    val uri = data.data!!
                    val content = contentResolver.openInputStream(uri)
                        ?.bufferedReader()
                        ?.use { it.readText() }
                    val name = uri.lastPathSegment?.substringAfterLast('/') ?: "snapshot.json"
                    snapshotPickResult?.success(
                        hashMapOf(
                            "name" to name,
                            "content" to content
                        )
                    )
                } catch (e: Exception) {
                    snapshotPickResult?.error("SNAPSHOT_PICK_ERROR", e.message, null)
                } finally {
                    snapshotPickResult = null
                }
            } else {
                snapshotPickResult?.success(null)
                snapshotPickResult = null
            }
            return
        }

        if (requestCode == SNAPSHOT_SAVE_REQUEST) {
            val pendingResult = snapshotSaveResult
            val pendingContent = pendingSnapshotContent
            val pendingName = pendingSnapshotName
            snapshotSaveResult = null
            pendingSnapshotContent = null
            pendingSnapshotName = null

            if (pendingResult == null || pendingContent == null || pendingName == null) {
                return
            }

            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                try {
                    val uri = data.data!!
                    contentResolver.openOutputStream(uri, "wt")?.bufferedWriter()?.use {
                        it.write(pendingContent)
                    } ?: throw IllegalStateException("Unable to open destination for writing")

                    pendingResult.success(
                        hashMapOf(
                            "name" to queryDisplayName(uri, pendingName),
                            "uri" to uri.toString()
                        )
                    )
                } catch (e: Exception) {
                    pendingResult.error("SNAPSHOT_SAVE_ERROR", e.message, null)
                }
            } else {
                pendingResult.success(null)
            }
            return
        }

        if (requestCode == BACKUP_PICK_REQUEST) {
            val pendingResult = backupPickResult
            if (pendingResult == null) {
                return
            }

            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                Thread {
                    try {
                        val fallbackName =
                            uri.lastPathSegment?.substringAfterLast('/') ?: "backup"
                        val name = queryDisplayName(uri, fallbackName)
                        val cached = copyUriToCache(uri, name)
                        runOnUiThread {
                            pendingResult.success(
                                hashMapOf(
                                    "name" to name,
                                    "path" to cached.absolutePath
                                )
                            )
                        }
                    } catch (e: Exception) {
                        runOnUiThread {
                            pendingResult.error("BACKUP_PICK_ERROR", e.message, null)
                        }
                    } finally {
                        backupPickResult = null
                    }
                }.start()
            } else {
                pendingResult.success(null)
                backupPickResult = null
            }
            return
        }

        if (requestCode == BOOTSTRAP_ARCHIVE_PICK_REQUEST) {
            val pendingResult = bootstrapArchivePickResult
            if (pendingResult == null) {
                return
            }

            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                Thread {
                    try {
                        val fallbackName =
                            uri.lastPathSegment?.substringAfterLast('/')
                                ?: "hermes-prebuilt-rootfs.tar.gz"
                        val name = queryDisplayName(uri, fallbackName)
                        val cached = copyBootstrapArchiveToCache(uri, name)
                        runOnUiThread {
                            pendingResult.success(
                                hashMapOf(
                                    "name" to name,
                                    "path" to cached.absolutePath
                                )
                            )
                        }
                    } catch (e: Exception) {
                        runOnUiThread {
                            pendingResult.error("BOOTSTRAP_ARCHIVE_PICK_ERROR", e.message, null)
                        }
                    } finally {
                        bootstrapArchivePickResult = null
                    }
                }.start()
            } else {
                pendingResult.success(null)
                bootstrapArchivePickResult = null
            }
            return
        }

        if (requestCode == WORKSPACE_BACKUP_SAVE_REQUEST) {
            val pendingResult = workspaceBackupSaveResult
            val pendingName = pendingWorkspaceBackupName
            val pendingAppVersion = pendingWorkspaceBackupAppVersion
            val pendingHermesVersion = pendingWorkspaceBackupHermesVersion
            workspaceBackupSaveResult = null
            pendingWorkspaceBackupName = null
            pendingWorkspaceBackupAppVersion = null
            pendingWorkspaceBackupHermesVersion = null

            if (pendingResult == null || pendingName == null || pendingAppVersion == null) {
                return
            }

            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                Thread {
                    try {
                        contentResolver.openOutputStream(uri, "w")?.use { output ->
                            bootstrapManager.exportWorkspaceBackup(
                                output = output,
                                appVersion = pendingAppVersion,
                                hermesVersion = pendingHermesVersion
                            )
                        } ?: throw IllegalStateException(
                            "Unable to open destination for writing"
                        )

                        runOnUiThread {
                            pendingResult.success(
                                hashMapOf(
                                    "name" to queryDisplayName(uri, pendingName),
                                    "uri" to uri.toString()
                                )
                            )
                        }
                    } catch (e: Exception) {
                        runOnUiThread {
                            pendingResult.error(
                                "WORKSPACE_BACKUP_SAVE_ERROR",
                                e.message,
                                null
                            )
                        }
                    }
                }.start()
            } else {
                pendingResult.success(null)
            }
            return
        }
    }

    private fun copyUriToCache(uri: Uri, fileName: String): File {
        val sanitizedName = sanitizeDocumentFileName(fileName)
        val cacheFile = File(
            cacheDir,
            "backup-import-${System.currentTimeMillis()}-$sanitizedName"
        )
        contentResolver.openInputStream(uri)?.use { input ->
            cacheFile.outputStream().use { output ->
                input.copyTo(output)
            }
        } ?: throw IllegalStateException("Unable to open source file")
        return cacheFile
    }

    private fun copyBootstrapArchiveToCache(uri: Uri, fileName: String): File {
        val sanitizedName = sanitizeDocumentFileName(fileName)
        val cacheFile = File(
            cacheDir,
            "bootstrap-archive-${System.currentTimeMillis()}-$sanitizedName"
        )
        contentResolver.openInputStream(uri)?.use { input ->
            cacheFile.outputStream().use { output ->
                input.copyTo(output)
            }
        } ?: throw IllegalStateException("Unable to open source file")
        return cacheFile
    }

    private fun sanitizeDocumentFileName(fileName: String): String {
        val normalized = fileName.trim().ifEmpty { "backup" }
        val sanitized = normalized
            .replace(Regex("[^A-Za-z0-9._-]+"), "-")
            .trim('-')
            .ifEmpty { "backup" }
        return sanitized.take(96)
    }

    private fun queryDisplayName(uri: Uri, fallback: String): String {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (index >= 0) {
                            cursor.getString(index) ?: fallback
                        } else {
                            fallback
                        }
                    } else {
                        fallback
                    }
                } ?: fallback
        } catch (_: Exception) {
            fallback
        }
    }

    /**
     * 生成浏览器油猴脚本 — 让浏览器连接到 JsBridgeServer
     */
    private fun generateJsUserscript(serverIp: String, serverPort: Int): String {
        return """
// ==UserScript==
// @name         Hermes JS Bridge
// @namespace    hermes-agent
// @version      2.0
// @description  接收 Hermes Agent 下发的 JS 命令并在当前页面执行，结果回传
// @match        *://*/*
// @grant        none
// @run-at       document-idle
// ==/UserScript==

(function() {
    'use strict';

    // ── 配置 ──
    const WS_URL = 'ws://${serverIp}:${serverPort}';
    const RECONNECT_DELAY = 3000;
    const PING_INTERVAL = 25000;

    let ws = null;
    let pingTimer = null;
    let connected = false;

    // ── 状态指示 ──
    const badge = document.createElement('div');
    Object.assign(badge.style, {
        position: 'fixed', bottom: '8px', right: '8px', zIndex: 2147483647,
        padding: '4px 10px', borderRadius: '12px', fontSize: '12px',
        fontFamily: 'monospace', color: '#fff', cursor: 'pointer',
        transition: 'opacity 0.3s', opacity: '0.7',
        background: '#e53935',
        boxShadow: '0 2px 8px rgba(0,0,0,0.3)',
    });
    badge.textContent = 'Hermes: disconnected';
    badge.title = 'Hermes JS Bridge — 点击重连';
    badge.onclick = () => { ws && ws.close(); connect(); };
    document.body.appendChild(badge);

    function setStatus(ok) {
        connected = ok;
        badge.style.background = ok ? '#43a047' : '#e53935';
        badge.textContent = ok ? 'Hermes: connected' : 'Hermes: disconnected';
    }

    // ── 核心：执行 JS 并返回结果 ──
    function executeJS(code) {
        try {
            // 先尝试当表达式求值
            const fn = new Function('return (' + code + ')');
            const result = fn();
            if (result && typeof result.then === 'function') {
                return result.then(
                    val => ({ ok: true, result: safeStringify(val) }),
                    err => ({ ok: false, error: String(err) })
                );
            }
            return Promise.resolve({ ok: true, result: safeStringify(result) });
        } catch (e) {
            // 不是表达式，尝试当语句执行
            try {
                const fn2 = new Function(code);
                const result2 = fn2();
                if (result2 && typeof result2.then === 'function') {
                    return result2.then(
                        val => ({ ok: true, result: safeStringify(val) }),
                        err => ({ ok: false, error: String(err) })
                    );
                }
                return Promise.resolve({ ok: true, result: safeStringify(result2) });
            } catch (e2) {
                return Promise.resolve({ ok: false, error: String(e2) });
            }
        }
    }

    function safeStringify(val) {
        if (val === undefined) return 'undefined';
        if (val === null) return 'null';
        try {
            return typeof val === 'string' ? val : JSON.stringify(val);
        } catch {
            return String(val);
        }
    }

    // ── WebSocket 连接 ──
    function connect() {
        if (ws && ws.readyState <= 1) return;

        try {
            ws = new WebSocket(WS_URL);
        } catch (e) {
            setStatus(false);
            scheduleReconnect();
            return;
        }

        ws.onopen = () => {
            setStatus(true);
            ws.send(JSON.stringify({ type: 'register', client_type: 'browser' }));
            pingTimer = setInterval(() => {
                if (ws.readyState === 1) ws.send(JSON.stringify({ type: 'ping' }));
            }, PING_INTERVAL);
        };

        ws.onmessage = (e) => {
            let msg;
            try { msg = JSON.parse(e.data); } catch { return; }

            if (msg.type === 'js_exec' && msg.id) {
                executeJS(msg.code).then(result => {
                    if (ws.readyState === 1) {
                        ws.send(JSON.stringify({
                            type: 'js_result',
                            id: msg.id,
                            ...result,
                        }));
                    }
                });
            }
        };

        ws.onclose = () => {
            setStatus(false);
            clearInterval(pingTimer);
            scheduleReconnect();
        };

        ws.onerror = () => {
            setStatus(false);
        };
    }

    function scheduleReconnect() {
        setTimeout(connect, RECONNECT_DELAY);
    }

    // ── 启动 ──
    connect();
})();
""".trimIndent()
    }

    companion object {
        const val URL_CHANNEL_ID = "hermes_urls"
        const val NOTIFICATION_PERMISSION_REQUEST = 1001
        const val SCREEN_CAPTURE_REQUEST = 1002
        const val STORAGE_PERMISSION_REQUEST = 1003
        const val SNAPSHOT_PICK_REQUEST = 1004
        const val INSTALL_UNKNOWN_APP_SOURCES_REQUEST = 1005
        const val SNAPSHOT_SAVE_REQUEST = 1006
        const val BACKUP_PICK_REQUEST = 1007
        const val WORKSPACE_BACKUP_SAVE_REQUEST = 1008
        const val BOOTSTRAP_ARCHIVE_PICK_REQUEST = 1009
    }

    /**
     * Ensure hermes_cli/__main__.py exists inside the rootfs.
     * The official NousResearch install.sh doesn't create this file,
     * but python3 -m hermes_cli requires it to run.
     * Called on every app start to repair after installs or APK updates.
     */
    private fun fixHermesMainPy(filesDir: String) {
        val rootfsDir = "$filesDir/rootfs/ubuntu"
        val candidates = listOf(
            "$rootfsDir/usr/local/lib/python3/dist-packages/hermes_cli",
            "$rootfsDir/usr/lib/python3/dist-packages/hermes_cli",
        ) + listOf("3.12", "3.11", "3.10", "3.13").map { ver ->
            "$rootfsDir/usr/local/lib/python$ver/dist-packages/hermes_cli"
        }

        for (dir in candidates) {
            val initFile = File(dir, "__init__.py")
            val mainFile = File(dir, "__main__.py")
            if (initFile.exists() && !mainFile.exists()) {
                mainFile.writeText("from hermes_cli.main import main\nmain()\n")
                break
            }
        }
    }
}
