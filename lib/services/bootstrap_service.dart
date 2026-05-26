import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:dio/dio.dart';
import '../constants.dart';
import '../l10n/app_localizations.dart';
import '../models/hermes_install_options.dart';
import '../models/setup_state.dart';
import 'install_status_message_formatter.dart';
import 'native_bridge.dart';
import 'hermes_version_service.dart';

enum _PreparedArchiveSource {
  bundled,
  cached,
  localFile,
  externalUrl,
  none,
}

class _TransferProgressTracker {
  final _stopwatch = Stopwatch()..start();
  int _lastBytes = 0;
  double _lastSpeed = 0;

  void update(int bytes) {
    final elapsed = _stopwatch.elapsedMilliseconds;
    if (elapsed > 0) {
      _lastSpeed = bytes / (elapsed / 1000);
    }
    _lastBytes = bytes;
  }

  double get speedBytesPerSec => _lastSpeed;
  int get bytes => _lastBytes;
  int get elapsedMs => _stopwatch.elapsedMilliseconds;

  String describe(int received, int total) {
    final receivedMb = (received / 1024 / 1024).toStringAsFixed(1);
    final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
    final speed = _lastSpeed > 0
        ? '${(_lastSpeed / 1024 / 1024).toStringAsFixed(1)} MB/s'
        : '';
    return '$receivedMb / $totalMb MB${speed.isNotEmpty ? " ($speed)" : ""}';
  }
}

class _MirrorProbeResult {
  final String baseUrl;
  final int elapsedMs;

  const _MirrorProbeResult(this.baseUrl, this.elapsedMs);
}

class BootstrapService {
  final Dio _dio = Dio();
  final HermesVersionService _hermesVersionService =
      HermesVersionService();
  SetupState _lastSetupState = const SetupState();

