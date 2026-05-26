import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';

import '../constants.dart';
import '../l10n/app_localizations.dart';
import '../models/hermes_install_options.dart';
import '../models/setup_state.dart';
import '../services/native_bridge.dart';
import '../services/terminal_service.dart';
import '../widgets/progress_step.dart';
import 'dashboard_screen.dart';

/// Screen that runs the Hermes Agent install.sh via curl | bash in a real PTY
/// terminal, with a progress sidebar showing bootstrap steps (rootfs, Python).
///
/// After rootfs + Python are ready, the screen opens a terminal and runs:
///   curl -fsSL <proxied-install-url> | bash
///
/// The user sees live output and can interact with any prompts.
class TerminalInstallScreen extends StatefulWidget {
  final HermesInstallOptions installOptions;
  final String? selectedHermesVersion;

  const TerminalInstallScreen({
    super.key,
    required this.installOptions,
    this.selectedHermesVersion,
  });

  @override
  State<TerminalInstallScreen> createState() => _TerminalInstallScreenState();
}

class _TerminalInstallScreenState extends State<TerminalInstallScreen> {
  // Bootstrap progress tracking (rootfs + Python)
  SetupState _bootstrapState = const SetupState();
  bool _bootstrapRunning = false;
  bool _bootstrapDone = false;
  String? _bootstrapError;

  // Terminal state
  Pty? _pty;
  bool _terminalStarted = false;
  bool _installDone = false;
  bool _installFailed = false;
  int _exitCode = -1;
  final _outputBuffer = StringBuffer();
  final _scrollController = ScrollController();

  // Completion detection patterns
  static final _successPattern = RegExp(
    r'install(ation)?\s+(complete|successful|finished|done)|'
    r'setup\s+(complete|successful|finished|done)|'
    r'hermes\s+(is\s+)?(now\s+)?(installed|ready)|'
    r'INSTALL_SH_OK|'
    r'Successfully installed',
    caseSensitive: false,
  );
  static final _failPattern = RegExp(
    r'INSTALL_SH_FAIL|error|failed|fatal|exception',
    caseSensitive: false,
  );

  @override
  void initState() {
    super.initState();
    _runBootstrap();
  }

  @override
  void dispose() {
    _pty?.kill();
    _scrollController.dispose();
    super.dispose();
  }

  // ── Bootstrap: rootfs + Python (steps 1-3 from bootstrap_service) ──

