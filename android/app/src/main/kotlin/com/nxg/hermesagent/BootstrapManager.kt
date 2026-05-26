package com.nousresearch.hermes

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.os.Build
import android.system.Os
import io.flutter.FlutterInjector
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.FileNotFoundException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPInputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import org.json.JSONArray
import org.json.JSONObject
import org.apache.commons.compress.archivers.ar.ArArchiveInputStream
import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.xz.XZCompressorInputStream
import org.apache.commons.compress.compressors.zstandard.ZstdCompressorInputStream

class BootstrapManager(
    private val context: Context,
    private val filesDir: String,
    private val nativeLibDir: String
) {
    private val rootfsDir get() = "$filesDir/rootfs/ubuntu"
    private val tmpDir get() = "$filesDir/tmp"
    private val homeDir get() = "$filesDir/home"
    private val configDir get() = "$filesDir/config"
    private val libDir get() = "$filesDir/lib"
    private val nativeRuntimeDir get() = "$filesDir/native"
    private val workspaceRootDir get() = File("$rootfsDir/root/.hermes")
    private val workspaceBackupManifestName = "hermes-workspace-backup.json"
    private val workspaceBackupFormat = "hermes-workspace-backup"
    private val workspaceBackupRelativePaths = listOf(
        ".env",
        "config.yaml",
        "data",
        "memory",
        "skills",
        "config",
        "extensions",
        "agents",
    )

    fun setupDirectories() {
        listOf(
            rootfsDir to "Ubuntu rootfs directory",
            tmpDir to "temporary directory",
            homeDir to "home directory",
            configDir to "config directory",
            "$homeDir/.hermes" to "Hermes home directory",
            libDir to "library directory",
            nativeRuntimeDir to "native runtime directory",
        ).forEach { (path, label) ->
            HostFilesystem.ensureDirectoryReady(path, label)
        }
        setupNativeRuntimeBinaries()
        // Termux's proot links against libtalloc.so.2 but Android extracts it
        // as libtalloc.so (jniLibs naming convention). Create a copy with the
        // correct SONAME so the dynamic linker finds it.
        setupLibtalloc()
        ensureRootfsRuntimeDirectories()
        // Create fake /proc and /sys files for proot bind mounts
        setupFakeSysdata()
        ensureDefaultTimezone()
    }

    /**
     * Download and install PRoot + libtalloc + loaders from the Termux package repository.
     * Called when the APK doesn't bundle proot as a native library (libproot.so).
     * Mimics scripts/fetch-proot-binaries.sh behavior.
     */
    fun setupProotFromTermux(arch: String) {
        val prootDir = File(nativeRuntimeDir)
        prootDir.mkdirs()
        val prootFile = File(prootDir, "libproot.so")
        val loaderFile = File(prootDir, "libprootloader.so")
        val loader32File = File(prootDir, "libprootloader32.so")
        val libtallocFile = File(prootDir, "libtalloc.so")

        // Skip if all already present
        if (prootFile.exists() && prootFile.length() > 1024 &&
            libtallocFile.exists() && libtallocFile.length() > 1024) {
            return
        }

        val termuxPool = "https://packages.termux.dev/apt/termux-main/pool/main"

        // Download proot .deb (contains proot + loader + loader32)
        if (!prootFile.exists() || prootFile.length() < 1024) {
            val prootDebUrl = when (arch) {
                "aarch64", "arm64" -> "$termuxPool/p/proot/proot_5.1.107-71_aarch64.deb"
                "arm", "armv7l", "armeabi-v7a" -> "$termuxPool/p/proot/proot_5.1.107-71_arm.deb"
                "x86_64", "amd64" -> "$termuxPool/p/proot/proot_5.1.107-71_x86_64.deb"
                else -> "$termuxPool/p/proot/proot_5.1.107-71_aarch64.deb"
            }
            val prootDebFile = File("$tmpDir/proot.deb")
            downloadFile(prootDebUrl, prootDebFile)
            if (prootDebFile.exists() && prootDebFile.length() > 1024) {
                extractProotAndLoadersFromDeb(prootDebFile, prootDir)
                prootDebFile.delete()
            }
        }

        // Download libtalloc .deb
        if (!libtallocFile.exists() || libtallocFile.length() < 1024) {
            val libtallocDebUrl = when (arch) {
                "aarch64", "arm64" -> "$termuxPool/libt/libtalloc/libtalloc_2.4.3_aarch64.deb"
                "arm", "armv7l", "armeabi-v7a" -> "$termuxPool/libt/libtalloc/libtalloc_2.4.3_arm.deb"
                "x86_64", "amd64" -> "$termuxPool/libt/libtalloc/libtalloc_2.4.3_x86_64.deb"
                else -> "$termuxPool/libt/libtalloc/libtalloc_2.4.3_aarch64.deb"
            }
            val libtallocDebFile = File("$tmpDir/libtalloc.deb")
            downloadFile(libtallocDebUrl, libtallocDebFile)
            if (libtallocDebFile.exists() && libtallocDebFile.length() > 1024) {
                extractLibFromDeb(libtallocDebFile, prootDir, "libtalloc")
                libtallocDebFile.delete()
            }
        }

        // Setup libtalloc.so.2 (proot expects this SONAME)
        setupLibtalloc()

        // Verify critical files
        if (!prootFile.exists() || prootFile.length() < 1024) {
            throw RuntimeException("Failed to download PRoot binary from Termux repository")
        }
        prootFile.setExecutable(true, false)
        prootFile.setReadable(true, false)
        if (loaderFile.exists()) loaderFile.setExecutable(true, false)
        if (loader32File.exists()) loader32File.setExecutable(true, false)
    }

    private fun downloadFile(url: String, dest: File) {
        dest.parentFile?.mkdirs()
        val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
        conn.connectTimeout = 30_000
        conn.readTimeout = 60_000
        conn.instanceFollowRedirects = true
        conn.connect()
        if (conn.responseCode !in 200..299) {
            conn.disconnect()
            return
        }
        conn.inputStream.use { input ->
            FileOutputStream(dest).use { output ->
                val buf = ByteArray(8192)
                var len: Int
                while (input.read(buf).also { len = it } != -1) {
                    output.write(buf, 0, len)
                }
            }
        }
        conn.disconnect()
    }

    /**
     * Extract proot binary + loader + loader32 from a .deb package.
     * The Termux proot package contains bin/proot, libexec/proot/loader, libexec/proot/loader32.
     */
    private fun extractProotAndLoadersFromDeb(debFile: File, destDir: File) {
        val tmpDir = File("$tmpDir/proot_extract")
        try {
            tmpDir.mkdirs()
            extractArToDir(debFile, tmpDir)
            var dataTar = tmpDir.listFiles()?.find { it.name.startsWith("data.tar") } ?: return
            dataTar = decompressIfNeeded(dataTar, tmpDir)

            val process = ProcessBuilder("tar", "tf", dataTar.absolutePath)
                .redirectErrorStream(true).start()
            val listing = process.inputStream.bufferedReader().readText()
            process.waitFor()

            // Find proot, loader, loader32 entries
            val entriesToExtract = listing.lines().filter { line ->
                val trimmed = line.trim()
                (trimmed.endsWith("/proot") && !trimmed.contains("doc") && !trimmed.contains("man")) ||
                trimmed.endsWith("/loader") ||
                trimmed.endsWith("/loader32")
            }.map { it.trim() }

            if (entriesToExtract.isNotEmpty()) {
                ProcessBuilder(listOf("tar", "xf", dataTar.absolutePath,
                    "-C", tmpDir.absolutePath) + entriesToExtract)
                    .redirectErrorStream(true).start().waitFor()
            }

            // Copy proot
            val prootBin = tmpDir.walk().find { it.name == "proot" && it.isFile && !it.path.contains("doc") }
            if (prootBin != null) {
                prootBin.copyTo(File(destDir, "libproot.so"), overwrite = true)
            }

            // Copy loaders
            val loader = tmpDir.walk().find { it.name == "loader" && !it.name.endsWith("32") && it.isFile }
            if (loader != null) {
                loader.copyTo(File(destDir, "libprootloader.so"), overwrite = true)
            }
            val loader32 = tmpDir.walk().find { it.name == "loader32" && it.isFile }
            if (loader32 != null) {
                loader32.copyTo(File(destDir, "libprootloader32.so"), overwrite = true)
            }
        } finally {
            tmpDir.deleteRecursively()
        }
    }

    private fun extractLibFromDeb(debFile: File, destDir: File, prefix: String) {
        val tmpDir = File("$tmpDir/lib_extract")
        try {
            tmpDir.mkdirs()
            extractArToDir(debFile, tmpDir)
            var dataTar = tmpDir.listFiles()?.find { it.name.startsWith("data.tar") } ?: return
            dataTar = decompressIfNeeded(dataTar, tmpDir)
            val process = ProcessBuilder("tar", "tf", dataTar.absolutePath).start()
            val listing = process.inputStream.bufferedReader().readText()
            process.waitFor()
            val entries = listing.lines().filter { line ->
                line.contains(prefix) && (line.endsWith(".so") || line.matches(Regex(".*\\.so\\..*")))
            }.map { it.trim() }
            if (entries.isNotEmpty()) {
                ProcessBuilder(listOf("tar", "xf", dataTar.absolutePath,
                    "-C", tmpDir.absolutePath) + entries)
                    .redirectErrorStream(true).start().waitFor()
                val found = tmpDir.walk().filter { f ->
                    f.name.startsWith(prefix) && (f.name.endsWith(".so") || f.name.matches(Regex(".*\\.so\\..*")))
                }.maxByOrNull { it.length() }
                if (found != null) {
                    found.copyTo(File(destDir, "libtalloc.so"), overwrite = true)
                }
            }
        } finally {
            tmpDir.deleteRecursively()
        }
    }

    private fun extractArToDir(arFile: File, outDir: File) {
        val fis = arFile.inputStream().buffered()
        val magic = ByteArray(8)
        fis.read(magic)
        if (!String(magic).startsWith("!<arch>")) { fis.close(); return }
        while (fis.available() > 0) {
            val header = ByteArray(60)
            if (fis.read(header) != 60) break
            val name = String(header, 0, 16).trim().trimEnd('/')
            val size = String(header, 48, 10).trim().toIntOrNull() ?: break
            if (name.isEmpty()) {
                fis.skip((if (size % 2 != 0) size + 1 else size).toLong())
                continue
            }
            val data = ByteArray(size)
            var read = 0
            while (read < size) { val r = fis.read(data, read, size - read); if (r == -1) break; read += r }
            if (size % 2 != 0) fis.read()
            File(outDir, name).apply { parentFile?.mkdirs(); writeBytes(data) }
        }
        fis.close()
    }

    private fun decompressIfNeeded(file: File, tmpDir: File): File {
        if (!file.name.endsWith(".xz")) return file
        val out = File(tmpDir, "data.tar")
        try {
            XZCompressorInputStream(file.inputStream()).use { xz ->
                out.outputStream().use { xz.copyTo(it) }
            }
            if (out.exists() && out.length() > 0) return out
        } catch (_: Exception) { out.delete() }
        return file
    }

    private fun ensureRootfsRuntimeDirectories() {
        listOf(
            "$rootfsDir/var/cache/apt",
            "$rootfsDir/var/cache/apt/archives",
            "$rootfsDir/var/cache/apt/archives/partial",
            "$rootfsDir/var/lib/apt",
            "$rootfsDir/var/lib/apt/lists",
            "$rootfsDir/var/lib/apt/lists/partial",
            "$rootfsDir/var/log/apt",
            "$rootfsDir/var/lib/dpkg/updates",
            "$rootfsDir/var/lib/dpkg/triggers",
            "$rootfsDir/tmp",
            "$rootfsDir/var/tmp",
            "$rootfsDir/run",
            "$rootfsDir/run/lock",
            "$rootfsDir/dev/shm",
        ).forEach { path ->
            HostFilesystem.ensureDirectoryReady(path, "rootfs runtime directory")
        }
    }

    private fun setupNativeRuntimeBinaries() {
        listOf(
            "libproot.so",
            "libprootloader.so",
            "libprootloader32.so",
            "libtalloc.so",
        ).forEach { libName ->
            ensureNativeRuntimeBinary(libName)
        }
    }

    private fun ensureNativeRuntimeBinary(libName: String) {
        val target = File("$nativeRuntimeDir/$libName")
        if (target.exists() && target.length() > 0L) {
            target.setReadable(true, false)
            target.setExecutable(true, false)
            return
        }

        val directSource = File("$nativeLibDir/$libName")
        if (directSource.exists() && directSource.length() > 0L) {
            directSource.copyTo(target, overwrite = true)
            target.setReadable(true, false)
            target.setExecutable(true, false)
            return
        }

        extractNativeLibraryFromApk(libName, target)
    }

    private fun extractNativeLibraryFromApk(libName: String, target: File) {
        val apkPath = context.applicationInfo.sourceDir ?: return
        val abiDirs = resolveApkAbiDirs()

        ZipFile(apkPath).use { zip ->
            for (abiDir in abiDirs) {
                val entry = zip.getEntry("lib/$abiDir/$libName") ?: continue
                target.parentFile?.mkdirs()
                zip.getInputStream(entry).use { input ->
                    FileOutputStream(target).use { output ->
                        input.copyTo(output)
                    }
                }
                target.setReadable(true, false)
                target.setExecutable(true, false)
                return
            }
        }
    }

    private fun resolveApkAbiDirs(): List<String> {
        val supported = Build.SUPPORTED_ABIS?.mapNotNull { abi ->
            when (abi.lowercase()) {
                "arm64-v8a" -> "arm64-v8a"
                "armeabi-v7a", "armeabi" -> "armeabi-v7a"
                "x86_64" -> "x86_64"
                "x86" -> "x86"
                else -> null
            }
        } ?: emptyList()

        return (supported + listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86"))
            .distinct()
    }

    private fun setupLibtalloc() {
        val runtimeSource = File("$nativeRuntimeDir/libtalloc.so")
        val source = if (runtimeSource.exists() && runtimeSource.length() > 0L) {
            runtimeSource
        } else {
            File("$nativeLibDir/libtalloc.so")
        }
        val target = File("$libDir/libtalloc.so.2")
        if (source.exists() && (!target.exists() || target.length() != source.length())) {
            source.copyTo(target, overwrite = true)
            target.setExecutable(true)
            target.setReadable(true, false)
        }
    }

    fun isBootstrapComplete(): Boolean {
        val rootfs = File(rootfsDir)
        val binBash = File("$rootfsDir/bin/bash")
        val python = File("$rootfsDir/usr/bin/python3").let {
            if (it.exists()) it else File("$rootfsDir/usr/local/bin/python3")
        }

        // ★ Fast path: check common hermes entry point files on the host
        // filesystem FIRST. This avoids the expensive PRoot spawn on every
        // app open. Only fall back to PRoot if the fast check fails.
        val fastHermesCheck = File("$rootfsDir/usr/local/bin/hermes").exists() ||
            File("$rootfsDir/root/.local/bin/hermes").exists() ||
            File("$rootfsDir/usr/local/lib/hermes-agent/venv/bin/python").exists() ||
            File("$rootfsDir/usr/local/lib/hermes-agent/venv/bin/hermes").exists()

        val hermesOk = if (fastHermesCheck) {
            true
        } else {
            // Slow path: check hermes inside PRoot (hermes is installed in the
            // Ubuntu rootfs, so `command -v hermes` on the host will always fail).
            try {
                val pm = ProcessManager(filesDir, nativeLibDir)
                val output = pm.runInProotSync(
                    "export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\" && " +
                    "(command -v hermes || " +
                    "/usr/local/lib/hermes-agent/venv/bin/hermes --version || " +
                    "/usr/local/lib/hermes-agent/venv/bin/python -m hermes_cli --version || " +
                    "python3 -m hermes_cli --version) 2>/dev/null",
                    timeoutSeconds = 15
                )
                output.trim().isNotEmpty()
            } catch (_: Exception) {
                // Fallback: check common entry point locations inside rootfs
                File("$rootfsDir/usr/local/bin/hermes").exists() ||
                File("$rootfsDir/root/.local/bin/hermes").exists() ||
                File("$rootfsDir/usr/local/lib/hermes-agent/venv/bin/python").exists() ||
                File("$rootfsDir/usr/local/lib/hermes-agent/setup.py").exists() ||
                File("$rootfsDir/usr/local/lib/hermes-agent/pyproject.toml").exists()
            }
        }
        return rootfs.exists() && binBash.exists()
            && python.exists() && hermesOk
    }

    fun getBootstrapStatus(): Map<String, Any> {
        val rootfsExists = File(rootfsDir).exists()
        val binBashExists = File("$rootfsDir/bin/bash").exists()
        val pythonExists = File("$rootfsDir/usr/bin/python3").exists() ||
            File("$rootfsDir/usr/local/bin/python3").exists()
        // Check hermes inside PRoot (hermes lives in the Ubuntu rootfs, not on host)
        // Use venv python since hermes_cli is installed there
        val hermesExists = try {
            val pm = ProcessManager(filesDir, nativeLibDir)
            val venvPython = "/root/.hermes/hermes-agent/venv/bin/python"
            val output = pm.runInProotSync(
                "export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\" && " +
                "(command -v hermes 2>/dev/null || " +
                "\"$venvPython\" -m hermes_cli --version 2>/dev/null) 2>/dev/null",
                timeoutSeconds = 15
            )
            output.trim().isNotEmpty()
        } catch (_: Exception) {
            // Fallback: check common entry point locations inside rootfs
            File("$rootfsDir/usr/local/bin/hermes").exists() ||
            File("$rootfsDir/root/.local/bin/hermes").exists() ||
            File("$rootfsDir/root/.hermes/hermes-agent/venv/bin/python").exists() ||
            File("$rootfsDir/usr/local/lib/hermes-agent/venv/bin/python").exists() ||
            File("$rootfsDir/usr/local/lib/hermes-agent/setup.py").exists() ||
            File("$rootfsDir/usr/local/lib/hermes-agent/pyproject.toml").exists()
        }
        val basePackageBinaries = listOf(
            "$rootfsDir/usr/bin/git",
            "$rootfsDir/usr/bin/python3",
            "$rootfsDir/usr/bin/make",
            "$rootfsDir/usr/bin/g++",
            "$rootfsDir/usr/bin/curl",
            "$rootfsDir/usr/bin/wget",
        )
        val caCertificatesReady =
            File("$rootfsDir/etc/ssl/certs/ca-certificates.crt").exists() ||
            File("$rootfsDir/usr/sbin/update-ca-certificates").exists()
        val basePackagesInstalled = binBashExists &&
            basePackageBinaries.all { File(it).exists() } &&
            caCertificatesReady

        return mapOf(
            "rootfsExists" to rootfsExists,
            "binBashExists" to binBashExists,
            "pythonInstalled" to pythonExists,
            "hermesInstalled" to hermesExists,
            "basePackagesInstalled" to basePackagesInstalled,
            "rootfsPath" to rootfsDir,
            "complete" to (rootfsExists && binBashExists
                && pythonExists && hermesExists)
        )
    }

    fun extractRootfs(tarPath: String) {
        val rootfs = File(rootfsDir)
        // Clean up any previous failed extraction
        if (rootfs.exists()) {
            deleteRecursively(rootfs)
        }
        rootfs.mkdirs()

        // Pure Java extraction using Apache Commons Compress.
        // Two-phase approach:
        //   Phase 1: Extract directories, regular files, and hard links (as copies).
        //   Phase 2: Create all symlinks (deferred so directory structure exists first).
        // This handles tarball entry ordering issues (e.g., bin/bash before bin鈫抲sr/bin).
        val deferredSymlinks = mutableListOf<Pair<String, String>>() // target, path
        var entryCount = 0
        var fileCount = 0
        var symlinkCount = 0
        var extractionError: Exception? = null

        try {
            FileInputStream(tarPath).use { fis ->
                BufferedInputStream(fis, 256 * 1024).use { bis ->
                    GZIPInputStream(bis).use { gis ->
                        TarArchiveInputStream(gis).use { tis ->
                            var entry: TarArchiveEntry? = tis.nextEntry
                            while (entry != null) {
                                entryCount++
                                val name = entry.name
                                    .removePrefix("./")
                                    .removePrefix("/")

                                if (name.isEmpty() || name.startsWith("dev/") || name == "dev") {
                                    entry = tis.nextEntry
                                    continue
                                }

                                val outFile = File(rootfsDir, name)

                                when {
                                    entry.isDirectory -> {
                                        outFile.mkdirs()
                                    }
                                    entry.isSymbolicLink -> {
                                        // Defer symlinks to phase 2
                                        deferredSymlinks.add(
                                            Pair(entry.linkName, outFile.absolutePath)
                                        )
                                        symlinkCount++
                                    }
                                    entry.isLink -> {
                                        // Hard link 鈫?copy the target file
                                        val target = entry.linkName
                                            .removePrefix("./")
                                            .removePrefix("/")
                                        val targetFile = File(rootfsDir, target)
                                        outFile.parentFile?.mkdirs()
                                        try {
                                            if (targetFile.exists()) {
                                                targetFile.copyTo(outFile, overwrite = true)
                                                if (targetFile.canExecute()) {
                                                    outFile.setExecutable(true, false)
                                                }
                                                fileCount++
                                            }
                                        } catch (_: Exception) {}
                                    }
                                    else -> {
                                        // Regular file
                                        outFile.parentFile?.mkdirs()
                                        FileOutputStream(outFile).use { fos ->
                                            val buf = ByteArray(65536)
                                            var len: Int
                                            while (tis.read(buf).also { len = it } != -1) {
                                                fos.write(buf, 0, len)
                                            }
                                        }
                                        outFile.setReadable(true, false)
                                        outFile.setWritable(true, false)
                                        val mode = entry.mode
                                        // Always check path-based heuristic for executables.
                                        // The tarball mode bits may not be preserved correctly
                                        // by Apache Commons Compress, so we MUST mark files
                                        // in /bin/, /sbin/ etc. as executable regardless.
                                        val path = name.lowercase()
                                        if ((mode != 0 && mode and 0b001_001_001 != 0) ||
                                            path.contains("/bin/") ||
                                            path.contains("/sbin/") ||
                                            path.endsWith(".sh") ||
                                            path.contains("/lib/apt/methods/")) {
                                            outFile.setExecutable(true, false)
                                        }
                                        fileCount++
                                    }
                                }

                                entry = tis.nextEntry
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            extractionError = e
        }

        if (entryCount == 0) {
            throw RuntimeException(
                "Extraction failed: tarball appears empty or corrupt. " +
                "Error: ${extractionError?.message ?: "none"}"
            )
        }

        if (extractionError != null && fileCount < 100) {
            throw RuntimeException(
                "Extraction failed after $entryCount entries ($fileCount files): " +
                "${extractionError!!.message}"
            )
        }

        // Phase 2: Create all symlinks now that the directory structure exists.
        var symlinkErrors = 0
        var lastSymlinkError = ""
        for ((target, path) in deferredSymlinks) {
            try {
                val file = File(path)
                if (file.exists()) {
                    if (file.isDirectory) {
                        val linkTarget = if (target.startsWith("/")) {
                            target.removePrefix("/")
                        } else {
                            val parent = file.parentFile?.absolutePath ?: rootfsDir
                            File(parent, target).relativeTo(File(rootfsDir)).path
                        }
                        val realTargetDir = File(rootfsDir, linkTarget)
                        if (realTargetDir.exists() && realTargetDir.isDirectory) {
                            file.listFiles()?.forEach { child ->
                                val dest = File(realTargetDir, child.name)
                                if (!dest.exists()) {
                                    child.renameTo(dest)
                                }
                            }
                        }
                        deleteRecursively(file)
                    } else {
                        file.delete()
                    }
                }
                file.parentFile?.mkdirs()
                Os.symlink(target, path)
            } catch (e: Exception) {
                symlinkErrors++
                lastSymlinkError = "$path -> $target: ${e.message}"
            }
        }

        // Phase 3: Ensure critical symlinks/binaries for merged /usr.
        // If Phase 2 failed (SELinux, FUSE, etc.), PRoot cannot execute bash.
        ensureCriticalSymlinks()

        // Verify extraction
        if (!File("$rootfsDir/bin/bash").exists() &&
            !File("$rootfsDir/usr/bin/bash").exists()) {
            throw RuntimeException(
                "Extraction failed: bash not found in rootfs. " +
                "Processed $entryCount entries, $fileCount files, " +
                "$symlinkCount symlinks (${symlinkErrors} symlink errors). " +
                "Last symlink error: $lastSymlinkError. " +
                "usr/bin exists: ${File("$rootfsDir/usr/bin").exists()}. " +
                "Extraction error: ${extractionError?.message ?: "none"}"
            )
        }

        // Post-extraction: configure rootfs for proot compatibility
        configureRootfs()

        // Clean up tarball
        File(tarPath).delete()
    }

    /**
     * Extract all .deb packages from the apt cache into the rootfs.
     * Uses Java (Apache Commons Compress) to avoid fork+exec issues in proot.
     * A .deb is an ar archive containing data.tar.{xz,gz,zst}.
     * Returns the number of packages extracted.
     */
    fun extractDebPackages(): Int {
        val archivesDir = File("$rootfsDir/var/cache/apt/archives")
        if (!archivesDir.exists()) {
            throw RuntimeException("No apt archives directory found")
        }

        val debFiles = archivesDir.listFiles { f -> f.name.endsWith(".deb") }
            ?: throw RuntimeException("No .deb files found in apt cache")

        if (debFiles.isEmpty()) {
            throw RuntimeException("No .deb files found in apt cache")
        }

        var extracted = 0
        val errors = mutableListOf<String>()

        for (debFile in debFiles) {
            try {
                extractSingleDeb(debFile)
                extracted++
            } catch (e: Exception) {
                errors.add("${debFile.name}: ${e.message}")
            }
        }

        if (extracted == 0) {
            throw RuntimeException(
                "Failed to extract any .deb packages. Errors: ${errors.joinToString("; ")}"
            )
        }

        // Fix permissions on newly extracted binaries
        fixBinPermissions()

        return extracted
    }

    /**
     * Extract a single .deb file into the rootfs.
     * Reads the ar archive, finds data.tar.*, decompresses, and extracts.
     */
    private fun extractSingleDeb(debFile: File) {
        FileInputStream(debFile).use { fis ->
            BufferedInputStream(fis).use { bis ->
                ArArchiveInputStream(bis).use { arIn ->
                    var arEntry = arIn.nextEntry
                    while (arEntry != null) {
                        val name = arEntry.name
                        if (name.startsWith("data.tar")) {
                            // Wrap in appropriate decompressor
                            val dataStream: InputStream = when {
                                name.endsWith(".xz") -> XZCompressorInputStream(arIn)
                                name.endsWith(".gz") -> GZIPInputStream(arIn)
                                name.endsWith(".zst") -> ZstdCompressorInputStream(arIn)
                                else -> arIn // plain .tar or unknown
                            }

                            // Extract data.tar contents into rootfs
                            TarArchiveInputStream(dataStream).use { tarIn ->
                                var tarEntry = tarIn.nextEntry
                                while (tarEntry != null) {
                                    val entryName = tarEntry.name
                                        .removePrefix("./")
                                        .removePrefix("/")

                                    if (entryName.isEmpty()) {
                                        tarEntry = tarIn.nextEntry
                                        continue
                                    }

                                    val outFile = File(rootfsDir, entryName)

                                    when {
                                        tarEntry.isDirectory -> {
                                            outFile.mkdirs()
                                        }
                                        tarEntry.isSymbolicLink -> {
                                            try {
                                                if (outFile.exists()) outFile.delete()
                                                outFile.parentFile?.mkdirs()
                                                Os.symlink(tarEntry.linkName, outFile.absolutePath)
                                            } catch (_: Exception) {}
                                        }
                                        tarEntry.isLink -> {
                                            val target = tarEntry.linkName
                                                .removePrefix("./")
                                                .removePrefix("/")
                                            val targetFile = File(rootfsDir, target)
                                            outFile.parentFile?.mkdirs()
                                            try {
                                                if (targetFile.exists()) {
                                                    targetFile.copyTo(outFile, overwrite = true)
                                                    if (targetFile.canExecute()) {
                                                        outFile.setExecutable(true, false)
                                                    }
                                                }
                                            } catch (_: Exception) {}
                                        }
                                        else -> {
                                            outFile.parentFile?.mkdirs()
                                            FileOutputStream(outFile).use { fos ->
                                                val buf = ByteArray(65536)
                                                var len: Int
                                                while (tarIn.read(buf).also { len = it } != -1) {
                                                    fos.write(buf, 0, len)
                                                }
                                            }
                                            outFile.setReadable(true, false)
                                            outFile.setWritable(true, false)
                                            val mode = tarEntry.mode
                                            if (mode and 0b001_001_001 != 0) {
                                                outFile.setExecutable(true, false)
                                            }
                                            // Ensure bin/sbin files are executable
                                            val path = entryName.lowercase()
                                            if (path.contains("/bin/") ||
                                                path.contains("/sbin/")) {
                                                outFile.setExecutable(true, false)
                                            }
                                        }
                                    }

                                    tarEntry = tarIn.nextEntry
                                }
                            }
                            return // Found and processed data.tar, done
                        }
                        arEntry = arIn.nextEntry
                    }
                }
            }
        }
    }

    /**
     * Write configuration files that make the rootfs work correctly under proot.
     * Called automatically after extraction.
     */
    private fun configureRootfs() {
        // 1. Disable apt sandboxing 鈥?proot fakes UID 0 via ptrace but cannot
        //    intercept setresuid/setresgid, so apt's _apt user privilege drop
        //    fails with "Operation not permitted". Tell apt to stay as root.
        val aptConfDir = File("$rootfsDir/etc/apt/apt.conf.d")
        aptConfDir.mkdirs()
        File(aptConfDir, "01-hermes-proot").writeText(
            "APT::Sandbox::User \"root\";\n" +
            "Acquire::Languages \"none\";\n" +
            "Acquire::Retries \"3\";\n" +
            "Acquire::http::Timeout \"20\";\n" +
            "Acquire::https::Timeout \"20\";\n" +
            // Disable PTY allocation when APT forks dpkg. APT's child process
            // calls SetupSlavePtyMagic() before execvp(dpkg); in proot on
            // Android 10+ (W^X policy), the PTY/chdir setup in the child can
            // fail causing _exit(100). Disabling this simplifies the fork path.
            "Dpkg::Use-Pty \"0\";\n" +
            // Pass dpkg options through apt to tolerate proot failures
            "Dpkg::Options { \"--force-confnew\"; \"--force-overwrite\"; };\n"
        )

        // 2. Configure dpkg for proot compatibility
        //    - force-unsafe-io: skip fsync/sync_file_range (may ENOSYS in proot)
        //    - no-debsig: skip signature verification
        val dpkgConfDir = File("$rootfsDir/etc/dpkg/dpkg.cfg.d")
        dpkgConfDir.mkdirs()
        File(dpkgConfDir, "01-hermes-proot").writeText(
            "force-unsafe-io\n" +
            "no-debsig\n" +
            "force-overwrite\n" +
            "force-depends\n"
        )

        // 3. Ensure essential directories exist
        // mkdir syscall is broken inside proot on Android 10+.
        // Pre-create ALL directories that tools need at runtime.
        listOf(
            "$rootfsDir/etc/ssl/certs",
            "$rootfsDir/usr/share/keyrings",
            "$rootfsDir/etc/apt/sources.list.d",
            "$rootfsDir/var/cache/apt",
            "$rootfsDir/var/cache/apt/archives",
            "$rootfsDir/var/cache/apt/archives/partial",
            "$rootfsDir/var/lib/apt",
            "$rootfsDir/var/lib/apt/lists",
            "$rootfsDir/var/lib/apt/lists/partial",
            "$rootfsDir/var/log/apt",
            "$rootfsDir/var/lib/dpkg/updates",
            "$rootfsDir/var/lib/dpkg/triggers",
            // pip cache directories (pip can't mkdir inside proot)
            "$rootfsDir/tmp/pip-cache",
            // Python / pip working directories
            "$rootfsDir/root/.pip",
            "$rootfsDir/root/.config",
            "$rootfsDir/usr/local/lib/node_modules",
            "$rootfsDir/usr/local/lib/python3/dist-packages",
            "$rootfsDir/usr/local/bin",
            // Hermes runtime directories (can't mkdir at runtime)
            "$rootfsDir/root/.hermes",
            "$rootfsDir/root/.hermes/data",
            "$rootfsDir/root/.hermes/memory",
            "$rootfsDir/root/.hermes/skills",
            "$rootfsDir/root/.hermes/config",
            "$rootfsDir/root/.hermes/extensions",
            "$rootfsDir/root/.hermes/logs",
            // Hermes Agent session/conversation logs
            "$rootfsDir/root/.hermes/sessions",
            "$rootfsDir/root/.config/hermes",
            "$rootfsDir/root/.local/share",
            "$rootfsDir/root/.cache",
            "$rootfsDir/root/.cache/hermes",
            "$rootfsDir/root/.cache/node",
            // Hermes Agent code directory (tarball extracts here)
            "$rootfsDir/usr/local/lib/hermes-agent",
            // Virtual environment directory (PEP 668 compliance)
            "$rootfsDir/usr/local/lib/hermes-agent/venv",
            "$rootfsDir/usr/local/lib/hermes-agent/venv/bin",
            "$rootfsDir/usr/local/lib/hermes-agent/venv/lib",
            // pip/wheel cache directories
            "$rootfsDir/root/.cache/pip",
            "$rootfsDir/root/.config/pip",
            // General runtime directories
            "$rootfsDir/var/tmp",
            "$rootfsDir/run",
            "$rootfsDir/run/lock",
            "$rootfsDir/dev/shm",
        ).forEach { File(it).mkdirs() }

        // 4. Ensure /etc/machine-id exists (dpkg triggers and systemd utils need it)
        val machineId = File("$rootfsDir/etc/machine-id")
        if (!machineId.exists()) {
            machineId.parentFile?.mkdirs()
            machineId.writeText("10000000000000000000000000000000\n")
        }

        // 4. Ensure policy-rc.d prevents services from auto-starting during install
        //    (they'd fail inside proot anyway)
        val policyRc = File("$rootfsDir/usr/sbin/policy-rc.d")
        policyRc.parentFile?.mkdirs()
        policyRc.writeText("#!/bin/sh\nexit 101\n")
        policyRc.setExecutable(true, false)

        // 5. Register Android user/groups in rootfs (matching proot-distro).
        //    dpkg and apt need valid user/group databases.
        registerAndroidUsers()

        // 6. Write /etc/hosts (some post-install scripts need hostname resolution)
        val hosts = File("$rootfsDir/etc/hosts")
        if (!hosts.exists() || !hosts.readText().contains("localhost")) {
            hosts.writeText(
                "127.0.0.1   localhost.localdomain localhost\n" +
                "::1         localhost.localdomain localhost ip6-localhost ip6-loopback\n"
            )
        }

        // 7. Ensure /tmp exists with world-writable + sticky permissions
        //    (needed for /dev/shm bind mount and general temp file usage)
        val tmpDir = File("$rootfsDir/tmp")
        tmpDir.mkdirs()
        tmpDir.setReadable(true, false)
        tmpDir.setWritable(true, false)
        tmpDir.setExecutable(true, false)

        // 8. Fix executable permissions on critical directories.
        //    Our Java extraction might not preserve all permission bits correctly
        //    (dpkg error 100 = "Could not exec dpkg" = permission issue).
        //    Recursively ensure all files in bin/sbin/lib dirs are executable.
        fixBinPermissions()
        ensureDefaultTimezone()
        //    Detect Python version and create dist-packages directory
        ensurePythonDistPackages()
        ensureCriticalBinaries()
        verifyBashBinary()
    }

    /**
     * Ensure critical symlinks exist for merged /usr layout.
     * Ubuntu 24.04: /bin -> usr/bin, /sbin -> usr/sbin, /lib -> usr/lib, /lib64 -> usr/lib.
     * If symlinks can't be created (Android SELinux/FUSE), copy directory contents instead.
     */
    private fun ensureCriticalSymlinks() {
        data class CriticalLink(val linkPath: String, val target: String, val source: String)
        val links = listOf(
            CriticalLink("bin", "usr/bin", "usr/bin"),
            CriticalLink("sbin", "usr/sbin", "usr/sbin"),
            CriticalLink("lib", "usr/lib", "usr/lib"),
            CriticalLink("lib64", "usr/lib", "usr/lib"),
        )
        for (link in links) {
            val file = File(rootfsDir, link.linkPath)
            if (file.exists() || java.nio.file.Files.isSymbolicLink(file.toPath())) continue
            val src = File(rootfsDir, link.source)
            if (!src.exists() || !src.isDirectory) continue
            try {
                file.parentFile?.mkdirs()
                Os.symlink(link.target, file.absolutePath)
            } catch (_: Exception) {
                // Fallback: copy directory contents (works on all Android filesystems)
                try {
                    file.mkdirs()
                    src.listFiles()?.forEach { child ->
                        val dest = File(file, child.name)
                        if (!dest.exists()) {
                            if (child.isDirectory) child.copyRecursively(dest)
                            else { child.copyTo(dest); if (child.canExecute()) dest.setExecutable(true, false) }
                        }
                    }
                } catch (_: Exception) {}
            }
        }
        ensureDynamicLinker()
    }

    /**
     * Ensure dynamic linker (ld-linux) exists. Without it, no ELF binary can execute.
     * arm64: /lib64/ld-linux-aarch64.so.1  armhf: /lib/ld-linux-armhf.so.3  x86_64: /lib64/ld-linux-x86-64.so.2
     */
    private fun ensureDynamicLinker() {
        // Map of linker path -> possible source paths
        val candidates: List<Pair<String, List<String>>> = listOf(
            "lib64/ld-linux-aarch64.so.1" to listOf(
                "usr/lib/ld-linux-aarch64.so.1",
                "usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
            ),
            "lib/ld-linux-armhf.so.3" to listOf(
                "usr/lib/ld-linux-armhf.so.3",
                "usr/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3"
            ),
            "lib64/ld-linux-x86-64.so.2" to listOf(
                "usr/lib/ld-linux-x86-64.so.2",
                "usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
            ),
        )
        for ((linkPath, sourcePaths) in candidates) {
            val linkFile = File(rootfsDir, linkPath)
            if (linkFile.exists() || java.nio.file.Files.isSymbolicLink(linkFile.toPath())) continue
            // Find the actual linker binary
            var sourceFile: File? = null
            for (sp in sourcePaths) {
                val f = File(rootfsDir, sp)
                if (f.exists()) { sourceFile = f; break }
            }
            if (sourceFile == null) {
                sourceFile = File(rootfsDir).walk().maxDepth(5).find {
                    it.isFile && it.name.startsWith("ld-linux") &&
                    (it.name.endsWith(".so.1") || it.name.endsWith(".so.2") || it.name.endsWith(".so.3"))
                }
            }
            if (sourceFile == null) continue
            linkFile.parentFile?.mkdirs()
            try {
                val rel = sourceFile.relativeTo(linkFile.parentFile!!).path
                Os.symlink(rel, linkFile.absolutePath)
            } catch (_: Exception) {
                try { sourceFile.copyTo(linkFile, overwrite = true); linkFile.setExecutable(true, false) } catch (_: Exception) {}
            }
        }
    }

    /**
     * Verify /bin/bash and /usr/bin/bash exist and are executable.
     */
    private fun verifyBashBinary() {
        val binBash = File("$rootfsDir/bin/bash")
        val usrBinBash = File("$rootfsDir/usr/bin/bash")

        if (!binBash.exists() && usrBinBash.exists()) {
            File("$rootfsDir/bin").mkdirs()
            try { Os.symlink("usr/bin/bash", binBash.absolutePath) } catch (_: Exception) {
                try { usrBinBash.copyTo(binBash, overwrite = true) } catch (_: Exception) {}
            }
        }
        if (!usrBinBash.exists() && binBash.exists()) {
            File("$rootfsDir/usr/bin").mkdirs()
            try { Os.symlink("../../bin/bash", usrBinBash.absolutePath) } catch (_: Exception) {
                try { binBash.copyTo(usrBinBash, overwrite = true) } catch (_: Exception) {}
            }
        }
        if (!binBash.exists() && !usrBinBash.exists()) {
            val found = File(rootfsDir).walk().maxDepth(4)
                .find { it.name == "bash" && it.isFile && it.canRead() }
            if (found != null) {
                File("$rootfsDir/bin").mkdirs()
                try { found.copyTo(binBash, overwrite = true) } catch (_: Exception) {}
            }
        }
        if (binBash.exists()) { binBash.setExecutable(true, false); binBash.setReadable(true, false) }
        if (usrBinBash.exists()) { usrBinBash.setExecutable(true, false); usrBinBash.setReadable(true, false) }
    }

    private fun ensureCriticalBinaries() {
        val usrBinEnv = File("$rootfsDir/usr/bin/env")
        if (usrBinEnv.exists()) return
        val binEnv = File("$rootfsDir/bin/env")
        if (binEnv.exists()) {
            usrBinEnv.parentFile?.mkdirs()
            try { Os.symlink("../../bin/env", usrBinEnv.absolutePath); return } catch (_: Exception) {}
            try { binEnv.copyTo(usrBinEnv, overwrite = true); usrBinEnv.setExecutable(true, false); return } catch (_: Exception) {}
        }
        usrBinEnv.parentFile?.mkdirs()
        try { usrBinEnv.writeText("#!/bin/sh\nexec \"\$@\"\n"); usrBinEnv.setExecutable(true, false) } catch (_: Exception) {}
        val usrBinBash = File("$rootfsDir/usr/bin/bash")
        if (!usrBinBash.exists()) {
            val binBash = File("$rootfsDir/bin/bash")
            if (binBash.exists()) {
                try { Os.symlink("../../bin/bash", usrBinBash.absolutePath) } catch (_: Exception) { try { binBash.copyTo(usrBinBash, overwrite = true); usrBinBash.setExecutable(true, false) } catch (_: Exception) {} }
            }
        }
    }

    /**
     * Detect the installed Python version and ensure the corresponding
     * dist-packages directory exists. Called after rootfs extraction and
     * after apt-get installs Python.
     */
    fun ensurePythonDistPackages() {
        val python3Bin = File("$rootfsDir/usr/bin/python3")
        if (!python3Bin.exists()) return

        try {
            // Read Python version from the binary's symlink or by checking common paths
            val possibleVersions = listOf("3.12", "3.11", "3.10", "3.13")
            for (ver in possibleVersions) {
                val distDir = File("$rootfsDir/usr/local/lib/python$ver/dist-packages")
                if (distDir.exists() || File("$rootfsDir/usr/lib/python$ver").exists()) {
                    distDir.mkdirs()
                    break
                }
            }
            // Always ensure the generic python3 path exists
            File("$rootfsDir/usr/local/lib/python3/dist-packages").mkdirs()
        } catch (_: Exception) {}
    }

    private fun ensureDefaultTimezone() {
        val rootfs = File(rootfsDir)
        if (!rootfs.exists()) {
            return
        }

        // Read device timezone instead of hardcoding Asia/Shanghai
        val timezone = try {
            java.util.TimeZone.getDefault().id ?: "Asia/Shanghai"
        } catch (_: Exception) {
            "Asia/Shanghai"
        }
        val timezoneFile = File("$rootfsDir/etc/timezone")
        timezoneFile.parentFile?.mkdirs()
        timezoneFile.writeText("$timezone\n")

        val zoneinfo = File("$rootfsDir/usr/share/zoneinfo/$timezone")
        if (!zoneinfo.exists()) {
            return
        }

        val localtime = File("$rootfsDir/etc/localtime")
        try {
            localtime.delete()
        } catch (_: Exception) {}

        try {
            Os.symlink("/usr/share/zoneinfo/$timezone", localtime.absolutePath)
        } catch (_: Exception) {
            try {
                zoneinfo.copyTo(localtime, overwrite = true)
            } catch (_: Exception) {}
        }
    }

    /**
     * Ensure all files in executable directories have the execute bit set.
     * Java's File API doesn't support full Unix permissions, so tar extraction
     * may leave some binaries without +x, causing "Could not exec dpkg" (error 100).
     */
    private fun fixBinPermissions() {
        // Directories whose files (recursively) must be executable
        val recursiveExecDirs = listOf(
            "$rootfsDir/usr/bin",
            "$rootfsDir/usr/sbin",
            "$rootfsDir/usr/local/bin",
            "$rootfsDir/usr/local/sbin",
            "$rootfsDir/usr/lib/apt/methods",
            "$rootfsDir/usr/lib/dpkg",
            "$rootfsDir/usr/lib/git-core",     // git sub-commands (git-remote-https, etc.)
            "$rootfsDir/usr/libexec",
            "$rootfsDir/var/lib/dpkg/info",    // dpkg maintainer scripts (preinst/postinst/prerm/postrm)
            "$rootfsDir/usr/share/debconf",    // debconf frontend scripts
            // These might be symlinks to usr/* in merged /usr, but
            // if they're real dirs we need to fix them too
            "$rootfsDir/bin",
            "$rootfsDir/sbin",
        )
        for (dirPath in recursiveExecDirs) {
            val dir = File(dirPath)
            if (dir.exists() && dir.isDirectory) {
                fixExecRecursive(dir)
            }
        }
        // Also fix shared libraries (dpkg, apt, etc. link against them)
        val libDirs = listOf(
            "$rootfsDir/usr/lib",
            "$rootfsDir/lib",
        )
        for (dirPath in libDirs) {
            val dir = File(dirPath)
            if (dir.exists() && dir.isDirectory) {
                fixSharedLibsRecursive(dir)
            }
        }
    }

    /** Recursively set +rx on all regular files in a directory tree. */
    private fun fixExecRecursive(dir: File) {
        dir.listFiles()?.forEach { file ->
            if (file.isDirectory) {
                fixExecRecursive(file)
            } else if (file.isFile) {
                file.setReadable(true, false)
                file.setExecutable(true, false)
            }
        }
    }

    private fun fixSharedLibsRecursive(dir: File) {
        dir.listFiles()?.forEach { file ->
            if (file.isDirectory) {
                fixSharedLibsRecursive(file)
            } else if (file.name.endsWith(".so") || file.name.contains(".so.")) {
                file.setReadable(true, false)
                file.setExecutable(true, false)
            }
        }
    }

    /**
     * Register Android UID/GID in the rootfs user databases,
     * matching what proot-distro does during installation.
     * This ensures dpkg/apt can resolve user/group names.
     */
    private fun registerAndroidUsers() {
        val uid = android.os.Process.myUid()
        val gid = uid // On Android, primary GID == UID

        // Ensure files are writable
        for (name in listOf("passwd", "shadow", "group", "gshadow")) {
            val f = File("$rootfsDir/etc/$name")
            if (f.exists()) f.setWritable(true, false)
        }

        // Add Android app user to /etc/passwd
        val passwd = File("$rootfsDir/etc/passwd")
        if (passwd.exists()) {
            val content = passwd.readText()
            if (!content.contains("aid_android")) {
                passwd.appendText("aid_android:x:$uid:$gid:Android:/:/sbin/nologin\n")
            }
        }

        // Add to /etc/shadow
        val shadow = File("$rootfsDir/etc/shadow")
        if (shadow.exists()) {
            val content = shadow.readText()
            if (!content.contains("aid_android")) {
                shadow.appendText("aid_android:*:18446:0:99999:7:::\n")
            }
        }

        // Add Android groups to /etc/group
        val group = File("$rootfsDir/etc/group")
        if (group.exists()) {
            val content = group.readText()
            // Add common Android groups that packages might reference
            val groups = mapOf(
                "aid_inet" to 3003,       // Internet access
                "aid_net_raw" to 3004,    // Raw sockets
                "aid_sdcard_rw" to 1015,  // SD card write
                "aid_android" to gid,     // App's own group
            )
            for ((name, id) in groups) {
                if (!content.contains(name)) {
                    group.appendText("$name:x:$id:root,aid_android\n")
                }
            }
        }

        // Add to /etc/gshadow
        val gshadow = File("$rootfsDir/etc/gshadow")
        if (gshadow.exists()) {
            val content = gshadow.readText()
            val groups = listOf("aid_inet", "aid_net_raw", "aid_sdcard_rw", "aid_android")
            for (name in groups) {
                if (!content.contains(name)) {
                    gshadow.appendText("$name:*::root,aid_android\n")
                }
            }
        }
    }

    /**
     * Extract a Python binary tarball (.tar.xz) into the rootfs.
     * The tarball contains python-3.x.x-linux-arm64/ with bin/, lib/, etc.
     * We extract its contents into /usr/local/ so python3 and pip are on PATH.
     * This bypasses the deadsnakes PPA (curl/gpg fail in proot).
     */
    fun extractPythonTarball(tarPath: String) {
        val destDir = File("$rootfsDir/usr/local")
        destDir.mkdirs()

        var entryCount = 0
        try {
            FileInputStream(tarPath).use { fis ->
                BufferedInputStream(fis, 256 * 1024).use { bis ->
                    XZCompressorInputStream(bis).use { xzis ->
                        TarArchiveInputStream(xzis).use { tis ->
                            var entry: TarArchiveEntry? = tis.nextEntry
                            while (entry != null) {
                                entryCount++
                                val name = entry.name

                                // Strip the top-level directory (node-v24.x.x-linux-arm64/)
                                val slashIdx = name.indexOf('/')
                                if (slashIdx < 0 || slashIdx == name.length - 1) {
                                    entry = tis.nextEntry
                                    continue
                                }
                                val relPath = name.substring(slashIdx + 1)
                                if (relPath.isEmpty()) {
                                    entry = tis.nextEntry
                                    continue
                                }

                                val outFile = File(destDir, relPath)

                                when {
                                    entry.isDirectory -> {
                                        outFile.mkdirs()
                                    }
                                    entry.isSymbolicLink -> {
                                        try {
                                            if (outFile.exists()) outFile.delete()
                                            outFile.parentFile?.mkdirs()
                                            Os.symlink(entry.linkName, outFile.absolutePath)
                                        } catch (_: Exception) {}
                                    }
                                    else -> {
                                        outFile.parentFile?.mkdirs()
                                        FileOutputStream(outFile).use { fos ->
                                            val buf = ByteArray(65536)
                                            var len: Int
                                            while (tis.read(buf).also { len = it } != -1) {
                                                fos.write(buf, 0, len)
                                            }
                                        }
                                        outFile.setReadable(true, false)
                                        outFile.setWritable(true, false)
                                        // Set executable for bin/ files and .so files
                                        val mode = entry.mode
                                        if (mode and 0b001_001_001 != 0 ||
                                            relPath.startsWith("bin/") ||
                                            relPath.contains(".so")) {
                                            outFile.setExecutable(true, false)
                                        }
                                    }
                                }

                                entry = tis.nextEntry
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            throw RuntimeException(
                "Python tarball extraction failed after $entryCount entries: ${e.message}"
            )
        }

        // Verify python3 binary exists
        val pythonBin = File("$rootfsDir/usr/bin/python3").let {
            if (it.exists()) it else File("$rootfsDir/usr/local/bin/python3")
        }
        if (!pythonBin.exists()) {
            throw RuntimeException(
                "Python extraction failed: python3 binary not found at /usr/local/bin/python3 " +
                "(processed $entryCount entries)"
            )
        }
        pythonBin.setExecutable(true, false)

        // Clean up tarball
        File(tarPath).delete()
    }

    /**
     * Ensure the hermes CLI entry point is executable in the rootfs.
     *
     * Hermes is installed via pip/uv which creates console_scripts entry points.
     * In proot, symlinks can fail silently. This method:
     *   1. Checks if hermes is already executable in PATH
     *   2. If not, looks for the pip-installed entry_point script
     *   3. Creates a shell wrapper as a reliable fallback
     *
     * @param entryPoint  The CLI name (default: "hermes")
     * @param moduleName  The Python module that provides the entry point
     */
    fun ensureHermesEntryPoint(
        entryPoint: String = "hermes",
        moduleName: String = "hermes_cli"
    ) {
        val binDir = File("$rootfsDir/usr/local/bin")
        binDir.mkdirs()

        val binFile = File(binDir, entryPoint)

        // If the entry point already exists and is executable, nothing to do
        if (binFile.exists() && binFile.canExecute()) return

        // Strategy 1: Try to find the pip-installed console_script
        // pip installs entry points as small Python scripts that import the module
        // Dynamically detect Python version by checking common version directories
        val sitePackagesDirs = mutableListOf(
            "$rootfsDir/usr/local/lib/python3/dist-packages",
            "$rootfsDir/usr/lib/python3/dist-packages",
        )
        // Add version-specific paths by detecting installed Python versions
        val pythonLibDir = File("$rootfsDir/usr/lib")
        if (pythonLibDir.exists()) {
            pythonLibDir.listFiles()?.filter { dir ->
                dir.isDirectory && dir.name.startsWith("python3.")
            }?.sortedByDescending { it.name }?.forEach { dir ->
                val ver = dir.name // e.g. "python3.12"
                sitePackagesDirs.add("$rootfsDir/usr/local/lib/$ver/dist-packages")
            }
        }

        // Look for hermes_agent package to find its module path
        var modulePath: String? = null
        for (siteDir in sitePackagesDirs) {
            val candidate = File(siteDir, moduleName.replace(".", "/"))
            if (candidate.exists() && File(candidate, "__init__.py").exists()) {
                modulePath = candidate.absolutePath
                break
            }
        }

        // Strategy 2: Create a shell wrapper that invokes python3 -m
        // This is more reliable than symlinks in proot.
        // Uses venv python for PEP 668 compliance, falls back to system python3
        val wrapper = buildString {
            appendLine("#!/bin/sh")
            appendLine("# Hermes Agent entry point wrapper (auto-generated)")
            appendLine("# Uses venv python for PEP 668 compliance")
            appendLine("")
            appendLine("export HOME=/root")
            appendLine("export PATH=\"/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin\"")
            appendLine("export PYTHONDONTWRITEBYTECODE=1")
            appendLine("export PIP_CACHE_DIR=/tmp/pip-cache")
            appendLine("")
            appendLine("# Try the venv python first (PEP 668 compliant install)")
            appendLine("VENV_PYTHON=\"/usr/local/lib/hermes-agent/venv/bin/python\"")
            appendLine("if [ -x \"\$VENV_PYTHON\" ]; then")
            appendLine("  exec \"\$VENV_PYTHON\" -m $moduleName \"\$@\"")
            appendLine("fi")
            appendLine("")
            appendLine("# Try the pip-installed entry_point")
            appendLine("""HERMES_BIN="${'$'}HOME/.local/bin/$entryPoint"""")
            appendLine("if [ -x ${'$'}HERMES_BIN ]; then")
            appendLine("  exec ${'$'}HERMES_BIN ${'$'}@")
            appendLine("fi")
            appendLine("")
            appendLine("# Try /usr/local/bin/hermes (wrapper from install step)")
            appendLine("if [ -x /usr/local/bin/hermes ]; then")
            appendLine("  exec /usr/local/bin/hermes ${'$'}@")
            appendLine("fi")
            appendLine("")
            appendLine("# Fallback: run via system python3 -m")
            appendLine("exec python3 -m $moduleName ${'$'}@")
        }

        binFile.writeText(wrapper)
        binFile.setExecutable(true, false)
        binFile.setReadable(true, false)
    }

    private fun deleteRecursively(file: File) {
        // CRITICAL: Do NOT follow symlinks 鈥?the rootfs contains symlinks
        // to /storage/emulated/0 (sdcard). Following them would delete the
        // user's photos, downloads, and other real files.

        // Path boundary check: refuse to delete anything outside filesDir.
        // This is a secondary safeguard against accidental data loss (#67, #63).
        try {
            if (!file.canonicalPath.startsWith(filesDir)) {
                return
            }
        } catch (_: Exception) {
            return // If we can't resolve the path, don't risk deleting
        }

        try {
            val path = file.toPath()
            if (java.nio.file.Files.isSymbolicLink(path)) {
                file.delete()
                return
            }
        } catch (_: Exception) {}
        if (file.isDirectory) {
            file.listFiles()?.forEach { deleteRecursively(it) }
        }
        file.delete()
    }

    /**
     * Set up Python-compatible PRoot environment.
     *
     * Unlike OpenClaw (Node.js), Hermes Agent is a Python application.
     * Python handles syscalls differently — the bionic-bypass.js / proot-compat.js
     * patches for Node.js are not needed. Instead we set up:
     *   - .bashrc with correct PATH and Python-friendly env vars
     *   - .gitconfig (SSH→HTTPS rewrite, since PRoot has no SSH keys)
     *   - Pre-created directories (already handled by configureRootfs)
     */
    fun installBionicBypass() {
        val bashrc = File("$rootfsDir/root/.bashrc")
        val bashrcContent = buildString {
            appendLine("# Hermes Agent PRoot environment")
            appendLine("")
            appendLine("# ★ Critical: clean Python env vars that may leak from Android JVM.")
            appendLine("# install.sh does this too — without it, hermes imports fail silently.")
            appendLine("unset PYTHONPATH")
            appendLine("unset PYTHONHOME")
            appendLine("")
            appendLine("export HOME=/root")
            appendLine("export PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"")
            appendLine("export LANG=C.UTF-8")
            appendLine("export TERM=xterm-256color")
            appendLine("export TMPDIR=/tmp")
            appendLine("export DEBIAN_FRONTEND=noninteractive")
            // Python-specific: avoid bytecode cache issues in PRoot
            appendLine("export PYTHONDONTWRITEBYTECODE=1")
            // pip cache in writable tmp
            appendLine("export PIP_CACHE_DIR=/tmp/pip-cache")
            // Ensure uv doesn't pick up stale config
            appendLine("export UV_NO_CONFIG=1")
            // Android API level for Python C extension compilation
            appendLine("export ANDROID_API_LEVEL=28")
            appendLine("")
            appendLine("# Ensure local bin is on PATH (hermes installs there)")
            appendLine("export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"")
            appendLine("")
            appendLine("# Activate hermes venv if available (PEP 668 compliance)")
            appendLine("if [ -f /root/.hermes/hermes-agent/venv/bin/activate ]; then")
            appendLine("  source /root/.hermes/hermes-agent/venv/bin/activate")
            appendLine("fi")
            appendLine("")
            appendLine("# Hermes Agent alias (use venv python)")
            appendLine("alias hermes='/root/.hermes/hermes-agent/venv/bin/python -m hermes_cli'")
        }

        // Only overwrite if not already set up (avoid clobbering user changes)
        val existing = if (bashrc.exists()) bashrc.readText() else ""
        if (!existing.contains("Hermes Agent PRoot environment")) {
            bashrc.writeText(bashrcContent)
        }

        // Git config — rewrite SSH URLs to HTTPS (no SSH keys in PRoot)
        // Also set user.name/email so git commit works (install.sh uses git)
        val gitConfig = File("$rootfsDir/root/.gitconfig")
        if (!gitConfig.exists() || !gitConfig.readText().contains("insteadOf")) {
            gitConfig.writeText(
                "[user]\n" +
                "\temail = hermes@localhost\n" +
                "\tname = Hermes Installer\n" +
                "[url \"https://github.com/\"]\n" +
                "\tinsteadOf = ssh://git@github.com/\n" +
                "\tinsteadOf = git@github.com:\n" +
                "[advice]\n" +
                "\tdetachedHead = false\n"
            )
        }
    }

    /**
     * Read DNS servers from Android's active network. Falls back to
     * public DNS servers if system DNS is unavailable (#60).
     */
    private fun getSystemDnsServers(): String {
        val fallbackServers = listOf("223.5.5.5", "119.29.29.29", "8.8.8.8")
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            if (cm != null) {
                val network = cm.activeNetwork
                if (network != null) {
                    val linkProps: LinkProperties? = cm.getLinkProperties(network)
                    val dnsServers = linkProps?.dnsServers
                    if (dnsServers != null && dnsServers.isNotEmpty()) {
                        val servers = (dnsServers.mapNotNull { it.hostAddress } + fallbackServers)
                            .map { it.trim() }
                            .filter { it.isNotEmpty() }
                            .distinct()
                            .take(3)
                        return servers.joinToString("\n") { "nameserver $it" } + "\n"
                    }
                }
            }
        } catch (_: Exception) {}
        return fallbackServers.joinToString("\n") { "nameserver $it" } + "\n"
    }

    fun writeResolvConf() {
        val content = getSystemDnsServers()

        // Ensure config directory exists (defensive against silent mkdirs failures)
        val configDirFile = File(configDir)
        if (!configDirFile.isDirectory) {
            configDirFile.mkdirs()
            if (!configDirFile.isDirectory) {
                try { Runtime.getRuntime().exec(arrayOf("mkdir", "-p", configDir)).waitFor() } catch (_: Exception) {}
            }
        }

        val resolvFile = File("$configDir/resolv.conf")
        try {
            resolvFile.writeText(content)
            resolvFile.setReadable(true, false)
            resolvFile.setWritable(true, false)
        } catch (_: Exception) {}

        // Also write directly into rootfs /etc/resolv.conf so DNS works
        // even if the bind-mount fails or hasn't been set up yet (#40).
        try {
            val rootfsResolv = File("$rootfsDir/etc/resolv.conf")
            rootfsResolv.parentFile?.mkdirs()
            rootfsResolv.writeText(content)
            rootfsResolv.setReadable(true, false)
            rootfsResolv.setWritable(true, false)
        } catch (_: Exception) {}
    }

    fun exportWorkspaceBackup(
        output: OutputStream,
        appVersion: String,
        hermesVersion: String?
    ) {
        setupDirectories()
        val workspaceRoot = workspaceRootDir
        workspaceRoot.mkdirs()

        ZipOutputStream(BufferedOutputStream(output)).use { zip ->
            val manifest = JSONObject().apply {
                put("format", workspaceBackupFormat)
                put("schemaVersion", 1)
                put("appVersion", appVersion.trim())
                if (hermesVersion.isNullOrBlank()) {
                    put("hermesVersion", JSONObject.NULL)
                } else {
                    put("hermesVersion", hermesVersion.trim())
                }
                put("createdAt", java.time.Instant.now().toString())
                put("workspaceRoot", "/root/.hermes")
                put(
                    "entries",
                    JSONArray().apply {
                        workspaceBackupRelativePaths.forEach { put(it) }
                    }
                )
            }

            zip.putNextEntry(ZipEntry(workspaceBackupManifestName))
            zip.write(manifest.toString(2).toByteArray(Charsets.UTF_8))
            zip.closeEntry()

            workspaceBackupRelativePaths.forEach { relativePath ->
                val target = File(workspaceRoot, relativePath)
                if (target.exists()) {
                    addWorkspaceBackupEntry(zip, target, relativePath)
                }
            }
        }
    }

    fun inspectWorkspaceBackup(path: String): Map<String, Any>? {
        val manifest = readWorkspaceBackupManifest(File(path)) ?: return null
        val entries = ArrayList<String>()
        val jsonEntries = manifest.optJSONArray("entries")
        if (jsonEntries != null) {
            for (index in 0 until jsonEntries.length()) {
                val value = jsonEntries.optString(index)
                if (value.isNotBlank()) {
                    entries.add(value)
                }
            }
        }

        return hashMapOf(
            "format" to manifest.optString("format", ""),
            "schemaVersion" to manifest.optInt("schemaVersion", 1),
            "appVersion" to manifest.optString("appVersion", ""),
            "hermesVersion" to manifest.optString("hermesVersion", ""),
            "createdAt" to manifest.optString("createdAt", ""),
            "entries" to entries
        )
    }

    fun restoreWorkspaceBackup(path: String) {
        val archiveFile = File(path)
        val manifest = readWorkspaceBackupManifest(archiveFile)
            ?: throw IllegalArgumentException(
                "Selected file is not a Hermes workspace backup"
            )

        if (manifest.optString("format") != workspaceBackupFormat) {
            throw IllegalArgumentException("Unsupported workspace backup format")
        }

        setupDirectories()
        val workspaceRoot = workspaceRootDir
        workspaceRoot.mkdirs()
        val workspaceCanonicalRoot = workspaceRoot.canonicalPath

        validateWorkspaceBackupArchive(archiveFile)
        clearWorkspaceBackupTargets()

        ZipFile(archiveFile).use { zip ->
            val entries = zip.entries()
            while (entries.hasMoreElements()) {
                val entry = entries.nextElement()
                val normalizedName = entry.name.replace('\\', '/')
                if (normalizedName == workspaceBackupManifestName) {
                    continue
                }
                if (!normalizedName.startsWith("workspace/")) {
                    throw IllegalArgumentException(
                        "Unsupported workspace backup entry: $normalizedName"
                    )
                }

                val relativePath = normalizedName
                    .removePrefix("workspace/")
                    .trim('/')
                if (relativePath.isEmpty()) {
                    continue
                }
                if (!isAllowedWorkspaceBackupPath(relativePath) ||
                    relativePath.contains("..") ||
                    relativePath.startsWith("/")
                ) {
                    throw IllegalArgumentException(
                        "Unsafe workspace backup entry: $normalizedName"
                    )
                }

                val outputFile = File(workspaceRoot, relativePath)
                outputFile.parentFile?.mkdirs()
                val canonicalOutput = outputFile.canonicalPath
                if (canonicalOutput != workspaceCanonicalRoot &&
                    !canonicalOutput.startsWith("$workspaceCanonicalRoot${File.separator}")
                ) {
                    throw IllegalArgumentException(
                        "Workspace backup entry escapes target directory: $normalizedName"
                    )
                }

                if (entry.isDirectory || normalizedName.endsWith("/")) {
                    outputFile.mkdirs()
                    continue
                }

                zip.getInputStream(entry).use { input ->
                    FileOutputStream(outputFile).use { fileOutput ->
                        input.copyTo(fileOutput)
                    }
                }
                outputFile.setReadable(true, false)
                outputFile.setWritable(true, false)
            }
        }

        setupDirectories()
        installBionicBypass()
        writeResolvConf()
    }

    private fun addWorkspaceBackupEntry(
        zip: ZipOutputStream,
        file: File,
        relativePath: String
    ) {
        val normalizedPath = relativePath.replace('\\', '/').trim('/')
        if (normalizedPath.isEmpty()) {
            return
        }

        try {
            if (java.nio.file.Files.isSymbolicLink(file.toPath())) {
                return
            }
        } catch (_: Exception) {}

        if (file.isDirectory) {
            zip.putNextEntry(ZipEntry("workspace/$normalizedPath/"))
            zip.closeEntry()
            file.listFiles()
                ?.sortedBy { it.name }
                ?.forEach { child ->
                    addWorkspaceBackupEntry(
                        zip,
                        child,
                        "$normalizedPath/${child.name}"
                    )
                }
            return
        }

        zip.putNextEntry(ZipEntry("workspace/$normalizedPath"))
        FileInputStream(file).use { input ->
            input.copyTo(zip)
        }
        zip.closeEntry()
    }

    private fun clearWorkspaceBackupTargets() {
        val workspaceRoot = workspaceRootDir
        workspaceBackupRelativePaths.forEach { relativePath ->
            val target = File(workspaceRoot, relativePath)
            if (target.exists()) {
                deleteRecursively(target)
            }
        }
    }

    private fun validateWorkspaceBackupArchive(archiveFile: File) {
        ZipFile(archiveFile).use { zip ->
            val entries = zip.entries()
            while (entries.hasMoreElements()) {
                val entry = entries.nextElement()
                val normalizedName = entry.name.replace('\\', '/')
                if (normalizedName == workspaceBackupManifestName) {
                    continue
                }
                if (!normalizedName.startsWith("workspace/")) {
                    throw IllegalArgumentException(
                        "Unsupported workspace backup entry: $normalizedName"
                    )
                }

                val relativePath = normalizedName
                    .removePrefix("workspace/")
                    .trim('/')
                if (relativePath.isEmpty()) {
                    continue
                }
                if (!isAllowedWorkspaceBackupPath(relativePath) ||
                    relativePath.contains("..") ||
                    relativePath.startsWith("/")
                ) {
                    throw IllegalArgumentException(
                        "Unsafe workspace backup entry: $normalizedName"
                    )
                }
            }
        }
    }

    private fun isAllowedWorkspaceBackupPath(relativePath: String): Boolean {
        return workspaceBackupRelativePaths.any { allowed ->
            relativePath == allowed || relativePath.startsWith("$allowed/")
        }
    }

    private fun readWorkspaceBackupManifest(archiveFile: File): JSONObject? {
        if (!archiveFile.exists() || !archiveFile.isFile) {
            return null
        }

        return try {
            ZipFile(archiveFile).use { zip ->
                val entry = zip.getEntry(workspaceBackupManifestName) ?: return null
                val content = zip.getInputStream(entry)
                    .bufferedReader(Charsets.UTF_8)
                    .use { it.readText() }
                val manifest = JSONObject(content)
                if (manifest.optString("format") == workspaceBackupFormat) {
                    manifest
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    /** Read a file from inside the rootfs (e.g. /root/.hermes/config.yaml). */
    fun readRootfsFile(path: String): String? {
        val file = File("$rootfsDir/$path")
        return if (file.exists()) file.readText() else null
    }

    /** Write content to a file inside the rootfs, creating parent dirs as needed. */
    fun writeRootfsFile(path: String, content: String) {
        val file = File("$rootfsDir/$path")
        file.parentFile?.mkdirs()
        file.writeText(content)
    }

    fun copyBundledAssetToFile(assetPath: String, destinationPath: String) {
        val assetKey = FlutterInjector.instance()
            .flutterLoader()
            .getLookupKeyForAsset(assetPath)
        val destinationFile = File(destinationPath)
        destinationFile.parentFile?.mkdirs()

        try {
            context.assets.open(assetKey).use { input ->
                FileOutputStream(destinationFile).use { output ->
                    input.copyTo(output)
                }
            }
        } catch (e: FileNotFoundException) {
            throw RuntimeException("Bundled asset not found: $assetPath")
        }

        destinationFile.setReadable(true, false)
        destinationFile.setWritable(true, false)
    }

    /**
     * Create fake /proc and /sys files that are bind-mounted into proot.
     * Android restricts access to many /proc entries; proot-distro works
     * around this by providing static fake data. We replicate that approach.
     */
    fun setupFakeSysdata() {
        HostFilesystem.ensureDirectoryReady(configDir, "config directory")
        val procDir = HostFilesystem.ensureDirectoryReady(
            "$configDir/proc_fakes",
            "fake /proc directory"
        )
        val sysDir = HostFilesystem.ensureDirectoryReady(
            "$configDir/sys_fakes",
            "fake /sys directory"
        )

        // /proc/loadavg
        File(procDir, "loadavg").writeText("0.12 0.07 0.02 2/165 765\n")

        // /proc/stat 鈥?matching proot-distro (8 CPUs)
        File(procDir, "stat").writeText(
            "cpu  1957 0 2877 93280 262 342 254 87 0 0\n" +
            "cpu0 31 0 226 12027 82 10 4 9 0 0\n" +
            "cpu1 45 0 290 11498 21 9 8 7 0 0\n" +
            "cpu2 52 0 401 11730 36 15 6 10 0 0\n" +
            "cpu3 42 0 268 11677 31 12 5 8 0 0\n" +
            "cpu4 789 0 720 11364 26 100 83 18 0 0\n" +
            "cpu5 486 0 438 11685 42 86 60 13 0 0\n" +
            "cpu6 314 0 336 11808 45 68 52 11 0 0\n" +
            "cpu7 198 0 198 11491 25 42 36 11 0 0\n" +
            "intr 63361 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n" +
            "ctxt 38014093\n" +
            "btime 1694292441\n" +
            "processes 26442\n" +
            "procs_running 1\n" +
            "procs_blocked 0\n" +
            "softirq 75663 0 5903 6 25375 10774 0 243 11685 0 21677\n"
        )

        // /proc/uptime
        File(procDir, "uptime").writeText("124.08 932.80\n")

        // /proc/version 鈥?fake kernel info matching proot-distro v4.37.0
        File(procDir, "version").writeText(
            "Linux version ${ProcessManager.FAKE_KERNEL_RELEASE} (proot@termux) " +
            "(gcc (GCC) 13.3.0, GNU ld (GNU Binutils) 2.42) " +
            "${ProcessManager.FAKE_KERNEL_VERSION}\n"
        )

        // /proc/vmstat 鈥?matching proot-distro format
        File(procDir, "vmstat").writeText(
            "nr_free_pages 1743136\n" +
            "nr_zone_inactive_anon 179281\n" +
            "nr_zone_active_anon 7183\n" +
            "nr_zone_inactive_file 22858\n" +
            "nr_zone_active_file 51328\n" +
            "nr_zone_unevictable 642\n" +
            "nr_zone_write_pending 0\n" +
            "nr_mlock 0\n" +
            "nr_slab_reclaimable 7520\n" +
            "nr_slab_unreclaimable 10776\n" +
            "pgpgin 198292\n" +
            "pgpgout 7674\n" +
            "pswpin 0\n" +
            "pswpout 0\n" +
            "pgalloc_dma 0\n" +
            "pgalloc_dma32 0\n" +
            "pgalloc_normal 44669136\n" +
            "pgfree 46674674\n" +
            "pgactivate 1085674\n" +
            "pgdeactivate 340776\n" +
            "pglazyfree 139872\n" +
            "pgfault 37291463\n" +
            "pgmajfault 6854\n" +
            "pgrefill 480634\n"
        )

        // /proc/sys/kernel/cap_last_cap
        File(procDir, "cap_last_cap").writeText("40\n")

        // /proc/sys/fs/inotify/max_user_watches
        File(procDir, "max_user_watches").writeText("4096\n")

        // /proc/sys/crypto/fips_enabled 鈥?libgcrypt reads this on startup;
        // missing/unreadable on Android causes apt HTTP method to SIGABRT
        File(procDir, "fips_enabled").writeText("0\n")

        // Empty file for /sys/fs/selinux bind
        File(sysDir, "empty").writeText("")
    }

    private fun checkHermesInProot(): Boolean {
        return try {
            val pm = ProcessManager(filesDir, nativeLibDir)
            val venvPython = "/root/.hermes/hermes-agent/venv/bin/python"
            // First, fix __main__.py if missing (prevents "No module named hermes_cli.__main__" error)
            // Use venv python since hermes_cli is installed there
            pm.runInProotSync(
                "HERMES_PKG=\$(\"$venvPython\" -c \"import hermes_cli,os;print(os.path.dirname(hermes_cli.__file__))\" 2>/dev/null) && " +
                "if [ -n \"\$HERMES_PKG\" ] && [ ! -f \"\$HERMES_PKG/__main__.py\" ]; then " +
                "echo \"from hermes_cli.main import main\" > \"\$HERMES_PKG/__main__.py\" && " +
                "echo \"main()\" >> \"\$HERMES_PKG/__main__.py\"; fi",
                timeoutSeconds = 15
            )
            val output = pm.runInProotSync(
                "export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\" && " +
                "(command -v hermes 2>/dev/null || " +
                "\"$venvPython\" -m hermes_cli --version 2>/dev/null) 2>/dev/null"
            )
            output.trim().isNotEmpty()
        } catch (e: Exception) {
            false
        }
    }
}

