import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import 'native_bridge.dart';
import 'proot_dns_service.dart';

typedef HermesInstallProgressCallback = void Function(
  HermesInstallProgress progress,
);

class HermesReleaseInfo {
  final String version;
  final String? tarballUrl;
  final String? unpackedSizeLabel;
  final String? nodeRequirement;

  const HermesReleaseInfo({
    required this.version,
    this.tarballUrl,
    this.unpackedSizeLabel,
    this.nodeRequirement,
  });

  factory HermesReleaseInfo.fromJson(Map<String, dynamic> json) {
    // PyPI top-level response has version inside 'info', not at root
    final info = json['info'];
    final version = ((json['version'] as String?) ??
            (info is Map ? info['version'] as String? : null))
        ?.trim() ?? '';
    // PyPI uses 'urls' array with 'sdist' type
    String? tarballUrl;
    final urls = json['urls'];
    if (urls is List) {
      for (final urlEntry in urls) {
        if (urlEntry is Map && urlEntry['packagetype'] == 'sdist') {
          tarballUrl = urlEntry['url'] as String?;
          break;
        }
      }
    }
    // Fallback: use 'info' -> 'download_url'
    if (tarballUrl == null) {
      if (info is Map) {
        tarballUrl = info['download_url'] as String?;
      }
    }
    // Try to extract size info from PyPI response
    String? unpackedSizeLabel;
    if (info is Map) {
      final size = info['size'];
      if (size is int && size > 0) {
        unpackedSizeLabel = HermesVersionService.formatBytes(size);
      }
    }
    // Check for node requirement in classifiers or description
    String? nodeRequirement;
    if (info is Map) {
      final desc = info['description'] as String? ?? '';
      final nodeMatch = RegExp(r'node\.?js\s*[v≥>=]*\s*(\d+)', caseSensitive: false).firstMatch(desc);
      if (nodeMatch != null) {
        nodeRequirement = 'Node.js ${nodeMatch.group(1)}+';
      }
    }
    return HermesReleaseInfo(
      version: version,
      tarballUrl: tarballUrl,
      unpackedSizeLabel: unpackedSizeLabel,
      nodeRequirement: nodeRequirement,
    );
  }
}

class HermesInstallProgress {
  final double progress;
  final String message;
  final String? detail;

  const HermesInstallProgress({
    required this.progress,
    required this.message,
    this.detail,
  });
}

class HermesVersionService {
  static const _pypiEndpoint = 'https://pypi.org/pypi/hermes-agent/json';
  final Dio _dio = Dio();
  HermesInstallProgress _lastProgress = const HermesInstallProgress(
    progress: 0.0,
    message: '',
  );

  double _clampProgress(double progress) => progress.clamp(0.0, 1.0).toDouble();

  void _emitProgress(
    HermesInstallProgressCallback? onProgress, {
    required double progress,
    required String message,
    String? detail,
    bool preserveDetail = false,
  }) {
    final nextDetail = preserveDetail ? _lastProgress.detail : detail;
    _lastProgress = HermesInstallProgress(
      progress: _clampProgress(progress),
      message: message,
      detail: nextDetail,
    );
    onProgress?.call(_lastProgress);
  }

  Future<T> _runEstimatedProgress<T>({
    required HermesInstallProgressCallback? onProgress,
    required double startProgress,
    required double targetProgress,
    required String message,
    required Future<T> Function() task,
    required Duration estimatedDuration,
    String? detail,
    Duration tick = const Duration(milliseconds: 800),
  }) async {
    _emitProgress(onProgress, progress: startProgress, message: message, detail: detail);
    final future = task();
    var isDone = false;
    future.whenComplete(() => isDone = true);
    final stopwatch = Stopwatch()..start();
    final durationMs = estimatedDuration.inMilliseconds <= 0
        ? 1.0
        : estimatedDuration.inMilliseconds.toDouble();
    var lastProgress = -1.0;

    while (!isDone) {
      await Future.delayed(tick);
      if (isDone) break;
      final elapsedFactor = stopwatch.elapsedMilliseconds / durationMs;
      final easedRatio = (1 - math.exp(-2.2 * elapsedFactor)).clamp(0.0, 1.0).toDouble();
      final currentProgress = startProgress + ((targetProgress - startProgress) * easedRatio);
      if ((currentProgress - lastProgress).abs() < 0.003) continue;
      lastProgress = currentProgress;
      _emitProgress(onProgress, progress: currentProgress, message: message, preserveDetail: true);
    }
    return await future;
  }

