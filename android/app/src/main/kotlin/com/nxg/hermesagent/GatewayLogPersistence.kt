package com.nousresearch.hermes

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.channels.FileLock

object GatewayLogPersistence {
    private const val PREFS_NAME = "hermes_gateway"
    private const val KEY_ENABLED = "persistent_gateway_logs_enabled"
    private const val MAX_LOG_BYTES = 5L * 1024 * 1024
    private const val MAX_LOG_FILES = 3
    private const val LOG_RELATIVE_PATH = "rootfs/ubuntu/root/hermes.log"
    private const val TAG = "GatewayLogPersistence"

    @Volatile
    private var cachedEnabled: Boolean? = null

    fun isEnabled(context: Context): Boolean {
        cachedEnabled?.let { return it }
        val enabled = context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_ENABLED, false)
        cachedEnabled = enabled
        return enabled
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ENABLED, enabled)
            .apply()
        cachedEnabled = enabled
    }

    // Fix #10: Use file-level locking to protect rotation across threads.
    // The @Synchronized on appendLine protects within-JVM concurrency;
    // FileChannel.tryLock() adds defense-in-depth for rotation operations.
    @Synchronized
    fun appendLine(context: Context, line: String) {
        if (!isEnabled(context)) return

        try {
            val logFile = File(context.filesDir, LOG_RELATIVE_PATH)
            logFile.parentFile?.mkdirs()

            val payload = (line + "\n").toByteArray(Charsets.UTF_8)
            rotateIfNeeded(logFile, payload.size.toLong())

            FileOutputStream(logFile, true).use { output ->
                output.write(payload)
                output.flush()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to append persistent gateway log", e)
        }
    }

    private fun rotateIfNeeded(logFile: File, incomingBytes: Long) {
        if (!logFile.exists()) return
        if (logFile.length() + incomingBytes <= MAX_LOG_BYTES) return

        val parent = logFile.parentFile ?: return

        // Use file lock to protect the rotation sequence
        val lockFile = File(parent, "${logFile.name}.lock")
        var lock: FileLock? = null
        try {
            FileOutputStream(lockFile, false).use { lockStream ->
                lock = lockStream.channel.tryLock()
                if (lock == null) {
                    // Another thread/process is rotating — skip
                    return
                }

                // Re-check size after acquiring lock (another thread may have rotated)
                if (!logFile.exists() || logFile.length() + incomingBytes <= MAX_LOG_BYTES) {
                    return
                }

                val oldest = File(parent, "${logFile.name}.${MAX_LOG_FILES - 1}")
                if (oldest.exists()) {
                    oldest.delete()
                }

                for (index in (MAX_LOG_FILES - 2) downTo 1) {
                    val current = File(parent, "${logFile.name}.$index")
                    if (current.exists()) {
                        val next = File(parent, "${logFile.name}.${index + 1}")
                        if (!current.renameTo(next)) {
                            Log.w(TAG, "Failed to rotate log file: ${current.name}")
                        }
                    }
                }

                val firstRotated = File(parent, "${logFile.name}.1")
                if (!logFile.renameTo(firstRotated)) {
                    Log.w(TAG, "Failed to rotate current log file to .1")
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Log rotation failed", e)
        } finally {
            try { lock?.release() } catch (_: Exception) {}
            try { lockFile.delete() } catch (_: Exception) {}
        }
    }
}