  Future<void> _runBootstrap() async {
    setState(() {
      _bootstrapRunning = true;
      _bootstrapError = null;
    });

    try {
      // Step 0: Setup directories
      _emitBootstrap(SetupStep.checkingStatus, 0.4, 'Setting up directories...');
      try { await NativeBridge.setupDirs(); } catch (_) {}
      try { await NativeBridge.writeResolv(); } catch (_) {}

      // Step 1: Check/download rootfs
      final status = await NativeBridge.getBootstrapStatus();
      final rootfsReady = status['rootfsExists'] == true &&
          status['binBashExists'] == true;

      if (rootfsReady) {
        _emitBootstrap(SetupStep.extractingRootfs, 1.0, 'Ubuntu rootfs already available');
      } else {
        _emitBootstrap(SetupStep.downloadingRootfs, 0.5, 'Downloading Ubuntu rootfs...');
        final arch = await NativeBridge.getArch();
        final filesDir = await NativeBridge.getFilesDir();
        final rootfsUrl = AppConstants.getRootfsUrl(arch);
        final tarPath = '$filesDir/tmp/ubuntu-rootfs.tar.gz';

        // ★ Download via Dart HttpClient (NOT proot curl).
        //    gh-proxy.com only proxies github.com, NOT cdimage.ubuntu.com.
        //    Use Chinese Ubuntu mirrors first, then official CDN.
        final urls = <String>[
          if (arch == 'aarch64' || arch == 'arm64') ...[
            'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-arm64.tar.gz',
            'https://mirrors.aliyun.com/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-arm64.tar.gz',
          ] else if (arch == 'arm' || arch == 'armv7l') ...[
            'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-armhf.tar.gz',
            'https://mirrors.aliyun.com/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-armhf.tar.gz',
          ] else ...[
            'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz',
            'https://mirrors.aliyun.com/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-amd64.tar.gz',
          ],
          rootfsUrl,
        ];
        bool downloadOk = false;
        for (final url in urls) {
          try {
            final host = Uri.parse(url).host;
            _emitBootstrap(SetupStep.downloadingRootfs, 0.3, 'Downloading from $host...');
            downloadOk = await _downloadFile(url, tarPath);
            if (downloadOk) { _emitBootstrap(SetupStep.downloadingRootfs, 1.0, 'Downloaded from $host'); break; }
          } catch (e) { debugPrint('Download failed: $e'); }
        }
        if (!downloadOk) throw Exception('Failed to download Ubuntu rootfs.');

        _emitBootstrap(SetupStep.extractingRootfs, 0.3, 'Extracting rootfs...');
        await NativeBridge.extractRootfs(tarPath);
        _emitBootstrap(SetupStep.extractingRootfs, 1.0, 'Rootfs extracted');
      }

      // Step 2: Configure mirrors + ensure Python
      //   - Write Chinese mirrors so install.sh uses fast sources
      //   - Skip Python install here — install.sh does it (avoids apt lock conflict)
      _emitBootstrap(SetupStep.installingPython, 0.5, 'Configuring apt mirrors...');
      try {
        final arch2 = await NativeBridge.getArch();
        final isPorts = (arch2 == 'aarch64' || arch2 == 'arm64' || arch2 == 'arm' || arch2 == 'armv7l');
        final mirror = isPorts
            ? 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports'
            : 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu';
        final sourcesList = [
          'deb $mirror noble main restricted universe multiverse',
          'deb $mirror noble-updates main restricted universe multiverse',
          'deb $mirror noble-backports main restricted universe multiverse',
          'deb $mirror noble-security main restricted universe multiverse',
        ].join('\n');
        await NativeBridge.runInProot(
          "cat > /etc/apt/sources.list << 'EOF'\n$sourcesList\nEOF",
          timeout: 10,
        );
      } catch (_) {}

      // Kill any stale apt-get/dpkg from bootstrap + clean locks
      try {
        await NativeBridge.runInProot(
          'killall apt-get dpkg 2>/dev/null; sleep 1; '
          'rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock; '
          'dpkg --configure -a 2>/dev/null',
          timeout: 15,
        );
      } catch (_) {}

      // Step 2.5: Download official NousResearch install.sh into PRoot.
      _emitBootstrap(SetupStep.installingPython, 0.6, 'Downloading install.sh...');
      final proxyPrefix = AppConstants.terminalInstallProxyPrefix;
      final scriptUrl = AppConstants.hermesInstallScriptUrl;
      final proxiedUrl = '$proxyPrefix$scriptUrl';
      final filesDir = await NativeBridge.getFilesDir();
      final hostScriptPath = '$filesDir/rootfs/ubuntu/tmp/install.sh';
      try {
        Directory('$filesDir/rootfs/ubuntu/tmp').createSync(recursive: true);
      } catch (_) {}
      bool scriptReady = false;
      try {
        scriptReady = await _downloadFile(proxiedUrl, hostScriptPath);
      } catch (_) {}
      if (!scriptReady) {
        try {
          scriptReady = await _downloadFile(scriptUrl, hostScriptPath);
        } catch (_) {}
      }
      _emitBootstrap(SetupStep.installingPython, 0.7,
          scriptReady ? 'install.sh downloaded' : 'Download failed, will try curl in PRoot');

      // Step 2.6: Install essential packages (xz, git, ca-certificates).
      // install.sh needs xz to extract Node.js .tar.xz, git to clone repos.
      _emitBootstrap(SetupStep.installingPython, 0.75, 'Installing essential packages (curl, xz, git)...');
      try {
        await NativeBridge.runInProot(
          'apt-get update -y 2>/dev/null && '
          'apt-get install -y --no-install-recommends curl xz-utils git ca-certificates 2>/dev/null && '
          'echo essential_packages_ok || echo essential_packages_skip',
          timeout: 180,
        );
      } catch (_) {}

      // Quick Python check (don't install — install.sh handles it)
      bool pythonOk = false;
      try {
        await NativeBridge.runInProot('python3 --version', timeout: 30);
        pythonOk = true;
      } catch (_) {}
      _emitBootstrap(SetupStep.installingPython, 1.0,
          pythonOk ? 'Python already available' : 'Python will be installed by install.sh');

      // Step 3: Ensure PRoot binary
      try {
        final arch = await NativeBridge.getArch();
        await NativeBridge.setupProotFromTermux(arch: arch);
      } catch (_) {}

      // Step 4: Fix rootfs permissions and verify bash.
      // Java tar extraction may lose execute bits; merged /usr symlinks may be missing.
      // These must be fixed BEFORE install.sh runs, otherwise bash -c fails.
      _emitBootstrap(SetupStep.installingPython, 0.95, 'Fixing rootfs permissions...');
      try {
        await NativeBridge.runInProot(
          'chmod -R 755 /usr/bin /usr/sbin /bin /sbin /usr/local/bin 2>/dev/null; '
          'chmod -R +x /usr/lib/apt/ /usr/lib/dpkg/ /var/lib/dpkg/info/ 2>/dev/null; '
          'if [ ! -x /bin/bash ] && [ -f /usr/bin/bash ]; then '
          'mkdir -p /bin; cp /usr/bin/bash /bin/bash; chmod +x /bin/bash; fi; '
          'if [ ! -x /usr/bin/bash ] && [ -f /bin/bash ]; then '
          'cp /bin/bash /usr/bin/bash; chmod +x /usr/bin/bash; fi; '
          'echo bash_fix_done',
          timeout: 15,
        );
      } catch (_) {}

      // Bootstrap done — now start terminal install
      setState(() {
        _bootstrapRunning = false;
        _bootstrapDone = true;
      });
      _startTerminalInstall();
    } catch (e) {
      setState(() {
        _bootstrapRunning = false;
        _bootstrapError = '$e';
        _bootstrapState = SetupState(
          step: SetupStep.error,
          error: 'Bootstrap failed: $e',
        );
      });
    }
  }

