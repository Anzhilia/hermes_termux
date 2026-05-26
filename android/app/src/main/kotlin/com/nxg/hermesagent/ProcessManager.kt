package com.nousresearch.hermes

import android.os.Build
import android.os.Environment
import android.system.Os
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader

/**
 * Manages proot process execution, matching Termux proot-distro as closely
 * as possible. Two command modes:
 *   - Install mode (buildInstallCommand): matches proot-distro's run_proot_cmd()
 *   - Gateway mode (buildGatewayCommand): matches proot-distro's command_login()
 */
class ProcessManager(
    private val filesDir: String,
    private val nativeLibDir: String
) {
    private val rootfsDir get() = "$filesDir/rootfs/ubuntu"
    private val tmpDir get() = "$filesDir/tmp"
    private val homeDir get() = "$filesDir/home"
    private val configDir get() = "$filesDir/config"
    private val libDir get() = "$filesDir/lib"
    private val nativeRuntimeDir get() = "$filesDir/native"
    var installLogEmitter: ((String) -> Unit)? = null

    companion object {
        // Match proot-distro v4.37.0 defaults
        const val FAKE_KERNEL_RELEASE = "6.17.0-PRoot-Distro"
        const val FAKE_KERNEL_VERSION =
            "#1 SMP PREEMPT_DYNAMIC Fri, 10 Oct 2025 00:00:00 +0000"
    }

    private fun resolveHostNativePath(fileName: String): String {
        val directSource = File("$nativeLibDir/$fileName")
        if (directSource.exists() && directSource.length() > 0L) {
            return directSource.absolutePath
        }

        val runtimePath = File("$nativeRuntimeDir/$fileName")
        if (runtimePath.exists() && runtimePath.length() > 0L) {
            return runtimePath.absolutePath
        }

        throw IllegalStateException(
            "Native runtime binary is missing: $fileName (checked ${directSource.absolutePath} and ${runtimePath.absolutePath})"
        )
    }

    fun getProotPath(): String = resolveHostNativePath("libproot.so")

    // ================================================================
    // Host-side environment for proot binary itself.
    // ONLY proot-specific vars 鈥?guest env is set via `env -i` inside
    // the command line, matching proot-distro's approach.
    // ================================================================
    private fun prootEnv(): Map<String, String> {
        val env = mutableMapOf(
            // proot temp directory for its internal use
            "PROOT_TMP_DIR" to tmpDir,
            // Loader executables for proot's execve interception
            "PROOT_LOADER" to resolveHostNativePath("libprootloader.so"),
            "PROOT_LOADER_32" to resolveHostNativePath("libprootloader32.so"),
            // LD_LIBRARY_PATH: proot itself needs libtalloc.so.2
            // This does NOT leak into the guest (env -i cleans it)
            "LD_LIBRARY_PATH" to listOf(libDir, nativeLibDir, nativeRuntimeDir)
                .distinct()
                .joinToString(":"),
            // NOTE: Do NOT set PROOT_NO_SECCOMP. proot-distro does NOT set it.
            // Seccomp BPF filter provides efficient syscall interception AND
            // proper fork/clone child process tracking.
            //
            // NOTE: Do NOT set PROOT_L2S_DIR. We extract with Java, not
            // `proot --link2symlink tar`, so no L2S metadata exists.
        )
        // ★ Explicitly unset Python env vars that may leak from Android JVM.
        // install.sh does `unset PYTHONPATH; unset PYTHONHOME` — we must do
        // the same on the host side since ProcessBuilder inherits the full
        // JVM environment. Setting them to empty string prevents the dynamic
        // linker / Python from seeing stale values.
        env["PYTHONPATH"] = ""
        env["PYTHONHOME"] = ""
        return env
    }

    // ================================================================
    // Common proot flags shared by both install and gateway modes.
    // Matches proot-distro's bind mounts exactly.
    // ================================================================
    /**
     * Ensure resolv.conf exists before any proot invocation.
     * This is the single chokepoint 鈥?every proot operation flows through
     * commonProotFlags(), so resolv.conf is guaranteed for all callers.
     */
    private fun ensureResolvConf(): File? {
        val content = "nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n"

        // Ensure config directory exists (mkdirs can silently fail on some Android devices)
        val configDirFile = File(configDir)
        if (!configDirFile.isDirectory) {
            configDirFile.mkdirs()
            // Verify and retry via shell if mkdirs() silently failed
            if (!configDirFile.isDirectory) {
                try {
                    Runtime.getRuntime().exec(arrayOf("mkdir", "-p", configDir)).waitFor()
                } catch (_: Exception) {}
            }
            if (configDirFile.isDirectory) {
                configDirFile.setReadable(true, false)
                configDirFile.setWritable(true, false)
                configDirFile.setExecutable(true, false)
            }
        }

        val resolvFile = File("$configDir/resolv.conf")

        // Create the file if missing
        if (!resolvFile.exists()) {
            try {
                resolvFile.writeText(content)
                resolvFile.setReadable(true, false)
                resolvFile.setWritable(true, false)
            } catch (_: Exception) {}
        }

        // Verify file actually exists on disk (not just in Java's view)
        if (!resolvFile.exists() || !resolvFile.isFile) {
            // Last resort: shell write
            try {
                val proc = Runtime.getRuntime().exec(
                    arrayOf("sh", "-c", "mkdir -p $configDir && cat > $configDir/resolv.conf")
                )
                proc.outputStream.use { it.write(content.toByteArray()) }
                proc.waitFor()
            } catch (_: Exception) {}
        }

        // Final fallback: if file still doesn't exist, try writing with raw bytes
        if (!resolvFile.exists() || resolvFile.length() == 0L) {
            try {
                File(configDir).mkdirs()
                resolvFile.writeBytes(content.toByteArray(Charsets.UTF_8))
            } catch (_: Exception) {}
        }

        // Also ensure rootfs /etc/resolv.conf exists (fallback for bind-mount failure)
        try {
            val rootfsResolv = File("$rootfsDir/etc/resolv.conf")
            rootfsResolv.parentFile?.mkdirs()
            if (!rootfsResolv.exists()) {
                rootfsResolv.writeText(content)
                rootfsResolv.setReadable(true, false)
                rootfsResolv.setWritable(true, false)
            }
        } catch (_: Exception) {}

        // Verify the file actually exists on disk by attempting to read it.
        // Java File.exists() can return true on Android FUSE even when the
        // file doesn't physically exist, causing PRoot bind-mount failures.
        val verified = try {
            resolvFile.exists() && resolvFile.isFile && resolvFile.canRead() &&
                resolvFile.length() > 0
        } catch (_: Exception) {
            false
        }
        return if (verified) resolvFile else null
    }

    /**
     * Only bind stdio device paths when the host fd resolves to a real file/tty
     * path. Bind the resolved host path itself instead of /proc/self/fd/N:
     * the latter is evaluated in the child process and can still trip PRoot's
     * sanitize step in Android foreground services.
     */
    private fun buildStandardFdBinds(): List<String> {
        val binds = mutableListOf<String>()
        val mappings = listOf(
            Triple(0, "/dev/stdin", true),
            Triple(1, "/dev/stdout", false),
            Triple(2, "/dev/stderr", false),
        )

        for ((fd, guestPath, allowDevNull) in mappings) {
            val hostPath = "/proc/self/fd/$fd"
            val bindSource = resolveBindableFd(hostPath, allowDevNull)
            if (bindSource != null) {
                binds.add("--bind=$bindSource:$guestPath")
            }
        }

        return binds
    }

    private fun resolveBindableFd(hostPath: String, allowDevNull: Boolean): String? {
        return try {
            val target = Os.readlink(hostPath)
            when {
                target.isBlank() -> null
                target.startsWith("pipe:[") -> null
                target.startsWith("socket:[") -> null
                target.startsWith("anon_inode:") -> null
                allowDevNull && target == "/dev/null" -> target
                target.startsWith("/") && File(target).exists() -> target
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun buildEnvCommand(envVars: List<String>, command: String?): List<String> {
        val envBin = File("$rootfsDir/usr/bin/env")
        return if (envBin.exists()) {
            val args = mutableListOf("/usr/bin/env", "-i")
            args.addAll(envVars)
            if (command != null) args.addAll(listOf("/bin/bash", "-c", command))
            else args.addAll(listOf("/bin/bash", "-l"))
            args
        } else {
            val exports = envVars.joinToString(" ") { "export $it;" }
            if (command != null) listOf("/bin/bash", "-c", "$exports $command")
            else listOf("/bin/bash", "-c", "$exports exec /bin/bash -l")
        }
    }

    private fun commonProotFlags(): List<String> {
        // Guarantee resolv.conf exists before building the bind-mount list
        val resolvFile = ensureResolvConf()

        val prootPath = getProotPath()
        val procFakes = "$configDir/proc_fakes"
        val sysFakes = "$configDir/sys_fakes"

        val flags = mutableListOf(
            prootPath,
            "--link2symlink",
            "-L",
            "--kill-on-exit",
            "--rootfs=$rootfsDir",
            "--cwd=/root",
            // Core device binds (matching proot-distro)
            "--bind=/dev",
            "--bind=/dev/urandom:/dev/random",
            "--bind=/proc",
            "--bind=/proc/self/fd:/dev/fd",
            "--bind=/sys",
            // Fake /proc entries 鈥?Android restricts most /proc access.
            // proot-distro's run_proot_cmd() binds these unconditionally.
            "--bind=$procFakes/loadavg:/proc/loadavg",
            "--bind=$procFakes/stat:/proc/stat",
            "--bind=$procFakes/uptime:/proc/uptime",
            "--bind=$procFakes/version:/proc/version",
            "--bind=$procFakes/vmstat:/proc/vmstat",
            "--bind=$procFakes/cap_last_cap:/proc/sys/kernel/cap_last_cap",
            "--bind=$procFakes/max_user_watches:/proc/sys/fs/inotify/max_user_watches",
            // Extra: libgcrypt reads this; missing causes apt SIGABRT
            "--bind=$procFakes/fips_enabled:/proc/sys/crypto/fips_enabled",
            // Shared memory 鈥?proot-distro binds rootfs/tmp to /dev/shm
            "--bind=$rootfsDir/tmp:/dev/shm",
            // SELinux override 鈥?empty dir disables SELinux checks
            "--bind=$sysFakes/empty:/sys/fs/selinux",
            "--bind=$homeDir:/root/home",
        )
        if (resolvFile != null && resolvFile.exists() && resolvFile.length() > 0) {
            flags.add("--bind=${resolvFile.absolutePath}:/etc/resolv.conf")
        }
        return flags.let { flagsWithResolv ->
            // Bind-mount shared storage into proot (Termux proot-distro style).
            // Bind the whole /storage tree so symlinks and sub-mounts resolve.
            // Then create /sdcard symlink inside rootfs pointing to the right path.
            val stdioFlags = buildStandardFdBinds()
            val baseFlags = flagsWithResolv + stdioFlags

            val hasAccess = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                Environment.isExternalStorageManager()
            } else {
                val sdcard = Environment.getExternalStorageDirectory()
                sdcard.exists() && sdcard.canRead()
            }

            if (hasAccess) {
                val storageDir = File("$rootfsDir/storage")
                storageDir.mkdirs()
                // Create /sdcard symlink 鈫?/storage/emulated/0 inside rootfs
                val sdcardLink = File("$rootfsDir/sdcard")
                if (!sdcardLink.exists()) {
                    try {
                        Runtime.getRuntime().exec(
                            arrayOf("ln", "-sf", "/storage/emulated/0", "$rootfsDir/sdcard")
                        ).waitFor()
                    } catch (_: Exception) {
                        // Fallback: create as directory if symlink fails
                        sdcardLink.mkdirs()
                    }
                }
                baseFlags + listOf(
                    "--bind=/storage:/storage",
                    "--bind=/storage/emulated/0:/sdcard",
                )
            } else {
                baseFlags
            }
        }
    }

    // ================================================================
    // INSTALL MODE 鈥?matches proot-distro's run_proot_cmd()
    // Used for: apt-get, dpkg, pip install, chmod, etc.
    // Simpler: no --sysvipc, simple kernel-release, minimal guest env.
    // ================================================================
    fun buildInstallCommand(command: String): List<String> {
        val flags = commonProotFlags().toMutableList()

        // --root-id: fake root identity (same as proot-distro run_proot_cmd)
        flags.add(1, "--root-id")
        // Simple kernel-release (proot-distro run_proot_cmd uses plain string)
        flags.add(2, "--kernel-release=$FAKE_KERNEL_RELEASE")
        // NOTE: --sysvipc is NOT used during install (matches proot-distro).
        // It causes SIGABRT when dpkg forks child processes.

        // Guest environment via env -i (matching proot-distro's run_proot_cmd)
        val envCommand = buildEnvCommand(listOf(
            "HOME=/root", "LANG=C.UTF-8",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM=xterm-256color", "TMPDIR=/tmp",
            "DEBIAN_FRONTEND=noninteractive", "PIP_CACHE_DIR=/tmp/pip-cache",
        ), command)
        flags.addAll(envCommand)

        return flags
    }

    // ================================================================
    // GATEWAY MODE 鈥?matches proot-distro's command_login()
    // Used for: running hermes gateway (long-lived Python process).
    // Full featured: --sysvipc, full uname struct, more guest env vars.
    // ================================================================
    fun buildGatewayCommand(command: String): List<String> {
        val flags = commonProotFlags().toMutableList()
        val arch = ArchUtils.getArch()
        // Map to uname -m format
        val machine = when (arch) {
            "arm" -> "armv7l"
            else -> arch // aarch64, x86_64, x86
        }

        // --change-id=0:0 (proot-distro command_login uses this for root)
        flags.add(1, "--change-id=0:0")
        // --sysvipc: enable SysV IPC (proot-distro enables for login sessions)
        flags.add(2, "--sysvipc")
        // Full uname struct format (matching proot-distro command_login)
        // Format: \sysname\nodename\release\version\machine\domainname\personality\
        val kernelRelease = "\\Linux\\localhost\\$FAKE_KERNEL_RELEASE" +
            "\\$FAKE_KERNEL_VERSION\\$machine\\localdomain\\-1\\"
        flags.add(3, "--kernel-release=$kernelRelease")

        // Guest environment via env -i (matching proot-distro command_login)
        val envCommand = buildEnvCommand(listOf(
            "HOME=/root", "USER=root", "LANG=C.UTF-8",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "TERM=xterm-256color", "TMPDIR=/tmp",
            "DEBIAN_FRONTEND=noninteractive", "PYTHONDONTWRITEBYTECODE=1",
            "PIP_CACHE_DIR=/tmp/pip-cache", "UV_NO_CONFIG=1",
            "CHOKIDAR_USEPOLLING=true", "UV_USE_IO_URING=0",
        ), command)
        flags.addAll(envCommand)

        return flags
    }

    // Backward compatibility alias
    fun buildProotCommand(command: String): List<String> = buildInstallCommand(command)

    // ================================================================
    // Execute a command in proot (install mode) and return output.
    // Used during bootstrap for apt, pip, chmod, etc.
    // ================================================================
    fun runInProotSync(
        command: String,
        timeoutSeconds: Long = 900,
    ): String {
        val cmd = buildInstallCommand(command)
        val env = prootEnv()

        val pb = ProcessBuilder(cmd)
        // CRITICAL: Clear inherited Android JVM environment.
        // Without this, LD_PRELOAD, CLASSPATH, DEX2OAT vars leak into
        // proot and break fork+exec. proot-distro uses `env -i` on the
        // guest side AND runs from a clean Termux shell on the host side.
        // We must explicitly clear() since Android's ProcessBuilder
        // inherits the full JVM environment.
        pb.environment().clear()
        pb.environment().putAll(env)
        pb.redirectErrorStream(true)

        val process = pb.start()
        val output = StringBuilder()
        val errorLines = StringBuilder()
        val criticalLines = StringBuilder()
        val reader = BufferedReader(InputStreamReader(process.inputStream))

        var line: String?
        while (reader.readLine().also { line = it } != null) {
            val l = line ?: continue
            if (l.contains("proot warning") || l.contains("can't sanitize")) {
                continue
            }
            emitInstallLog(l)
            output.appendLine(l)
            val trimmed = l.trim()
            if (isCriticalErrorLine(trimmed)) {
                criticalLines.appendLine(trimmed)
            }
            if (isErrorRelevantLine(trimmed)) {
                errorLines.appendLine(trimmed)
            }
        }

        val exited = process.waitFor(timeoutSeconds, java.util.concurrent.TimeUnit.SECONDS)
        if (!exited) {
            process.destroyForcibly()
            throw RuntimeException("Command timed out after ${timeoutSeconds}s")
        }

        val exitCode = process.exitValue()
        if (exitCode != 0) {
            val fullOutput = output.toString()
            val errorOutput = criticalLines.toString().takeLast(8000).ifEmpty {
                errorLines.toString().takeLast(8000)
            }.ifEmpty {
                fullOutput.takeLast(8000)
            }
            throw RuntimeException(
                "Command failed (exit code $exitCode): $errorOutput"
            )
        }

        return output.toString()
    }

    private fun isCriticalErrorLine(line: String): Boolean {
        if (line.isEmpty()) return false
        return line.startsWith("E:") ||
            line.startsWith("Err:") ||
            line.startsWith("dpkg: error") ||
            line.startsWith("dpkg: dependency problems") ||
            line.startsWith("Sub-process ") ||
            line.startsWith("Errors were encountered") ||
            line.contains("Temporary failure resolving") ||
            line.contains("Could not resolve") ||
            line.contains("Unable to fetch") ||
            line.contains("Unable to locate package")
    }

    private fun isErrorRelevantLine(line: String): Boolean {
        if (line.isEmpty()) return false
        if (isCriticalErrorLine(line)) return true
        if (line.startsWith("Get:") ||
            line.startsWith("Hit:") ||
            line.startsWith("Ign:") ||
            line.startsWith("Fetched ") ||
            line.startsWith("Reading package") ||
            line.startsWith("Building dependency") ||
            line.startsWith("Reading state") ||
            line.startsWith("The following") ||
            line.startsWith("Suggested packages:") ||
            line.startsWith("Recommended packages:") ||
            line.startsWith("Need to get") ||
            line.startsWith("After this") ||
            line.startsWith("Selecting previously") ||
            line.startsWith("Preparing to unpack") ||
            line.startsWith("Unpacking ") ||
            line.startsWith("Setting up ") ||
            line.startsWith("Processing triggers")) {
            return false
        }
        if (line.contains(" kB]") || line.contains(" MB]")) {
            return false
        }
        return true
    }

    private fun emitInstallLog(line: String) {
        val cleaned = line
            .replace(Regex("\\u001B\\[[0-9;]*[A-Za-z]"), "")
            .replace("\r", "")
            .replace("\u0008", "")
            .trim()
        if (cleaned.isEmpty()) {
            return
        }
        installLogEmitter?.invoke(cleaned)
    }

    // ================================================================
    // Start a long-lived gateway process (gateway mode).
    // Uses full proot-distro command_login() style configuration.
    // ================================================================
    fun startProotProcess(command: String): Process {
        val cmd = buildGatewayCommand(command)
        val env = prootEnv()

        val pb = ProcessBuilder(cmd)
        pb.environment().clear()
        pb.environment().putAll(env)
        pb.redirectErrorStream(false)

        return pb.start()
    }

    /**
     * Get the PID of a Process object. Works across Android API levels.
     * Returns -1 if PID cannot be determined.
     */
    fun getProcessPid(process: Process): Int {
        try {
            val pidMethod = process.javaClass.getMethod("pid")
            return pidMethod.invoke(process) as Int
        } catch (_: Exception) {}
        try {
            val pidField = process.javaClass.getDeclaredField("pid")
            pidField.isAccessible = true
            return pidField.getInt(process)
        } catch (_: Exception) {}
        return -1
    }

    /**
     * Kill a PRoot process and all its children (bash, python, hermes, etc.).
     * Uses kill(-pid, SIGTERM) to kill the process group, then escalates to SIGKILL.
     * This is the reliable way to stop PRoot-spawned processes on Android.
     */
    fun killProcessTree(process: Process, force: Boolean = false) {
        val pid = getProcessPid(process)
        if (pid > 1) {
            try {
                // Negative PID = kill entire process group
                // First try SIGTERM for graceful shutdown
                if (!force) {
                    Runtime.getRuntime().exec(arrayOf("kill", "-TERM", "-$pid")).waitFor()
                    val exited = process.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)
                    if (exited) return
                }
                // Escalate to SIGKILL (force kill entire process group)
                Runtime.getRuntime().exec(arrayOf("kill", "-KILL", "-$pid")).waitFor()
            } catch (_: Exception) {}
        }
        // Final fallback: force destroy the Process object
        try { process.destroyForcibly() } catch (_: Exception) {}
        try { process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS) } catch (_: Exception) {}
    }

    fun startProotLoginShell(): Process {
        val arch = ArchUtils.getArch()
        val machine = when (arch) {
            "arm" -> "armv7l"
            else -> arch
        }
        val kernelRelease = "\\Linux\\localhost\\$FAKE_KERNEL_RELEASE" +
            "\\$FAKE_KERNEL_VERSION\\$machine\\localdomain\\-1\\"

        val cmd = commonProotFlags().toMutableList().apply {
            add(1, "--change-id=0:0")
            add(2, "--sysvipc")
            add(3, "--kernel-release=$kernelRelease")
            addAll(buildEnvCommand(listOf(
                "HOME=/root", "USER=root", "LANG=C.UTF-8",
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TERM=xterm-256color", "TMPDIR=/tmp",
                "DEBIAN_FRONTEND=noninteractive", "PYTHONDONTWRITEBYTECODE=1",
                "PIP_CACHE_DIR=/tmp/pip-cache", "UV_NO_CONFIG=1",
                "CHOKIDAR_USEPOLLING=true", "UV_USE_IO_URING=0",
            ), null))
        }

        val pb = ProcessBuilder(cmd)
        pb.environment().clear()
        pb.environment().putAll(prootEnv())
        pb.redirectErrorStream(true)
        return pb.start()
    }
}