  // Fix #2: Generate a random API key per installation instead of hardcoding "1234"
  static String _generateSecureApiKey() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '').substring(0, 32);
  }

  AppLocalizations get _notificationL10n =>
      AppLocalizations(PlatformDispatcher.instance.locale);

  void _updateSetupNotification(String text, {int progress = -1}) {
    try {
      NativeBridge.updateSetupNotification(text, progress: progress);
    } catch (_) {}
  }

  void _stopSetupService() {
    try {
      NativeBridge.stopSetupService();
    } catch (_) {}
  }

  double _clampProgress(double progress) => progress.clamp(0.0, 1.0).toDouble();

  double _overallProgressFor(SetupStep step, double stepProgress) {
    final progress = _clampProgress(stepProgress);
    switch (step) {
      case SetupStep.checkingStatus:
        return progress * 0.05;
      case SetupStep.downloadingRootfs:
        return 0.05 + (progress * 0.25);
      case SetupStep.extractingRootfs:
        return 0.30 + (progress * 0.15);
      case SetupStep.installingPython:
        return 0.45 + (progress * 0.35);
      case SetupStep.installingHermes:
        return 0.80 + (progress * 0.15);
      case SetupStep.configuringEnvironment:
        return 0.95 + (progress * 0.05);
      case SetupStep.complete:
        return 1.0;
      case SetupStep.error:
        return 0.0;
    }
  }

  String _formatPercent(double progress, {int digits = 1}) =>
      '${(_clampProgress(progress) * 100).toStringAsFixed(digits)}%';

  bool _statusFlag(Map<String, dynamic> status, String key) =>
      status[key] == true;

  Future<bool> _isInstalledPythonUsable() async {
    try {
      await NativeBridge.runInProot('python3 --version', timeout: 30);
      return true;
    } catch (_) {
      return false;
    }
  }

  static const _venvPath = '/root/.hermes/hermes-agent/venv';

  Future<bool> _isInstalledHermesUsable() async {
    try {
      await NativeBridge.runInProot(
        'unset PYTHONPATH; unset PYTHONHOME; '
        'export HOME=/root && '
        'if [ -x "$_venvPath/bin/python" ]; then '
        '  "$_venvPath/bin/hermes" --version 2>/dev/null || '
        '  "$_venvPath/bin/python" -m hermes_cli --version 2>/dev/null; '
        'else '
        '  export PATH="/usr/local/bin:\$HOME/.local/bin:\$PATH" && '
        '  (hermes --version || python3 -m hermes_cli --version) 2>/dev/null; '
        'fi',
        timeout: 30,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<_PreparedArchiveSource> _prepareBundledOrCachedArchive({
    String? assetPath,
    required String destinationPath,
  }) async {
    if (assetPath == null || assetPath.isEmpty) {
      return _PreparedArchiveSource.none;
    }
    final file = File(destinationPath);
    if (file.existsSync() && file.lengthSync() > 0) {
      return _PreparedArchiveSource.cached;
    }
    if (file.existsSync()) {
      try {
        file.deleteSync();
      } catch (_) {}
    }

    try {
      await NativeBridge.copyBundledAssetToFile(
        assetPath: assetPath,
        destinationPath: destinationPath,
      );
      if (file.existsSync() && file.lengthSync() > 0) {
        return _PreparedArchiveSource.bundled;
      }
    } catch (_) {
      return _PreparedArchiveSource.none;
    }

    return _PreparedArchiveSource.none;
  }

  Future<_PreparedArchiveSource> _prepareLocalArchive({
    required String sourcePath,
    required String destinationPath,
  }) async {
    final source = File(sourcePath);
    if (!source.existsSync() || source.lengthSync() <= 0) {
      return _PreparedArchiveSource.none;
    }

    final destination = File(destinationPath);
    if (source.absolute.path == destination.absolute.path) {
      return _PreparedArchiveSource.localFile;
    }

    if (destination.existsSync()) {
      try {
        destination.deleteSync();
      } catch (_) {}
    }
    destination.parent.createSync(recursive: true);
    await source.copy(destinationPath);
    return destination.existsSync() && destination.lengthSync() > 0
        ? _PreparedArchiveSource.localFile
        : _PreparedArchiveSource.none;
  }

  void _deleteArchiveIfExists(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  Future<void> _downloadStepArchive({
    required String url,
    required String destinationPath,
    required void Function(SetupState) onProgress,
    required SetupStep step,
    required double startProgress,
    required double endProgress,
    required String idleMessage,
    required String Function(
      String currentMb,
      String totalMb,
      String details,
    ) detailBuilder,
  }) async {
    _emitProgress(
      onProgress: onProgress,
      step: step,
      progress: startProgress,
      message: idleMessage,
    );

    final tracker = _TransferProgressTracker();
    await _dio.download(
      url,
      destinationPath,
      onReceiveProgress: (received, total) {
        if (total <= 0) {
          return;
        }
        final downloadRatio = received / total;
        final progress =
            startProgress + ((endProgress - startProgress) * downloadRatio);
        final currentMb = (received / 1024 / 1024).toStringAsFixed(1);
        final totalMb = (total / 1024 / 1024).toStringAsFixed(1);
        final details = tracker.describe(received, total);
        _emitProgress(
          onProgress: onProgress,
          step: step,
          progress: progress,
          message: idleMessage,
          detail: detailBuilder(currentMb, totalMb, details),
        );
      },
    );
  }

  Future<String> _selectUbuntuMirror(String arch) async {
    final candidates = AppConstants.ubuntuMirrorCandidates(arch);
    const releasePath = '/dists/${AppConstants.ubuntuCodename}/Release';
    final checks = candidates.map((baseUrl) async {
      final stopwatch = Stopwatch()..start();
      try {
        final response = await _dio.get<String>(
          '$baseUrl$releasePath',
          options: Options(
            responseType: ResponseType.plain,
            sendTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );
        if ((response.statusCode ?? 500) >= 200 &&
            (response.statusCode ?? 500) < 300) {
          return _MirrorProbeResult(baseUrl, stopwatch.elapsedMilliseconds);
        }
      } catch (_) {}
      return null;
    });

    final results = (await Future.wait(checks))
        .whereType<_MirrorProbeResult>()
        .toList()
      ..sort((a, b) => a.elapsedMs.compareTo(b.elapsedMs));

    if (results.isNotEmpty) {
      return results.first.baseUrl;
    }
    return candidates.first;
  }

  Future<void> _configureUbuntuMirror(String arch) async {
    final selectedMirror = await _selectUbuntuMirror(arch);
    await NativeBridge.writeRootfsFile(
      'etc/apt/sources.list',
      AppConstants.buildUbuntuSourcesList(selectedMirror),
    );
  }

  bool _rootfsReady(Map<String, dynamic> status) =>
      _statusFlag(status, 'rootfsExists') &&
      _statusFlag(status, 'binBashExists');

  bool _basePackagesReady(Map<String, dynamic> status) =>
      _statusFlag(status, 'basePackagesInstalled');

  Future<void> _extractRootfsWithProgress({
    required void Function(SetupState) onProgress,
    required String tarPath,
  }) async {
    await _runEstimatedProgress(
      onProgress: onProgress,
      step: SetupStep.extractingRootfs,
      startProgress: 0.02,
      targetProgress: 0.92,
      message: 'Extracting rootfs (this takes a while)...',
      estimatedDuration: const Duration(minutes: 2),
      task: () => NativeBridge.extractRootfs(tarPath),
    );
  }

  void _emitProgress({
    required void Function(SetupState) onProgress,
    required SetupStep step,
    required double progress,
    required String message,
    String? detail,
    bool preserveDetail = false,
    String? notificationText,
    bool updateNotification = true,
  }) {
    final clampedProgress = _clampProgress(progress);
    final nextDetail = preserveDetail ? _lastSetupState.detail : detail;
    _lastSetupState = SetupState(
      step: step,
      progress: clampedProgress,
      message: message,
      detail: nextDetail,
    );
    onProgress(_lastSetupState);
    if (!updateNotification) {
      return;
    }
    final overallProgress = _overallProgressFor(step, clampedProgress);
    final localizedMessage =
        InstallStatusMessageFormatter.localize(_notificationL10n, message);
    _updateSetupNotification(
      '$localizedMessage ${_formatPercent(overallProgress)}',
      progress: (overallProgress * 100).round(),
    );
  }

  Future<T> _runEstimatedProgress<T>({
    required void Function(SetupState) onProgress,
    required SetupStep step,
    required double startProgress,
    required double targetProgress,
    required String message,
    required Future<T> Function() task,
    required Duration estimatedDuration,
    String? detail,
    Duration tick = const Duration(milliseconds: 800),
  }) async {
    _emitProgress(
      onProgress: onProgress,
      step: step,
      progress: startProgress,
      message: message,
      detail: detail,
    );

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
      final easedRatio =
          (1 - math.exp(-2.2 * elapsedFactor)).clamp(0.0, 1.0).toDouble();
      final currentProgress =
          startProgress + ((targetProgress - startProgress) * easedRatio);

      if ((currentProgress - lastProgress).abs() < 0.003) {
        continue;
      }
      lastProgress = currentProgress;
      final overallProgress = _overallProgressFor(step, currentProgress);
      _emitProgress(
        onProgress: onProgress,
        step: step,
        progress: currentProgress,
        message: message,
        preserveDetail: true,
        notificationText: '$message ${_formatPercent(overallProgress)}',
      );
    }

    return await future;
  }

  Future<SetupState> checkStatus() async {
    try {
      final complete = await NativeBridge.isBootstrapComplete();
      if (complete) {
        return const SetupState(
          step: SetupStep.complete,
          progress: 1.0,
          message: 'Setup complete',
        );
      }
      return const SetupState(
        step: SetupStep.checkingStatus,
        progress: 0.0,
        message: 'Setup required',
      );
    } catch (e) {
      return SetupState(
        step: SetupStep.error,
        error: 'Failed to check status: $e',
      );
    }
  }

  Future<void> runFullSetup({
    required void Function(SetupState) onProgress,
    String? selectedHermesVersion,
    HermesInstallOptions installOptions = const HermesInstallOptions(),
  }) async {
    _lastSetupState = const SetupState();
    final logSubscription = NativeBridge.setupLogStream.listen((line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || _lastSetupState.message.isEmpty) {
        return;
      }
      _emitProgress(
        onProgress: onProgress,
        step: _lastSetupState.step,
        progress: _lastSetupState.progress,
        message: _lastSetupState.message,
        detail: trimmed,
        updateNotification: false,
      );
    });

    try {
      // Start foreground service to keep app alive during setup
      try {
        await NativeBridge.startSetupService();
      } catch (_) {} // Non-fatal if service fails to start

      // Step 0: Setup directories
      _emitProgress(
        onProgress: onProgress,
        step: SetupStep.checkingStatus,
        progress: 0.4,
        message: 'Setting up directories...',
        notificationText: 'Setting up directories... 2.0%',
      );
      try {
        await NativeBridge.setupDirs();
      } catch (_) {}
      try {
        await NativeBridge.writeResolv();
      } catch (_) {}

      // Step 1: Download rootfs
      final arch = await NativeBridge.getArch();
      final rootfsUrl = AppConstants.getRootfsUrl(arch);
      final filesDir = await NativeBridge.getFilesDir();

      // Direct Dart fallback: ensure config dir + resolv.conf exist (#40).
      const resolvContent =
          'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n';
      try {
        final configDir = '$filesDir/config';
        final resolvFile = File('$configDir/resolv.conf');
        if (!resolvFile.existsSync()) {
          Directory(configDir).createSync(recursive: true);
          resolvFile.writeAsStringSync(resolvContent);
        }
        // Also write into rootfs /etc/ so DNS works even if bind-mount fails
        final rootfsResolv = File('$filesDir/rootfs/ubuntu/etc/resolv.conf');
        if (!rootfsResolv.existsSync()) {
          rootfsResolv.parent.createSync(recursive: true);
          rootfsResolv.writeAsStringSync(resolvContent);
        }
      } catch (_) {}
      var bootstrapStatus = await NativeBridge.getBootstrapStatus();
      final rootfsReady = _rootfsReady(bootstrapStatus);
      final tarPath = '$filesDir/tmp/ubuntu-rootfs.tar.gz';
      final rootfsAssetPath =
          AppConstants.bundledBootstrapAssetPathForUrl(rootfsUrl);
      final prebuiltTarPath = '$filesDir/tmp/hermes-prebuilt-rootfs.tar.gz';
      final prebuiltRootfsAssetPath =
          AppConstants.prebuiltRootfsAssetPathForArch(arch);

      if (rootfsReady) {
        _emitProgress(
          onProgress: onProgress,
          step: SetupStep.extractingRootfs,
          progress: 1.0,
          message: 'Ubuntu rootfs already available',
          detail: 'Reusing previously extracted rootfs.',
          notificationText: 'Ubuntu rootfs ready 45.0%',
        );
      } else {
        var extractedPrebuiltRootfs = false;
        try {
          var prebuiltSource = _PreparedArchiveSource.none;
          final customPrebuiltPath =
              installOptions.normalizedPrebuiltRootfsArchivePath;
          final customPrebuiltUrl = installOptions.normalizedPrebuiltRootfsUrl;

          if (customPrebuiltPath != null) {
            prebuiltSource = await _prepareLocalArchive(
              sourcePath: customPrebuiltPath,
              destinationPath: prebuiltTarPath,
            );
          } else if (customPrebuiltUrl != null) {
            _deleteArchiveIfExists(prebuiltTarPath);
            await _downloadStepArchive(
              url: customPrebuiltUrl,
              destinationPath: prebuiltTarPath,
              onProgress: onProgress,
              step: SetupStep.downloadingRootfs,
              startProgress: 0.0,
              endProgress: 1.0,
              idleMessage: 'Downloading external prebuilt Ubuntu rootfs...',
              detailBuilder: (currentMb, totalMb, details) =>
                  '$currentMb MB / $totalMb MB | $details',
            );
            prebuiltSource = File(prebuiltTarPath).existsSync()
                ? _PreparedArchiveSource.externalUrl
                : _PreparedArchiveSource.none;
          } else {
            prebuiltSource = await _prepareBundledOrCachedArchive(
              assetPath: prebuiltRootfsAssetPath,
              destinationPath: prebuiltTarPath,
            );
          }

          if (prebuiltSource != _PreparedArchiveSource.none) {
            switch (prebuiltSource) {
              case _PreparedArchiveSource.bundled:
                _emitProgress(
                  onProgress: onProgress,
                  step: SetupStep.downloadingRootfs,
                  progress: 1.0,
                  message: 'Using bundled prebuilt Ubuntu rootfs package...',
                  detail: 'Using packaged prebuilt Ubuntu rootfs archive.',
                  notificationText:
                      'Using bundled prebuilt Ubuntu rootfs package... 30.0%',
                );
                break;
              case _PreparedArchiveSource.cached:
                _emitProgress(
                  onProgress: onProgress,
                  step: SetupStep.downloadingRootfs,
                  progress: 1.0,
                  message: 'Using cached prebuilt Ubuntu rootfs package...',
                  detail: 'Reusing local prebuilt Ubuntu rootfs archive cache.',
                  notificationText:
                      'Using cached prebuilt Ubuntu rootfs package... 30.0%',
                );
                break;
              case _PreparedArchiveSource.localFile:
                _emitProgress(
                  onProgress: onProgress,
                  step: SetupStep.downloadingRootfs,
                  progress: 1.0,
                  message: 'Using selected prebuilt Ubuntu rootfs package...',
                  detail: 'Using the archive selected from local storage.',
                  notificationText:
                      'Using selected prebuilt Ubuntu rootfs package... 30.0%',
                );
                break;
              case _PreparedArchiveSource.externalUrl:
                _emitProgress(
                  onProgress: onProgress,
                  step: SetupStep.downloadingRootfs,
                  progress: 1.0,
                  message: 'Using downloaded prebuilt Ubuntu rootfs package...',
                  detail: 'Using the archive downloaded from the custom URL.',
                  notificationText:
                      'Using downloaded prebuilt Ubuntu rootfs package... 30.0%',
                );
                break;
              case _PreparedArchiveSource.none:
                break;
            }

            await _extractRootfsWithProgress(
              onProgress: onProgress,
              tarPath: prebuiltTarPath,
            );
            bootstrapStatus = await NativeBridge.getBootstrapStatus();
            if (!_rootfsReady(bootstrapStatus) ||
                !_basePackagesReady(bootstrapStatus)) {
              throw StateError(
                'Prebuilt rootfs is missing required base packages.',
              );
            }
            extractedPrebuiltRootfs = true;
          }
        } catch (error) {
          _deleteArchiveIfExists(prebuiltTarPath);
          _emitProgress(
            onProgress: onProgress,
            step: SetupStep.downloadingRootfs,
            progress: 1.0,
            message:
                'Prebuilt rootfs failed, falling back to standard Ubuntu rootfs...',
            detail: error.toString(),
            notificationText:
                'Prebuilt rootfs failed, using standard Ubuntu rootfs... 30.0%',
          );
        }

        if (!extractedPrebuiltRootfs) {
          var rootfsSource = _PreparedArchiveSource.none;
          final customRootfsPath =
              installOptions.normalizedUbuntuRootfsArchivePath;
          final customRootfsUrl = installOptions.normalizedUbuntuRootfsUrl;

          if (customRootfsPath != null) {
            rootfsSource = await _prepareLocalArchive(
              sourcePath: customRootfsPath,
              destinationPath: tarPath,
            );
          } else if (customRootfsUrl != null) {
            _deleteArchiveIfExists(tarPath);
            await _downloadStepArchive(
              url: customRootfsUrl,
              destinationPath: tarPath,
              onProgress: onProgress,
              step: SetupStep.downloadingRootfs,
              startProgress: 0.0,
              endProgress: 1.0,
              idleMessage: 'Downloading selected Ubuntu rootfs...',
              detailBuilder: (currentMb, totalMb, details) =>
                  '$currentMb MB / $totalMb MB | $details',
            );
            rootfsSource = File(tarPath).existsSync()
                ? _PreparedArchiveSource.externalUrl
                : _PreparedArchiveSource.none;
          } else {
            rootfsSource = await _prepareBundledOrCachedArchive(
              assetPath: rootfsAssetPath,
              destinationPath: tarPath,
            );
          }

          final rootfsFromLocal = rootfsSource != _PreparedArchiveSource.none;
          if (rootfsSource == _PreparedArchiveSource.bundled) {
            _emitProgress(
              onProgress: onProgress,
              step: SetupStep.downloadingRootfs,
              progress: 1.0,
              message: 'Using bundled Ubuntu rootfs package...',
              detail: 'Using packaged Ubuntu rootfs archive.',
              notificationText: 'Using bundled Ubuntu rootfs package... 30.0%',
            );
          } else if (rootfsSource == _PreparedArchiveSource.cached) {
            _emitProgress(
              onProgress: onProgress,
              step: SetupStep.downloadingRootfs,
              progress: 1.0,
              message: 'Using cached Ubuntu rootfs package...',
              detail: 'Reusing local Ubuntu rootfs archive cache.',
              notificationText: 'Using cached Ubuntu rootfs package... 30.0%',
            );
          } else if (rootfsSource == _PreparedArchiveSource.localFile) {
            _emitProgress(
              onProgress: onProgress,
              step: SetupStep.downloadingRootfs,
              progress: 1.0,
              message: 'Using selected Ubuntu rootfs package...',
              detail: 'Using the Ubuntu rootfs archive selected from storage.',
              notificationText: 'Using selected Ubuntu rootfs package... 30.0%',
            );
          } else if (rootfsSource == _PreparedArchiveSource.externalUrl) {
            _emitProgress(
              onProgress: onProgress,
              step: SetupStep.downloadingRootfs,
              progress: 1.0,
              message: 'Using downloaded Ubuntu rootfs package...',
              detail: 'Using the Ubuntu rootfs archive downloaded from URL.',
              notificationText:
                  'Using downloaded Ubuntu rootfs package... 30.0%',
            );
          } else {
            await _downloadStepArchive(
              url: rootfsUrl,
              destinationPath: tarPath,
              onProgress: onProgress,
              step: SetupStep.downloadingRootfs,
              startProgress: 0.0,
              endProgress: 1.0,
              idleMessage: 'Downloading Ubuntu rootfs...',
              detailBuilder: (currentMb, totalMb, details) =>
                  '$currentMb MB / $totalMb MB | $details',
            );
          }

          try {
            await _extractRootfsWithProgress(
              onProgress: onProgress,
              tarPath: tarPath,
            );
          } catch (error) {
            if (!rootfsFromLocal) {
              rethrow;
            }
            try {
              File(tarPath).deleteSync();
            } catch (_) {}
            await _downloadStepArchive(
              url: rootfsUrl,
              destinationPath: tarPath,
              onProgress: onProgress,
              step: SetupStep.downloadingRootfs,
              startProgress: 0.0,
              endProgress: 1.0,
              idleMessage: 'Local rootfs cache failed, downloading online...',
              detailBuilder: (currentMb, totalMb, details) =>
                  '$currentMb MB / $totalMb MB | $details',
            );
            await _extractRootfsWithProgress(
              onProgress: onProgress,
              tarPath: tarPath,
            );
          }
        }
        bootstrapStatus = await NativeBridge.getBootstrapStatus();
        _emitProgress(
          onProgress: onProgress,
          step: SetupStep.extractingRootfs,
          progress: 1.0,
          message: 'Rootfs extracted',
          notificationText: 'Rootfs extracted 45.0%',
        );
      }
      bootstrapStatus = await NativeBridge.getBootstrapStatus();

      // Step 2.5: Ensure PRoot binary is available
      // If APK doesn't bundle libproot.so, download from Termux repo
      _emitProgress(
        onProgress: onProgress,
        step: SetupStep.extractingRootfs,
        progress: 0.90,
        message: 'Checking PRoot binary...',
        notificationText: 'Checking PRoot binary... 44.0%',
      );
      try {
        await NativeBridge.setupProotFromTermux(arch: arch);
      } catch (e) {
        _emitProgress(
          onProgress: onProgress,
          step: SetupStep.extractingRootfs,
          progress: 0.90,
          message: 'PRoot download failed: $e',
          detail: e.toString(),
        );
        // Non-fatal: proot might already exist from jniLibs
      }

      // Step 3: Install Python (45-80%)
      // ★ Always fix permissions first — install.sh needs bash/chmod/dpkg to be executable.
      _emitProgress(
        onProgress: onProgress,
        step: SetupStep.installingPython,
        progress: 0.02,
        message: 'Fixing rootfs permissions...',
        notificationText: 'Fixing rootfs permissions... 45.7%',
      );
      await NativeBridge.runInProot(
        'chmod -R 755 /usr/bin /usr/sbin /bin /sbin '
        '/usr/local/bin /usr/local/sbin 2>/dev/null; '
        'chmod -R +x /usr/lib/apt/ /usr/lib/dpkg/ /usr/libexec/ '
        '/var/lib/dpkg/info/ /usr/share/debconf/ 2>/dev/null; '
        'chmod 755 /lib/*/ld-linux-*.so* /usr/lib/*/ld-linux-*.so* 2>/dev/null; '
        'mkdir -p /var/lib/dpkg/updates /var/lib/dpkg/triggers; '
        'if [ ! -x /bin/bash ] && [ -f /usr/bin/bash ]; then '
        'mkdir -p /bin; cp /usr/bin/bash /bin/bash; chmod +x /bin/bash; fi; '
        'if [ ! -x /usr/bin/bash ] && [ -f /bin/bash ]; then '
        'cp /bin/bash /usr/bin/bash; chmod +x /usr/bin/bash; fi; '
        'echo permissions_fixed',
      );
      _emitProgress(
        onProgress: onProgress,
        step: SetupStep.installingPython,
        progress: 0.08,
        message: 'Fixing rootfs permissions...',
        notificationText: 'Fixing rootfs permissions... 47.8%',
      );

      final pythonReady = await _isInstalledPythonUsable();

      if (pythonReady) {
        _emitProgress(
          onProgress: onProgress,
          step: SetupStep.installingPython,
          progress: 1.0,
          message: 'Python already installed',
          detail: 'Reusing existing Python runtime.',
          notificationText: 'Python installed 80.0%',
        );
      } else {

        bootstrapStatus = await NativeBridge.getBootstrapStatus();
        if (_basePackagesReady(bootstrapStatus)) {
          _emitProgress(
            onProgress: onProgress,
            step: SetupStep.installingPython,
            progress: 0.42,
            message: 'Base packages already available',
            detail: 'Skipping apt-get update/install for prebuilt rootfs.',
            notificationText: 'Base packages ready 59.7%',
          );
        } else {
          await _configureUbuntuMirror(arch);

          await _runEstimatedProgress(
            onProgress: onProgress,
            step: SetupStep.installingPython,
            startProgress: 0.10,
            targetProgress: 0.18,
            message: 'Updating package lists...',
            detail: 'Running apt-get update...',
            estimatedDuration: const Duration(seconds: 25),
            task: () => NativeBridge.runInProot('apt-get update -y'),
          );

          _emitProgress(
            onProgress: onProgress,
            step: SetupStep.installingPython,
            progress: 0.20,
            message: 'Installing base packages...',
            notificationText: 'Installing base packages... 52.0%',
          );
          // Pre-configure tzdata to avoid interactive continent/timezone prompt
          await NativeBridge.runInProot(
            'ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime && '
            'echo "Etc/UTC" > /etc/timezone',
          );
          // Install basic packages needed by Hermes Agent (git, curl, python3, pip).
          // The tarball + pip install approach handles everything else.
          await _runEstimatedProgress(
            onProgress: onProgress,
            step: SetupStep.installingPython,
            startProgress: 0.22,
            targetProgress: 0.42,
            message: 'Installing base packages...',
            detail: 'Running apt-get install for base packages...',
            estimatedDuration: const Duration(minutes: 3),
            task: () => NativeBridge.runInProot(
              'apt-get install -y --no-install-recommends '
              'ca-certificates python3 python3-pip python3-venv git curl wget',
            ),
          );
          bootstrapStatus = await NativeBridge.getBootstrapStatus();
        }

        // --- Install Python 3 + pip ---
        await _runEstimatedProgress(
          onProgress: onProgress,
          step: SetupStep.installingPython,
          startProgress: 0.45,
          targetProgress: 0.80,
          message: 'Verifying Python installation...',
          detail: 'Checking python3 and pip3...',
          estimatedDuration: const Duration(seconds: 15),
          task: () => NativeBridge.runInProot(
            'python3 --version && pip3 --version',
            timeout: 30,
          ),
        );

        _emitProgress(
          onProgress: onProgress,
          step: SetupStep.installingPython,
          progress: 0.96,
          message: 'Verifying Python...',
          notificationText: 'Verifying Python... 78.6%',
        );
        await NativeBridge.runInProot('python3 --version', timeout: 30);
        _emitProgress(
          onProgress: onProgress,
          step: SetupStep.installingPython,
          progress: 1.0,
          message: 'Python installed',
          notificationText: 'Python installed 80.0%',
        );
      }

      bootstrapStatus = await NativeBridge.getBootstrapStatus();

      // Step 3.5: Install Node.js (required by hermes-agent)
      // hermes-agent install.sh checks for NODE_VERSION="22".
      final nodejsUrl = installOptions.nodejsSetupUrl?.trim() ??
          AppConstants.nodejsSetupUrl;

      // pip method: we must install Node.js ourselves
      final nodeReady = await NativeBridge.runInProot(
        'command -v node >/dev/null 2>&1 && node --version || echo NOT_FOUND',
        timeout: 15,
      ).then((v) => !v.contains('NOT_FOUND')).catchError((_) => false);

      if (nodeReady) {
        _emitProgress(
          onProgress: onProgress,
          step: SetupStep.installingPython,
          progress: 0.98,
          message: 'Node.js already installed',
          detail: 'Reusing existing Node.js runtime.',
          notificationText: 'Node.js ready 79.5%',
        );
      } else {
        // Use NodeSource to get Node.js 22 (apt only has Node.js 18 on Ubuntu 24.04)
        await _runEstimatedProgress(
          onProgress: onProgress,
          step: SetupStep.installingPython,
          startProgress: 0.88,
          targetProgress: 0.95,
          message: 'Installing Node.js 22...',
          detail: 'Setting up NodeSource repository...',
          estimatedDuration: const Duration(minutes: 2),
          task: () => NativeBridge.runInProot(
            'curl -fsSL $nodejsUrl | bash - 2>&1 && '
            'apt-get install -y nodejs 2>&1 && '
            'echo NODE_INSTALL_OK || echo NODE_INSTALL_FAIL',
            timeout: 300,
          ),
        );
        // Verify Node.js is usable
        final nodeVersion = await NativeBridge.runInProot(
          'node --version 2>/dev/null || echo NOT_FOUND',
          timeout: 15,
        ).catchError((_) => 'NOT_FOUND');
        if (nodeVersion.contains('NOT_FOUND')) {
          _emitProgress(
            onProgress: onProgress,
            step: SetupStep.installingPython,
            progress: 0.98,
            message: 'Node.js installation skipped (non-fatal)',
            detail: 'Node.js could not be installed; hermes tools may be limited.',
            notificationText: 'Node.js skipped 79.5%',
          );
        } else {
          _emitProgress(
            onProgress: onProgress,
            step: SetupStep.installingPython,
            progress: 1.0,
            message: 'Node.js installed ($nodeVersion)',
            notificationText: 'Node.js installed 79.5%',
          );
        }
      }

      // Step 4: Install Hermes Agent (80-98%)
      final androidApiLevel = await NativeBridge.runInProot(
        'getprop ro.build.version.sdk 2>/dev/null || echo 28',
        timeout: 10,
      ).then((v) => v.trim()).catchError((_) => '28');

      // Ensure PATH includes hermes locations before version check
      await NativeBridge.runInProot(
        'export PATH="$_venvPath/bin:\$HOME/.local/bin:/usr/local/bin:\$PATH" && hash -r',
        timeout: 10,
      );
      final installedHermesVersion =
          await _hermesVersionService.readInstalledVersion();
      final targetVersion = selectedHermesVersion?.trim();
      final hermesReady = installedHermesVersion != null &&
          (targetVersion == null ||
              targetVersion.isEmpty ||
              HermesVersionService.isSameVersion(
                installedVersion: installedHermesVersion,
                targetVersion: targetVersion,
              )) &&
          await _isInstalledHermesUsable();

      if (hermesReady) {
        _emitProgress(
          onProgress: onProgress,
          step: SetupStep.installingHermes,
          progress: 1.0,
          message: 'Hermes Agent already installed',
          detail: 'Reusing Hermes Agent $installedHermesVersion.',
        );
      } else {
        // ── PyPI wheel install ──
        await _hermesVersionService.installVersion(
          selectedHermesVersion ?? 'latest',
          captureLiveLogs: false,
          pipIndexUrl: installOptions.pipIndexUrl,
          onProgress: (installProgress) {
            final detail = installProgress.detail?.trim();
            _emitProgress(
              onProgress: onProgress,
              step: SetupStep.installingHermes,
              progress: installProgress.progress,
              message: installProgress.message,
              detail: detail?.isEmpty == true ? null : detail,
              preserveDetail: detail == null || detail.isEmpty,
            );
          },
        );
      }

      // Step 4.5: Ensure aiohttp is installed in venv (hermes dependency)
      try {
        await NativeBridge.runInProot(
          '"$_venvPath/bin/python" -c "import aiohttp" 2>/dev/null || '
          '"$_venvPath/bin/python" -m pip install aiohttp 2>&1',
          timeout: 120,
        );
      } catch (_) {
        // Non-fatal: hermes may still work without aiohttp
      }

      // Step 5: Configure PRoot environment (98-100%)
      _emitProgress(
        onProgress: onProgress,
        step: SetupStep.configuringEnvironment,
        progress: 0.0,
        message: '正在配置环境变量...',
        notificationText: '正在配置环境变量... 98.0%',
      );
      try {
        await NativeBridge.installBionicBypass();
      } catch (_) {
        // Non-fatal
      }

      // ★ Write a minimal config.yaml to ensure `hermes gateway` listens on
      // port 8642 (matching AppConstants.gatewayPort).
      _emitProgress(
        onProgress: onProgress,
        step: SetupStep.configuringEnvironment,
        progress: 0.5,
        message: 'Writing gateway configuration...',
        notificationText: 'Writing gateway configuration... 99.0%',
      );
      try {
        await NativeBridge.runInProot(
          'mkdir -p /root/.hermes && '
          'if [ ! -f /root/.hermes/config.yaml ]; then\n'
          '  cat > /root/.hermes/config.yaml << \'GATEWAY_CONFIG\'\n'
          'gateway:\n'
          '  port: ${AppConstants.gatewayPort}\n'
          '  bind: loopback\n'
          '  controlUi:\n'
          '    allowInsecureAuth: true\n'
          'GATEWAY_CONFIG\n'
          '  echo "config.yaml created with gateway port ${AppConstants.gatewayPort}"\n'
          'else\n'
          '  echo "config.yaml already exists, skipping"\n'
          'fi',
          timeout: 15,
        );
      } catch (_) {
        // Non-fatal: user can create config manually
      }

      // ★ Create a .env file with default settings so gateway auth token
      // resolution works and the API server is enabled out of the box.
      // hermes setup (interactive) normally creates this, but our automated
      // install skips the setup wizard. Without .env, GatewayAuthConfigService
      // cannot resolve ${ENV_VAR} references in config.yaml.
      try {
        await NativeBridge.runInProot(
          'mkdir -p /root/.hermes && '
          'if [ ! -f /root/.hermes/.env ]; then '
          '  cat > /root/.hermes/.env << \'ENV_DEFAULTS\'\n'
          '# Hermes Agent environment configuration\n'
          '# Created by Hermes Agent Android installer\n'
          '# Add your API keys here or use: hermes setup\n'
          'GATEWAY_ALLOW_ALL_USERS=true\n'
          'API_SERVER_ENABLED=true\n'
          'API_SERVER_KEY=${_generateSecureApiKey()}\n'
          'API_SERVER_PORT=8642\n'
          'API_SERVER_HOST=127.0.0.1\n'
          'ENV_DEFAULTS\n'
          '  echo ".env file created with defaults"; '
          'else '
          '  echo ".env already exists, skipping"; '
          'fi',
          timeout: 15,
        );
      } catch (_) {
        // Non-fatal: user can create .env manually
      }

      // Step 6: Environment configured
      // Note: Node.js and hermes-web-ui are NOT installed automatically.
      // Users can install them manually in the terminal if needed:
      //   apt install nodejs npm && npm install -g hermes-web-ui

      _emitProgress(
        onProgress: onProgress,
        step: SetupStep.configuringEnvironment,
        progress: 1.0,
        message: '环境变量已配置',
        notificationText: '环境变量已配置 100.0%',
      );

      // Done
      _stopSetupService();
      _emitProgress(
        onProgress: onProgress,
        step: SetupStep.complete,
        progress: 1.0,
        message: 'Setup complete! Ready to start the gateway.',
        notificationText: 'Setup complete! 100.0%',
      );
    } on DioException catch (e) {
      _stopSetupService();
      onProgress(SetupState(
        step: SetupStep.error,
        error: 'Download failed: ${e.message}',
        detail: 'Check your internet connection.\n${e.response?.statusCode ?? ""}',
      ));
    } catch (e) {
      _stopSetupService();
      // Extract detail from exception message (may contain terminal output)
      final errorStr = e.toString();
      final detailIndex = errorStr.indexOf('\n');
      onProgress(SetupState(
        step: SetupStep.error,
        error: detailIndex > 0 ? errorStr.substring(0, detailIndex) : errorStr,
        detail: detailIndex > 0 ? errorStr.substring(detailIndex + 1) : null,
      ));
    } finally {
      await logSubscription.cancel();
    }
  }
}