  static const _venvPath = '/root/.hermes/hermes-agent/venv';

  Future<String?> readInstalledVersion() async {
    try {
      await ProotDnsService.ensureReady();
      // Try multiple entry points:
      // 1. venv hermes wrapper
      // 2. venv python3 -m hermes_cli
      // 3. /usr/local/bin/hermes (legacy)
      // 4. system python3 -m hermes_cli (legacy)
      final output = await NativeBridge.runInProot(
        'unset PYTHONPATH; unset PYTHONHOME; '
        'export HOME=/root && '
        'if [ -x "$_venvPath/bin/python" ]; then '
        '  "$_venvPath/bin/hermes" --version 2>/dev/null || '
        '  "$_venvPath/bin/python" -m hermes_cli --version 2>/dev/null; '
        'else '
        '  export PATH="/usr/local/bin:\$HOME/.local/bin:\$PATH" && '
        '  /usr/local/bin/hermes --version 2>/dev/null || '
        '  python3 -m hermes_cli --version 2>/dev/null || true; '
        'fi',
        timeout: 30,
      );
      final trimmed = output.trim();
      if (trimmed.isEmpty) return null;
      final match = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(trimmed);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  Future<HermesReleaseInfo> fetchLatestRelease() async {
    final response = await http.get(
      Uri.parse(_pypiEndpoint),
      headers: const {'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 12));

    if (response.statusCode != 200) {
      throw Exception('PyPI returned ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Invalid PyPI response');
    }
    final release = HermesReleaseInfo.fromJson(decoded);
    if (release.version.isEmpty) {
      throw Exception('Latest version missing from PyPI response');
    }
    return release;
  }

  Future<List<HermesReleaseInfo>> fetchAvailableReleases({int? limit}) async {
    // Use GitHub Releases API to get full version list with tag→PyPI version mapping.
    // PyPI only returns the latest version, but users need to see all available versions.
    // Apply GitHub proxy for acceleration in mainland China.
    try {
      final githubApiUrl = AppConstants.proxiedGithubUrl(
        'https://api.github.com/repos/NousResearch/hermes-agent/releases?per_page=20',
      );
      final response = await http.get(
        Uri.parse(githubApiUrl),
        headers: const {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is List) {
          final releases = <HermesReleaseInfo>[];
          for (final release in decoded) {
            if (release is! Map<String, dynamic>) continue;
            // Extract PyPI version from release name: "Hermes Agent v0.14.0 (2026.5.16)"
            final name = release['name'] as String? ?? '';
            final versionMatch = RegExp(r'v?(\d+\.\d+\.\d+)').firstMatch(name);
            if (versionMatch == null) continue;
            final pypiVersion = versionMatch.group(1)!;
            releases.add(HermesReleaseInfo(version: pypiVersion));
          }
          if (releases.isNotEmpty) {
            if (limit != null && limit > 0 && releases.length > limit) {
              return releases.sublist(0, limit);
            }
            return releases;
          }
        }
      }
    } catch (_) {
      // Fall through to PyPI fallback
    }

    // Fallback: PyPI (only returns latest version)
    final response = await http.get(
      Uri.parse('$_pypiEndpoint'),
      headers: const {'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('PyPI returned ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Invalid PyPI response');
    }
    final releases = <HermesReleaseInfo>[];
    final info = decoded['info'];
    final version = (decoded['version'] as String?) ??
        (info is Map ? info['version'] as String? : null);
    if (version is String && version.trim().isNotEmpty) {
      releases.add(HermesReleaseInfo(version: version.trim()));
    }
    if (limit != null && limit > 0 && releases.length > limit) {
      return releases.sublist(0, limit);
    }
    return releases;
  }

  Future<void> installVersion(
    String version, {
    HermesReleaseInfo? releaseInfo,
    HermesInstallProgressCallback? onProgress,
    bool captureLiveLogs = true,
    String? pipIndexUrl,
  }) async {
    _lastProgress = const HermesInstallProgress(progress: 0.0, message: '');

    try {
      await ProotDnsService.ensureReady();

      final normalizedVersion = version.trim();
      if (normalizedVersion.isEmpty) {
        throw Exception('Version cannot be empty');
      }

      _emitProgress(onProgress, progress: 0.05, message: 'Preparing environment...');

      final androidApiLevel = await _detectAndroidApiLevel();

      // Diagnostic: verify PRoot is working at all
      try {
        final prootTest = await NativeBridge.runInProot('echo PROOT_OK && id && ls /bin/bash', timeout: 10);
        // ignore: avoid_print
        print('[HermesInstall] PRoot test: $prootTest');
      } catch (e) {
        // ignore: avoid_print
        print('[HermesInstall] PRoot test FAILED: $e');
        throw Exception('PRoot 环境无法启动，请检查 rootfs 是否安装完成: $e');
      }

      // Ensure basic tools are available (git, curl, python3, pip).
      try {
        await _runEstimatedProgress(
          onProgress: onProgress,
          startProgress: 0.05,
          targetProgress: 0.15,
          message: 'Checking dependencies...',
          estimatedDuration: const Duration(seconds: 15),
          task: () => NativeBridge.runInProot(
            'echo "APT_STEP_START" && '
            'apt-get update -qq 2>&1 && echo "APT_UPDATE_OK" || echo "APT_UPDATE_FAIL" && '
            'apt-get install -y --no-install-recommends '
            'python3 python3-pip python3-venv git curl ca-certificates xz-utils 2>&1 && '
            'echo "APT_INSTALL_OK" || echo "APT_INSTALL_FAIL"',
            timeout: 120,
          ),
        );
        // ignore: avoid_print
        print('[HermesInstall] apt-get completed');
      } catch (e) {
        // ignore: avoid_print
        print('[HermesInstall] apt-get FAILED: $e');
        throw Exception('依赖安装失败 (apt-get): $e');
      }

      _emitProgress(onProgress, progress: 0.15, message: 'Creating virtual environment...', detail: 'python3 -m venv $_venvPath');

      // Create venv for hermes (official recommendation)
      // Handle failure gracefully — PRoot environments may fail ensurepip
      await NativeBridge.runInProot(
        'mkdir -p /root/.hermes && '
        'python3 -m venv $_venvPath 2>&1 && echo VENV_CREATED || { '
        '  echo "venv creation failed, trying --without-pip fallback"; '
        '  python3 -m venv --without-pip $_venvPath 2>&1 && '
        '  echo VENV_CREATED_NO_PIP || echo VENV_FAILED; '
        '}',
        timeout: 60,
      );

      // Verify pip exists inside the venv; if not, bootstrap it
      await NativeBridge.runInProot(
        'if [ -x "$_venvPath/bin/pip" ]; then '
        '  echo PIP_READY; '
        'elif [ -x "$_venvPath/bin/python" ]; then '
        '  echo "pip not found in venv, bootstrapping..."; '
        '  "$_venvPath/bin/python" -m ensurepip 2>/dev/null && echo PIP_BOOTSTRAP_OK || { '
        '    echo "ensurepip failed, trying get-pip.py"; '
        '    curl -fsSL https://bootstrap.pypa.io/get-pip.py 2>/dev/null | "$_venvPath/bin/python" 2>&1 && '
        '    echo PIP_GETPIPY_OK || echo PIP_BOOTSTRAP_FAILED; '
        '  }; '
        'else '
        '  echo VENV_MISSING; '
        'fi',
        timeout: 120,
      );

      // Final check: verify pip is usable (as binary or as python module)
      final pipCheck = await NativeBridge.runInProot(
        'if [ -x "$_venvPath/bin/pip" ]; then '
        '  echo PIP_BIN_OK; '
        'elif "$_venvPath/bin/python" -m pip --version 2>/dev/null; then '
        '  echo PIP_MODULE_OK; '
        'else '
        '  echo PIP_MISSING; '
        'fi',
        timeout: 15,
      );
      if (pipCheck.contains('PIP_MISSING')) {
        throw Exception(
          'Failed to create a working virtual environment with pip. '
          'Output: $pipCheck',
        );
      }

      _emitProgress(onProgress, progress: 0.18, message: 'Installing Hermes Agent from PyPI...', detail: 'Using venv + pre-compiled wheels');

      // Install from PyPI into venv
      final versionSpec = normalizedVersion.isEmpty || normalizedVersion == 'latest'
          ? 'hermes-agent'
          : 'hermes-agent==$normalizedVersion';

      await _runEstimatedProgress(
        onProgress: onProgress,
        startProgress: 0.18,
        targetProgress: 0.85,
        message: 'Installing hermes-agent from PyPI...',
        estimatedDuration: const Duration(minutes: 5),
        task: () => _runPipWheelInstall(versionSpec, pipIndexUrl: pipIndexUrl),
      );

      _emitProgress(onProgress, progress: 0.86, message: 'Ensuring aiohttp dependency...', detail: 'aiohttp required by hermes');

      // Ensure aiohttp is installed in venv
      try {
        await NativeBridge.runInProot(
          '"$_venvPath/bin/python" -c "import aiohttp" 2>/dev/null || '
          '"$_venvPath/bin/python" -m pip install aiohttp 2>&1',
          timeout: 120,
        );
      } catch (_) {
        // Non-fatal
      }

      _emitProgress(onProgress, progress: 0.88, message: 'Creating hermes command...', detail: 'Setting up entry point');

      // Create __main__.py + wrapper script pointing to venv
      await NativeBridge.runInProot(
        // Ensure __main__.py exists
        'HERMES_PKG=\$("$_venvPath/bin/python" -c "import hermes_cli,os;print(os.path.dirname(hermes_cli.__file__))" 2>/dev/null) && '
        'if [ -n "\$HERMES_PKG" ] && [ ! -f "\$HERMES_PKG/__main__.py" ]; then '
        '  echo "from hermes_cli.main import main" > "\$HERMES_PKG/__main__.py" && '
        '  echo "main()" >> "\$HERMES_PKG/__main__.py" && '
        '  echo "Created __main__.py"; fi; '
        // Create wrapper script pointing to venv
        'mkdir -p /usr/local/bin && '
        'cat > /usr/local/bin/hermes << \'WRAPPER\'\n'
        '#!/bin/sh\n'
        'export HOME=/root\n'
        'VENV="/root/.hermes/hermes-agent/venv"\n'
        'if [ -x "\$VENV/bin/python" ]; then\n'
        '  exec "\$VENV/bin/python" -m hermes_cli "\$@"\n'
        'fi\n'
        'unset PYTHONPATH 2>/dev/null\n'
        'unset PYTHONHOME 2>/dev/null\n'
        'exec python3 -m hermes_cli "\$@"\n'
        'WRAPPER\n'
        'chmod +x /usr/local/bin/hermes && '
        'echo WRAPPER_CREATED',
        timeout: 15,
      );

      _emitProgress(onProgress, progress: 0.92, message: 'Verifying installation...', detail: 'Checking hermes --version');

      // Verify hermes is available (prefer venv)
      final versionOutput = await NativeBridge.runInProot(
        'unset PYTHONPATH; unset PYTHONHOME; '
        'export HOME=/root && '
        '"$_venvPath/bin/hermes" --version 2>/dev/null || '
        '"$_venvPath/bin/python" -m hermes_cli --version 2>/dev/null || '
        '/usr/local/bin/hermes --version 2>/dev/null || '
        'echo NOT_FOUND',
        timeout: 30,
      );
      if (versionOutput.contains('NOT_FOUND')) {
        throw Exception(
          'Hermes installation completed but hermes command not found. '
          'Output: $versionOutput',
        );
      }

      _emitProgress(onProgress, progress: 1.0, message: 'Hermes Agent installed');
    } catch (e) {
      rethrow;
    }
  }

  /// Detect Android SDK API level. Tries PRoot first (getprop), then falls
  /// back to reading from the native platform channel (Build.VERSION.SDK_INT).
  Future<String> _detectAndroidApiLevel() async {
    // Try getprop inside PRoot (works if Termux binaries are available)
    try {
      final level = await NativeBridge.runInProot(
        'getprop ro.build.version.sdk 2>/dev/null',
        timeout: 5,
      ).then((v) => v.trim());
      if (level.isNotEmpty && int.tryParse(level) != null) return level;
    } catch (_) {}

    // Fallback: read from native side via platform channel
    try {
      final level = await NativeBridge.getAndroidApiLevel();
      if (level.isNotEmpty) return level;
    } catch (_) {}

    // Final fallback
    return '28';
  }

  /// Install hermes-agent from PyPI using venv + pre-compiled wheels.
  Future<String> _runPipWheelInstall(
    String versionSpec, {
    int maxRetries = 2,
    String? pipIndexUrl,
  }) async {
    final String pipFlags;
    final effectiveUrl = (pipIndexUrl ?? '').trim();
    if (effectiveUrl.isNotEmpty) {
      final uri = Uri.tryParse(effectiveUrl);
      final host = uri?.host ?? '';
      final trustedHost = host.isNotEmpty ? ' --trusted-host $host' : '';
      pipFlags = '-i $effectiveUrl$trustedHost';
    } else {
      // Default: try Alibaba Cloud mirror first, then fall back to official PyPI.
      pipFlags = '-i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com';
    }

    var lastError = '';
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final output = await NativeBridge.runInProot(
          'export PYTHONDONTWRITEBYTECODE=1 && '
          'export PIP_CACHE_DIR=/tmp/pip-cache && '
          // Upgrade pip inside venv (use python -m pip for robustness:
          // works even when bin/pip script is missing but module is installed)
          '"$_venvPath/bin/python" -m pip install --upgrade pip setuptools wheel 2>&1 && '
          // Install from PyPI into venv
          '"$_venvPath/bin/python" -m pip install "$versionSpec" $pipFlags 2>&1 && '
          'echo "PIP_INSTALL_OK"',
          timeout: 600,
        );
        return output;
      } catch (e) {
        lastError = e.toString();
        if (lastError.contains('No matching distribution') ||
            lastError.contains('Could not find a version')) {
          // Retry with official PyPI if mirror failed
          if (pipFlags.contains('mirrors.aliyun.com')) {
            try {
              final output = await NativeBridge.runInProot(
                'export PYTHONDONTWRITEBYTECODE=1 && '
                'export PIP_CACHE_DIR=/tmp/pip-cache && '
                '"$_venvPath/bin/python" -m pip install --upgrade pip setuptools wheel 2>&1 && '
                '"$_venvPath/bin/python" -m pip install "$versionSpec" -i https://pypi.org/simple/ 2>&1 && '
                'echo "PIP_INSTALL_OK"',
                timeout: 600,
              );
              return output;
            } catch (_) {}
          }
          throw Exception('Hermes Agent package not found on PyPI. Error: $lastError');
        }
        if (attempt < maxRetries &&
            (lastError.contains('Connection reset') ||
             lastError.contains('Recv failure') ||
             lastError.contains('timed out') ||
             lastError.contains('Temporary failure') ||
             lastError.contains('ReadTimeoutError') ||
             lastError.contains('Network is unreachable'))) {
          await Future.delayed(Duration(seconds: 5 * (attempt + 1)));
          continue;
        }
        rethrow;
      }
    }
    throw Exception('pip install failed after ${maxRetries + 1} attempts: $lastError');
  }

  Future<void> updateToLatest({
    HermesReleaseInfo? latestRelease,
    HermesInstallProgressCallback? onProgress,
    bool captureLiveLogs = true,
  }) async {
    final release = latestRelease ?? await fetchLatestRelease();
    await installVersion(
      release.version,
      releaseInfo: release,
      onProgress: onProgress,
      captureLiveLogs: captureLiveLogs,
    );
  }

  static bool isUpdateAvailable({
    required String? installedVersion,
    required String latestVersion,
  }) {
    if (installedVersion == null || installedVersion.trim().isEmpty) return true;
    return compareVersions(latestVersion, installedVersion) > 0;
  }

  static bool isSameVersion({
    required String? installedVersion,
    required String? targetVersion,
  }) {
    if (installedVersion == null || installedVersion.trim().isEmpty ||
        targetVersion == null || targetVersion.trim().isEmpty) {
      return false;
    }
    return compareVersions(installedVersion, targetVersion) == 0;
  }

  static int compareVersions(String left, String right) {
    final leftParts = _versionParts(left);
    final rightParts = _versionParts(right);
    final maxLength = leftParts.length > rightParts.length ? leftParts.length : rightParts.length;
    for (var i = 0; i < maxLength; i++) {
      final leftValue = i < leftParts.length ? leftParts[i] : 0;
      final rightValue = i < rightParts.length ? rightParts[i] : 0;
      if (leftValue > rightValue) return 1;
      if (leftValue < rightValue) return -1;
    }
    return 0;
  }

  static List<int> _versionParts(String version) {
    return RegExp(r'\d+')
        .allMatches(version)
        .map((match) => int.tryParse(match.group(0) ?? '0') ?? 0)
        .toList();
  }

  static String formatBytes(int bytes) {
    final mb = bytes / 1024 / 1024;
    if (mb < 100) return '~${mb.toStringAsFixed(1)} MB';
    return '~${mb.toStringAsFixed(0)} MB';
  }
}