  void _emitBootstrap(SetupStep step, double progress, String message) {
    setState(() {
      _bootstrapState = SetupState(
        step: step,
        progress: progress,
        message: message,
      );
    });
  }


  Future<bool> _downloadFile(String url, String savePath,
      {Duration timeout = const Duration(minutes: 5)}) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    client.idleTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) { debugPrint('HTTP \${response.statusCode} from \$url'); return false; }
      final file = File(savePath);
      file.parent?.createSync(recursive: true);
      final sink = file.openWrite();
      await response.timeout(timeout).pipe(sink);
      await sink.flush();
      await sink.close();
      return file.existsSync() && file.lengthSync() > 512;
    } catch (e) { debugPrint('Download error: \$e'); return false; }
    finally { client.close(); }
  }
  // ── Terminal install: curl | bash ──

  Future<void> _startTerminalInstall() async {
    if (_terminalStarted) return;
    setState(() {
      _terminalStarted = true;
      _installDone = false;
      _installFailed = false;
      _outputBuffer.clear();
    });

    try {
      final config = await TerminalService.getProotShellConfig();
      final args = TerminalService.buildProotArgs(
        config,
        columns: 120,
        rows: 40,
        mode: TerminalProotMode.fast,
      );

      // Build the install command using official NousResearch install.sh
      final scriptUrl = AppConstants.hermesInstallScriptUrl;
      final proxyPrefix = AppConstants.terminalInstallProxyPrefix;
      final proxiedUrl = '$proxyPrefix$scriptUrl';

      // ★ Do NOT pass --branch with PyPI version numbers.
      // The official install.sh uses `git clone --branch $BRANCH` and
      // `git checkout $BRANCH`, but PyPI versions (0.14.0) don't match
      // git tags (v2026.5.16). Let install.sh use main branch (default),
      // then pin the version via pip after install.sh completes.
      final version = widget.selectedHermesVersion?.trim();
      final needsVersionPin = version != null && version.isNotEmpty && version != 'latest';

      // Use --dir to avoid /usr/local/lib/hermes-agent conflict
      // (configureRootfs() pre-creates that dir, causing "not a git repository" error)
      // --skip-browser: Playwright/Chromium can't install in PRoot
      final venvDir = '/root/.hermes/hermes-agent/venv';
      final installCmd =
          'echo "╔══════════════════════════════════════════════════╗"; '
          'echo "║  Hermes Agent Terminal Installer                 ║"; '
          'echo "╚══════════════════════════════════════════════════╝"; '
          'echo ""; '
          'echo "Cleaning up previous package operations..."; '
          'killall apt-get dpkg 2>/dev/null; sleep 2; '
          'rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null; '
          'dpkg --configure -a 2>/dev/null; '
          'echo ""; '
          'set +e; '
          'if [ -s /tmp/install.sh ]; then '
          '  echo "Using pre-downloaded install.sh"; '
          'else '
          '  echo "Downloading install.sh via curl..."; '
          '  curl -fsSL --connect-timeout 30 --max-time 120 '
          '"$proxiedUrl" -o /tmp/install.sh 2>/dev/null || '
          '  curl -fsSL --connect-timeout 30 --max-time 120 '
          '"$scriptUrl" -o /tmp/install.sh 2>/dev/null; '
          'fi; '
          'if [ ! -s /tmp/install.sh ]; then '
          '  echo "ERROR: install.sh not found!"; '
          '  echo "INSTALL_SH_FAIL"; exit 1; '
          'fi; '
          'bash /tmp/install.sh --skip-browser --dir "\$HOME/.hermes/hermes-agent" 2>/tmp/hermes-stderr.log; '
          'EXIT_CODE=\$?; '
          'grep -v "No module named hermes_cli.__main__" /tmp/hermes-stderr.log >&2; '
          'if [ \$EXIT_CODE -ne 0 ]; then '
          '  echo ""; '
          '  echo "install.sh failed. Falling back to venv + PyPI..."; '
          '  python3 -m venv $venvDir 2>&1; '
          '  "$venvDir/bin/pip" install --upgrade pip setuptools wheel 2>&1; '
          '  "$venvDir/bin/pip" install hermes-agent 2>&1; '
          '  if [ \$? -eq 0 ]; then '
          '    HERMES_PKG=\$("$venvDir/bin/python" -c "import hermes_cli,os;print(os.path.dirname(hermes_cli.__file__))" 2>/dev/null); '
          '    if [ -n "\$HERMES_PKG" ] && [ ! -f "\$HERMES_PKG/__main__.py" ]; then '
          '      echo "from hermes_cli.main import main" > "\$HERMES_PKG/__main__.py"; '
          '      echo "main()" >> "\$HERMES_PKG/__main__.py"; '
          '      echo "Created __main__.py"; fi; '
          '    mkdir -p /usr/local/bin; '
          '    cat > /usr/local/bin/hermes << \'WRAP\'\n'
          '#!/bin/sh\nexport HOME=/root\nVENV="/root/.hermes/hermes-agent/venv"\nif [ -x "\$VENV/bin/python" ]; then exec "\$VENV/bin/python" -m hermes_cli "\$@"; fi\nexec python3 -m hermes_cli "\$@"\n'
          'WRAP\n'
          '    chmod +x /usr/local/bin/hermes; '
          '    EXIT_CODE=0; '
          '    echo "venv + PyPI fallback install succeeded!"; '
          '  fi; '
          'fi; '
          '${needsVersionPin ?
          "if [ \$EXIT_CODE -eq 0 ]; then "
          "echo \"Pinning version to $version via pip...\"; "
          "\"$venvDir/bin/pip\" install \"hermes-agent==$version\" 2>&1; "
          "fi; " : ""}'
          'echo ""; '
          'if [ \$EXIT_CODE -eq 0 ]; then '
          '  echo "══════════════════════════════════════════════════"; '
          '  echo "  ✓ INSTALL_SH_OK — Installation complete!"; '
          '  echo "══════════════════════════════════════════════════"; '
          'else '
          '  echo "══════════════════════════════════════════════════"; '
          '  echo "  ✗ INSTALL_SH_FAIL (exit code: \$EXIT_CODE)"; '
          '  echo "══════════════════════════════════════════════════"; '
          'fi';

      // Replace the login shell args with our install command
      final installArgs = List<String>.from(args);
      installArgs.removeLast(); // remove '-l'
      installArgs.removeLast(); // remove '/bin/bash'
      installArgs.addAll(['/bin/bash', '-c', installCmd]);

      _pty = Pty.start(
        config['executable']!,
        arguments: installArgs,
        environment: TerminalService.buildHostEnv(config),
        columns: 120,
        rows: 40,
      );

      _pty!.output.cast<List<int>>().listen((data) {
        final text = utf8.decode(data, allowMalformed: true);
        _outputBuffer.write(text);
        if (mounted) setState(() {});
        // Auto-scroll to bottom
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });

        // Detect completion
        final cleanText = text.replaceAll(AppConstants.ansiEscape, '');
        if (!_installDone && _successPattern.hasMatch(cleanText)) {
          _installDone = true;
          _installFailed = false;
        }
        if (!_installFailed && cleanText.contains('INSTALL_SH_FAIL')) {
          _installFailed = true;
          _installDone = false;
        }
      });

      _pty!.exitCode.then((code) async {
        _exitCode = code;
        if (mounted) {
          setState(() {
            if (code == 0) {
              _installDone = true;
            } else if (!_installDone) {
              _installFailed = true;
            }
          });
        }
        // After successful install, fix hermes_cli entry point and ensure .env exists
        if (code == 0) {
          try {
            // ★ Critical: ensure hermes_cli.__main__.py exists.
            // Official install.sh may skip this in PRoot environments,
            // causing "No module named hermes_cli.__main__" errors.
            final venvDir = '/root/.hermes/hermes-agent/venv';
            await NativeBridge.runInProot(
              'HERMES_PKG=\$("$venvDir/bin/python" -c "import hermes_cli,os;print(os.path.dirname(hermes_cli.__file__))" 2>/dev/null || '
              'python3 -c "import hermes_cli,os;print(os.path.dirname(hermes_cli.__file__))" 2>/dev/null) && '
              'if [ -n "\$HERMES_PKG" ] && [ ! -f "\$HERMES_PKG/__main__.py" ]; then '
              '  echo "from hermes_cli.main import main" > "\$HERMES_PKG/__main__.py" && '
              '  echo "main()" >> "\$HERMES_PKG/__main__.py" && '
              '  echo "Created __main__.py at \$HERMES_PKG"; fi; '
              'mkdir -p /usr/local/bin && '
              'if [ ! -x /usr/local/bin/hermes ]; then '
              '  cat > /usr/local/bin/hermes << \'WRAPPER\'\n'
              '#!/bin/sh\nexport HOME=/root\nVENV="/root/.hermes/hermes-agent/venv"\nif [ -x "\$VENV/bin/python" ]; then exec "\$VENV/bin/python" -m hermes_cli "\$@"; fi\nexec python3 -m hermes_cli "\$@"\n'
              'WRAPPER\n'
              '  chmod +x /usr/local/bin/hermes && '
              '  echo "Created hermes wrapper"; fi',
              timeout: 15,
            );
            // Also ensure .env exists with default settings
            await NativeBridge.runInProot(
              'mkdir -p /root/.hermes && '
              'if [ ! -f /root/.hermes/.env ]; then '
              '  cat > /root/.hermes/.env << \'ENV_DEFAULTS\'\n'
              '# Hermes Agent environment configuration\n'
              '# Created by Hermes Agent Android installer\n'
              '# Add your API keys here or use: hermes setup\n'
              'GATEWAY_ALLOW_ALL_USERS=true\n'
              'API_SERVER_ENABLED=true\n'
              'API_SERVER_KEY=1234\n'
              'API_SERVER_PORT=8642\n'
              'API_SERVER_HOST=127.0.0.1\n'
              'ENV_DEFAULTS\n'
              '  echo ".env created with defaults"; fi',
              timeout: 15,
            );
            // Also ensure config.yaml has gateway settings
            await NativeBridge.runInProot(
              'mkdir -p /root/.hermes && '
              'if [ ! -f /root/.hermes/config.yaml ]; then '
              '  cat > /root/.hermes/config.yaml << \'GATEWAY_CONFIG\'\n'
              'gateway:\n'
              '  port: ${AppConstants.gatewayPort}\n'
              '  bind: loopback\n'
              '  controlUi:\n'
              '    allowInsecureAuth: true\n'
              'GATEWAY_CONFIG\n'
              '  echo "config.yaml created"; fi',
              timeout: 15,
            );
          } catch (_) {}
        }
      });
    } catch (e) {
      setState(() {
        _installFailed = true;
        _outputBuffer.writeln('Failed to start terminal: $e');
      });
    }
  }

  // ── Navigate to dashboard ──

  Future<void> _goToDashboard() async {
    _pty?.kill();
    final navigator = Navigator.of(context);
    try {
      navigator.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const DashboardScreen()),
        (route) => false,
      );
    } catch (_) {}
  }

  void _retryInstall() {
    _pty?.kill();
    _pty = null;
    setState(() {
      _terminalStarted = false;
      _installDone = false;
      _installFailed = false;
      _exitCode = -1;
      _outputBuffer.clear();
    });
    _startTerminalInstall();
  }

  // ── Build UI ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('terminalInstallTitle')),
        automaticallyImplyLeading: !_bootstrapRunning,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Progress steps (compact)
            if (_bootstrapRunning || _bootstrapDone) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: _buildBootstrapSteps(l10n),
              ),
              const Divider(height: 1),
            ],

            // Terminal output area
            Expanded(
              child: _terminalStarted
                  ? _buildTerminalOutput(theme)
                  : _buildWaitingState(theme, l10n),
            ),

            // Bottom action bar
            if (_installDone || _installFailed)
              Padding(
                padding: const EdgeInsets.all(16),
                child: _buildBottomActions(l10n),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBootstrapSteps(AppLocalizations l10n) {
    final steps = [
      (1, l10n.t('setupWizardStepDownloadRootfs'), SetupStep.downloadingRootfs),
      (2, l10n.t('setupWizardStepExtractRootfs'), SetupStep.extractingRootfs),
      (3, l10n.t('setupWizardStepInstallPython'), SetupStep.installingPython),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (num, label, step) in steps)
          ProgressStep(
            stepNumber: num,
            label: _bootstrapState.step == step ? _bootstrapState.message : label,
            isActive: _bootstrapRunning && _bootstrapState.step == step,
            isComplete: _bootstrapState.stepNumber > num || _bootstrapDone,
            hasError: _bootstrapState.hasError && _bootstrapState.step == step,
            progress: _bootstrapRunning && _bootstrapState.step == step
                ? _bootstrapState.progress
                : null,
          ),
        if (_bootstrapDone)
          ProgressStep(
            stepNumber: 4,
            label: l10n.t('setupWizardStepInstallHermes'),
            isActive: _terminalStarted && !_installDone && !_installFailed,
            isComplete: _installDone,
            hasError: _installFailed,
          ),
      ],
    );
  }

  Widget _buildTerminalOutput(ThemeData theme) {
    final output = _outputBuffer.toString();
    return Container(
      color: const Color(0xFF1E1E1E),
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          output,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: Color(0xFFD4D4D4),
            height: 1.35,
          ),
        ),
      ),
    );
  }

  Widget _buildWaitingState(ThemeData theme, AppLocalizations l10n) {
    if (_bootstrapError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48,
                  color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(_bootstrapError!, textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _bootstrapError = null;
                    _bootstrapDone = false;
                    _bootstrapRunning = false;
                  });
                  _runBootstrap();
                },
                icon: const Icon(Icons.refresh),
                label: Text(l10n.t('commonRetry')),
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(l10n.t('terminalInstallRunning')),
        ],
      ),
    );
  }

  Widget _buildBottomActions(AppLocalizations l10n) {
    if (_installDone) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _goToDashboard,
          icon: const Icon(Icons.arrow_forward),
          label: Text(l10n.t('terminalInstallGoToDashboard')),
        ),
      );
    }

    // _installFailed
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _retryInstall,
            icon: const Icon(Icons.refresh),
            label: Text(l10n.t('terminalInstallRetry')),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _goToDashboard,
            icon: const Icon(Icons.skip_next),
            label: Text(l10n.t('setupWizardSkipToDashboard')),
          ),
        ),
      ],
    );
  }
}
