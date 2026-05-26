import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';
import '../constants.dart';
import '../models/gateway_state.dart';
import 'gateway_auth_config_service.dart';
import 'native_bridge.dart';
import 'preferences_service.dart';
import 'dashboard_url_resolver.dart';
import 'message_platform_config_service.dart';
import 'phone_bridge_service.dart';
import 'provider_config_service.dart';

class GatewayService {
  Timer? _healthTimer;
  Timer? _initialDelayTimer;
  StreamSubscription? _logSubscription;
  final _stateController = StreamController<GatewayState>.broadcast();
  GatewayState _state = const GatewayState();
  DateTime? _startingAt;
  bool _startInProgress = false;
  bool _dashboardUrlProbeInFlight = false;
  DateTime? _lastDashboardUrlProbeAt;
  bool _stateSyncInFlight = false;
  static final _leadingTimestamp = RegExp(r'^(\d{4}-\d{2}-\d{2}T\S+)\s+(.*)$');
  static final _boxDrawing = RegExp('[\\u2500-\\u257F\\u25C6\\u25C7]+');

  /// Strip terminal-only noise while preserving whitespace boundaries so
  /// adjacent log labels do not get glued onto `#token=...` URLs.
  static String _cleanForUrl(String text) {
    return text
        .replaceAll(AppConstants.ansiEscape, '')
        .replaceAll(_boxDrawing, '');
  }

  static String _formatTimestamp(DateTime dt) {
    final local = dt.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute:$second';
  }

  static String? _normalizeLogLine(String line) {
    final clean = line.replaceAll(AppConstants.ansiEscape, '').trim();
    if (clean.isEmpty) return clean;

    var timestampMatch = _leadingTimestamp.firstMatch(clean);
    if (timestampMatch == null) {
      final fallbackTimestamp = _formatTimestamp(DateTime.now());
      return _rewriteCompatibilityLog(clean, fallbackTimestamp) ?? clean;
    }

    var timestamp = timestampMatch.group(1)!;
    var body = timestampMatch.group(2)!;

    final nestedMatch = _leadingTimestamp.firstMatch(body);
    if (nestedMatch != null) {
      timestamp = nestedMatch.group(1)!;
      body = nestedMatch.group(2)!;
    }

    final parsed = DateTime.tryParse(timestamp);
    final formattedTimestamp = parsed == null
        ? _formatTimestamp(DateTime.now())
        : _formatTimestamp(parsed);
    return _rewriteCompatibilityLog(body, formattedTimestamp) ??
        '$formattedTimestamp $body';
  }

  static String? _rewriteCompatibilityLog(String body, String timestamp) {
    final trimmedBody = body.trim();
    if (trimmedBody.isEmpty) {
      return null;
    }

    if (trimmedBody.contains(
      '[agents/model-providers] [xai-auth] bootstrap config fallback: no config-backed key found',
    )) {
      return null;
    }

    if (trimmedBody.contains(
      '[hooks/boot-md] boot-md skipped for agent startup run',
    )) {
      return null;
    }

    if (trimmedBody.contains(
      '[gateway] security warning: dangerous config flags enabled: gateway.controlUi.allowInsecureAuth=true',
    )) {
      return '$timestamp [INFO] Local Control UI compatibility mode is enabled for localhost access.';
    }

    if (trimmedBody.contains(
      '[bonjour] watchdog detected non-announced service; attempting re-advertise',
    )) {
      return '$timestamp [INFO] Bonjour service advertisement is retrying on Android.';
    }

    if (trimmedBody.contains(
      '[model-pricing] pricing bootstrap failed: TimeoutError: The operation was aborted due to timeout',
    )) {
      return '$timestamp [WARN] Model pricing bootstrap timed out; the gateway can continue running.';
    }

    return null;
  }

  static String _ts(String msg) => '${_formatTimestamp(DateTime.now())} $msg';

  Stream<GatewayState> get stateStream => _stateController.stream;
  GatewayState get state => _state;

  void _updateState(GatewayState newState) {
    _state = newState;
    _stateController.add(_state);
  }

  void clearLogs() {
    _updateState(_state.copyWith(logs: const []));
  }

  Future<String?> _readConfiguredDashboardUrl() async {
    return GatewayAuthConfigService.readDashboardUrl(
      baseUri: Uri.parse(AppConstants.gatewayUrl),
    );
  }

  /// Check if the gateway is already running (e.g. after app restart)
  /// and sync the UI state accordingly.  If not running but auto-start
  /// is enabled, start it automatically.
  Future<void> init() async {
    final prefs = PreferencesService();
    await prefs.init();
    final savedUrl = prefs.dashboardUrl;
    final configuredDashboardUrl = await _readConfiguredDashboardUrl();
    final initialDashboardUrl = configuredDashboardUrl ?? savedUrl;

    if (configuredDashboardUrl != null && configuredDashboardUrl != savedUrl) {
      await _persistDashboardUrl(configuredDashboardUrl);
    }

    // Always ensure directories and resolv.conf exist on app open.
    // Android may clear the files directory during an app update (#40).
    try {
      await NativeBridge.setupDirs();
    } catch (_) {}
    try {
      await NativeBridge.writeResolv();
    } catch (_) {}
    // Dart dart:io fallback if native calls failed (#40).
    try {
      final filesDir = await NativeBridge.getFilesDir();
      const resolvContent = 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n';
      final resolvFile = File('$filesDir/config/resolv.conf');
      if (!resolvFile.existsSync()) {
        Directory('$filesDir/config').createSync(recursive: true);
        resolvFile.writeAsStringSync(resolvContent);
      }
      // Also write into rootfs /etc/ so DNS works even if bind-mount fails
      final rootfsResolv = File('$filesDir/rootfs/ubuntu/etc/resolv.conf');
      if (!rootfsResolv.existsSync()) {
        rootfsResolv.parent.createSync(recursive: true);
        rootfsResolv.writeAsStringSync(resolvContent);
      }
    } catch (_) {}

    await ProviderConfigService.migrateCustomProviderConfigIfNeeded();

    final alreadyRunning = await NativeBridge.isGatewayRunning();
    if (alreadyRunning) {
      // Write allowCommands config so the next gateway restart picks it up,
      // and in case the running gateway supports config hot-reload.
      await _writeNodeAllowConfig();
      // 确保节点 MCP 配置存在
      try {
        await PhoneBridgeService.setupNodeMcp();
      } catch (_) {}
      // ★ 确保节点 WS Server 在运行（先于 Gateway 检测）
      try {
        await PhoneBridgeService.startNodeWsServer();
      } catch (_) {}
      _startingAt = DateTime.now();
      _updateState(_state.copyWith(
        status: GatewayStatus.starting,
        dashboardUrl: initialDashboardUrl,
        logs: [
          ..._state.logs,
          _ts('[INFO] Gateway process detected, reconnecting...')
        ],
      ));

      _subscribeLogs();
      _startHealthCheck();
      if (!DashboardUrlResolver.hasToken(initialDashboardUrl)) {
        unawaited(_maybeRefreshDashboardUrl(force: true));
      }
    } else if (prefs.autoStartGateway) {
      _updateState(_state.copyWith(
        logs: [..._state.logs, _ts('[INFO] Auto-starting gateway...')],
      ));
      await start();
    }
  }

  Future<void> syncStateFromSystem() async {
    if (_stateSyncInFlight) {
      return;
    }

    _stateSyncInFlight = true;
    try {
      final prefs = PreferencesService();
      await prefs.init();
      final configuredDashboardUrl = await _readConfiguredDashboardUrl();
      final persistedDashboardUrl = DashboardUrlResolver.normalizeDashboardUrl(
        prefs.dashboardUrl,
        baseUri: Uri.parse(AppConstants.gatewayUrl),
      );
      final currentDashboardUrl = DashboardUrlResolver.normalizeDashboardUrl(
        _state.dashboardUrl,
        baseUri: Uri.parse(AppConstants.gatewayUrl),
      );
      final dashboardUrl = configuredDashboardUrl ??
          currentDashboardUrl ??
          persistedDashboardUrl;
      if (configuredDashboardUrl != null &&
          configuredDashboardUrl != persistedDashboardUrl) {
        await _persistDashboardUrl(configuredDashboardUrl);
      }
      final isRunning = await NativeBridge.isGatewayRunning();

      if (_state.status == GatewayStatus.stopping && isRunning) {
        return;
      }

      if (isRunning) {
        _startingAt ??= DateTime.now();
        _subscribeLogs();
        _ensureHealthCheck();

        final healthy = await checkHealth();
        // ★ If the process is alive, treat as running even if HTTP probe fails.
        // Hermes Agent may not expose an HTTP endpoint.
        final isAlive = await NativeBridge.isGatewayRunning();
        final shouldBeRunning = healthy || isAlive;
        _updateState(_state.copyWith(
          status: shouldBeRunning ? GatewayStatus.running : GatewayStatus.starting,
          clearError: true,
          startedAt: shouldBeRunning
              ? (_state.startedAt ?? DateTime.now())
              : null,
          dashboardUrl: dashboardUrl,
        ));

        await _refreshDashboardUrlFromConfig(notify: false);
        if (!DashboardUrlResolver.hasToken(dashboardUrl)) {
          unawaited(_maybeRefreshDashboardUrl(force: true));
        }
        return;
      }

      if (_state.status == GatewayStatus.stopped) {
        if (dashboardUrl != null && dashboardUrl != _state.dashboardUrl) {
          _updateState(_state.copyWith(dashboardUrl: dashboardUrl));
        }
        return;
      }

      _startingAt = null;
      _cancelAllTimers();
      await _logSubscription?.cancel();
      _logSubscription = null;
      _updateState(_state.copyWith(
        status: GatewayStatus.stopped,
        clearError: true,
        clearStartedAt: true,
        dashboardUrl: dashboardUrl,
      ));
    } finally {
      _stateSyncInFlight = false;
    }
  }

  void _subscribeLogs() {
    if (_logSubscription != null) {
      return;
    }
    _logSubscription = NativeBridge.gatewayLogStream.listen((log) {
      final normalizedLog = _normalizeLogLine(log);
      if (normalizedLog == null || normalizedLog.isEmpty) {
        return;
      }
      final logs = [..._state.logs, normalizedLog];
      if (logs.length > 500) {
        logs.removeRange(0, logs.length - 500);
      }
      final currentDashboardUrl = DashboardUrlResolver.normalizeDashboardUrl(
        _state.dashboardUrl,
        baseUri: Uri.parse(AppConstants.gatewayUrl),
      );
      String? dashboardUrl;
      final cleanLog = _cleanForUrl(normalizedLog);
      final resolvedUrl = DashboardUrlResolver.extractDashboardUrlFromText(
        cleanLog,
        baseUri: Uri.parse(AppConstants.gatewayUrl),
      );
      if (resolvedUrl != null) {
        dashboardUrl = resolvedUrl;
        unawaited(
          _persistDashboardUrl(
            resolvedUrl,
            notify: resolvedUrl != currentDashboardUrl,
          ),
        );
      }
      _updateState(
        _state.copyWith(
          logs: logs,
          dashboardUrl: dashboardUrl ?? currentDashboardUrl,
        ),
      );
    });
  }

  Future<void> _persistDashboardUrl(
    String dashboardUrl, {
    bool notify = false,
  }) async {
    try {
      final normalizedUrl = DashboardUrlResolver.normalizeDashboardUrl(
        dashboardUrl,
        baseUri: Uri.parse(AppConstants.gatewayUrl),
      );
      if (normalizedUrl == null) {
        return;
      }
      final prefs = PreferencesService();
      await prefs.init();
      prefs.dashboardUrl = normalizedUrl;
      if (notify) {
        await NativeBridge.showUrlNotification(
          normalizedUrl,
          title: 'Dashboard Ready',
        );
      }
    } catch (_) {
      // Ignore dashboard URL persistence failures and keep the gateway running.
    }
  }

  Future<void> _maybeRefreshDashboardUrl({bool force = false}) async {
    if (_dashboardUrlProbeInFlight) {
      return;
    }

    if (!force && DashboardUrlResolver.hasToken(_state.dashboardUrl)) {
      return;
    }

    final now = DateTime.now();
    if (!force &&
        _lastDashboardUrlProbeAt != null &&
        now.difference(_lastDashboardUrlProbeAt!) <
            const Duration(seconds: 15)) {
      return;
    }

    _dashboardUrlProbeInFlight = true;
    _lastDashboardUrlProbeAt = now;
    try {
      final resolvedUrl = await _resolveDashboardUrlFromGateway();
      if (resolvedUrl == null || resolvedUrl == _state.dashboardUrl) {
        return;
      }
      await _persistDashboardUrl(resolvedUrl);
      _updateState(_state.copyWith(dashboardUrl: resolvedUrl));
    } finally {
      _dashboardUrlProbeInFlight = false;
    }
  }

  Future<String?> _refreshDashboardUrlFromConfig({bool notify = false}) async {
    final configuredDashboardUrl = await _readConfiguredDashboardUrl();
    if (configuredDashboardUrl == null || configuredDashboardUrl.isEmpty) {
      return null;
    }

    final normalizedCurrent = DashboardUrlResolver.normalizeDashboardUrl(
      _state.dashboardUrl,
      baseUri: Uri.parse(AppConstants.gatewayUrl),
    );
    if (configuredDashboardUrl != normalizedCurrent) {
      await _persistDashboardUrl(
        configuredDashboardUrl,
        notify: notify,
      );
      _updateState(_state.copyWith(dashboardUrl: configuredDashboardUrl));
    }
    return configuredDashboardUrl;
  }

  Future<void> _bootstrapDashboardUrlFromConfig({
    Duration timeout = const Duration(seconds: 20),
    Duration interval = const Duration(seconds: 1),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_state.status == GatewayStatus.stopped ||
          _state.status == GatewayStatus.stopping) {
        return;
      }

      final url = await _refreshDashboardUrlFromConfig(notify: false);
      if (DashboardUrlResolver.hasToken(url)) {
        return;
      }

      await Future<void>.delayed(interval);
    }
  }

  Future<String?> _resolveDashboardUrlFromGateway() async {
    final configuredDashboardUrl = await _readConfiguredDashboardUrl();
    if (configuredDashboardUrl != null) {
      return configuredDashboardUrl;
    }

    final prefs = PreferencesService();
    await prefs.init();

    final candidateUris = <Uri>{Uri.parse(AppConstants.gatewayUrl)};

    void addCandidate(String? value) {
      if (value == null || value.isEmpty) {
        return;
      }
      final uri = Uri.tryParse(value);
      if (uri == null) {
        return;
      }
      candidateUris.add(DashboardUrlResolver.dashboardBaseUri(uri));
    }

    addCandidate(_state.dashboardUrl);
    addCandidate(prefs.dashboardUrl);

    for (final uri in candidateUris) {
      final resolvedUrl = await _probeDashboardUrl(uri);
      if (resolvedUrl != null) {
        return resolvedUrl;
      }
    }

    return null;
  }

  Future<String?> _probeDashboardUrl(Uri baseUri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      var currentUri = DashboardUrlResolver.dashboardBaseUri(baseUri);

      for (var redirectCount = 0; redirectCount < 4; redirectCount++) {
        final request = await client.getUrl(currentUri);
        request.followRedirects = false;
        final response =
            await request.close().timeout(const Duration(seconds: 3));
        final location = response.headers.value(HttpHeaders.locationHeader);

        if (location != null) {
          final resolvedFromLocation =
              DashboardUrlResolver.extractDashboardUrlFromText(
            location,
            baseUri: currentUri,
          );
          if (resolvedFromLocation != null) {
            return resolvedFromLocation;
          }
        }

        final body = await utf8.decodeStream(response).timeout(
              const Duration(seconds: 3),
            );
        final resolvedFromBody =
            DashboardUrlResolver.extractDashboardUrlFromText(
          body,
          baseUri: currentUri,
        );
        if (resolvedFromBody != null) {
          return resolvedFromBody;
        }

        if (!response.isRedirect || location == null) {
          break;
        }

        currentUri = currentUri.resolve(location);
      }
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }

    return null;
  }

  /// Patch /root/.hermes/config.yaml with gateway settings.
  /// Note: nodes/denyCommands/allowCommands are NOT written because
  /// Hermes Agent does not recognize these fields (they are ignored).
  Future<void> _writeNodeAllowConfig() async {
    // Use direct Dart file I/O to write YAML config to /root/.hermes/config.yaml
    try {
      final filesDir = await NativeBridge.getFilesDir();
      final configFile =
          File('$filesDir/rootfs/ubuntu/root/.hermes/config.yaml');
      Map<String, dynamic> config = {};
      if (configFile.existsSync()) {
        try {
          var content = configFile.readAsStringSync();
          if (content.trim().isNotEmpty) {
            // 修复旧版 bug：合并重复的 gateway 键
            // 旧版 _ensureMcpConfig 用字符串追加方式添加 mcp_servers，
            // 导致文件中出现多个 gateway: 顶层键，loadYaml 只保留最后一个
            final gatewayMatches =
                RegExp(r'^gateway:\s*$', multiLine: true).allMatches(content);
            if (gatewayMatches.length > 1) {
              content = _mergeDuplicateGatewayKeys(content);
            }
            final doc = loadYaml(content);
            if (doc is YamlMap) {
              config = _convertYamlMapFromService(doc);
            }
          }
        } catch (_) {}
      }
      config.putIfAbsent('gateway', () => <String, dynamic>{});
      final gw = config['gateway'] as Map<String, dynamic>;
      gw['port'] = AppConstants.gatewayPort;
      gw['bind'] = 'loopback';
      gw['controlUi'] = <String, dynamic>{'allowInsecureAuth': true};
      // Remove stale nodes/denyCommands/allowCommands if present from old versions
      gw.remove('nodes');
      configFile.parent.createSync(recursive: true);
      configFile.writeAsStringSync(_toYamlStringFromService(config));
    } catch (_) {}
  }

  /// 修复旧版 bug：合并文件中重复的 gateway: 顶层键
  /// 将所有 gateway: 块的内容合并到最后一个 gateway: 下
  static String _mergeDuplicateGatewayKeys(String content) {
    final lines = content.split('\n');
    final result = <String>[];
    final gatewayBlocks = <List<String>>[];
    List<String>? currentBlock;
    var inGateway = false;
    var gatewayIndent = 0;

    for (final line in lines) {
      final trimmed = line.trimRight();
      final match = RegExp(r'^(\s*)gateway:\s*$').firstMatch(trimmed);
      if (match != null) {
        // 保存之前的 gateway 块
        if (currentBlock != null) {
          gatewayBlocks.add(currentBlock);
        }
        currentBlock = [];
        inGateway = true;
        gatewayIndent = match.group(1)!.length;
        continue;
      }

      if (inGateway) {
        // 检查是否还在 gateway 块内（缩进大于 gateway: 或空行）
        if (trimmed.isEmpty) {
          currentBlock?.add(trimmed);
          continue;
        }
        final lineIndent = trimmed.length - trimmed.trimLeft().length;
        if (lineIndent > gatewayIndent) {
          currentBlock?.add(trimmed);
          continue;
        }
        // 遇到同级或更低缩进的键，结束当前 gateway 块
        if (currentBlock != null) {
          gatewayBlocks.add(currentBlock);
        }
        currentBlock = null;
        inGateway = false;
      }
      result.add(trimmed);
    }
    // 保存最后一个 gateway 块
    if (currentBlock != null) {
      gatewayBlocks.add(currentBlock);
    }

    if (gatewayBlocks.length <= 1) {
      return content; // 没有重复，返回原内容
    }

    // 合并所有 gateway 块的内容（去重）
    final mergedLines = <String>{};
    for (final block in gatewayBlocks) {
      for (final line in block) {
        if (line.trim().isNotEmpty) {
          mergedLines.add(line);
        }
      }
    }

    // 在文件末尾添加合并后的 gateway 块
    result.add('gateway:');
    for (final line in mergedLines) {
      result.add(line);
    }
    result.add('');

    return result.join('\n');
  }

  /// Helper to convert YamlMap to regular Map (used by _writeNodeAllowConfig)
  static Map<String, dynamic> _convertYamlMapFromService(YamlMap yamlMap) {
    final result = <String, dynamic>{};
    for (final entry in yamlMap.entries) {
      final key = entry.key.toString();
      if (entry.value is YamlMap) {
        result[key] = _convertYamlMapFromService(entry.value as YamlMap);
      } else if (entry.value is YamlList) {
        result[key] = (entry.value as YamlList).map((item) {
          if (item is YamlMap) return _convertYamlMapFromService(item);
          return item;
        }).toList();
      } else {
        result[key] = entry.value;
      }
    }
    return result;
  }

  /// Helper to convert Map to YAML string (used by _writeNodeAllowConfig)
  /// 修正：列表项缩进使用 prefix（而非 prefix+'  '），与标准 YAML 格式一致
  static String _toYamlStringFromService(Map<String, dynamic> config,
      {int indent = 0}) {
    final buffer = StringBuffer();
    final prefix = '  ' * indent;
    for (final entry in config.entries) {
      final key = entry.key;
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        if (value.isEmpty) {
          buffer.writeln('$prefix$key: {}');
        } else {
          buffer.writeln('$prefix$key:');
          buffer.write(_toYamlStringFromService(value, indent: indent + 1));
        }
      } else if (value is List) {
        if (value.isEmpty) {
          buffer.writeln('$prefix$key: []');
        } else {
          buffer.writeln('$prefix$key:');
          for (final item in value) {
            if (item is Map<String, dynamic>) {
              buffer.writeln('$prefix  -');
              for (final e in item.entries) {
                buffer.writeln('$prefix    ${e.key}: ${_yamlValueFromService(e.value)}');
              }
            } else {
              buffer.writeln('$prefix  - ${_yamlValueFromService(item)}');
            }
          }
        }
      } else {
        buffer.writeln('$prefix$key: ${_yamlValueFromService(value)}');
      }
    }
    return buffer.toString();
  }

  /// 修正：仅在值包含 YAML 特殊结构时才加引号
  /// 旧版对所有包含 ':' 的值都加引号，导致 ws://127.0.0.1:18790 被错误引用
  static String _yamlValueFromService(dynamic value) {
    if (value == null) return '';
    if (value is String) {
      if (value.contains('\n') ||
          value.startsWith('{') ||
          value.startsWith('[') ||
          value.startsWith('*') ||
          value.startsWith('&') ||
          value == 'true' ||
          value == 'false' ||
          value == 'null' ||
          RegExp(r'^\d+$').hasMatch(value)) {
        return '"${value.replaceAll('"', '\\"')}"';
      }
      // 包含 ": " (冒号+空格) 时需要引号，避免被解析为键值对
      if (value.contains(': ')) {
        return '"${value.replaceAll('"', '\\"')}"';
      }
      return value;
    }
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) return value.toString();
    return value.toString();
  }


  Future<void> start() async {
    // Prevent concurrent start() calls from racing
    if (_startInProgress || _state.status == GatewayStatus.stopping) {
      return;
    }
    _startInProgress = true;

    final prefs = PreferencesService();
    await prefs.init();
    final savedUrl = prefs.dashboardUrl;
    final configuredDashboardUrl = await _readConfiguredDashboardUrl();

    _updateState(_state.copyWith(
      status: GatewayStatus.starting,
      clearError: true,
      logs: [..._state.logs, _ts('[INFO] Starting gateway...')],
      dashboardUrl: configuredDashboardUrl ?? savedUrl,
    ));

    try {
      // Ensure directories exist - Android may have cleared them (#40).
      // Non-fatal: the GatewayService foreground service also creates them.
      try {
        await NativeBridge.setupDirs();
      } catch (_) {}
      try {
        await NativeBridge.writeResolv();
      } catch (_) {}
      // Dart dart:io fallback if native calls failed (#40).
      try {
        final filesDir = await NativeBridge.getFilesDir();
        const resolvContent = 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n';
        final resolvFile = File('$filesDir/config/resolv.conf');
        if (!resolvFile.existsSync()) {
          Directory('$filesDir/config').createSync(recursive: true);
          resolvFile.writeAsStringSync(resolvContent);
        }
        // Also write into rootfs /etc/ so DNS works even if bind-mount fails
        final rootfsResolv = File('$filesDir/rootfs/ubuntu/etc/resolv.conf');
        if (!rootfsResolv.existsSync()) {
          rootfsResolv.parent.createSync(recursive: true);
          rootfsResolv.writeAsStringSync(resolvContent);
        }
      } catch (_) {}
      await ProviderConfigService.migrateCustomProviderConfigIfNeeded();
      await ProviderConfigService.ensureGatewayDefaults();
      await MessagePlatformConfigService.migrateFeishuConfigIfNeeded();
      await _writeNodeAllowConfig();

      // ★ 部署节点 MCP 适配器脚本 + 写入配置
      try {
        await PhoneBridgeService.setupNodeMcp();
      } catch (_) {} // 非致命错误

      // ★ 先启动节点 WS Server，等端口就绪后再启动 Gateway
      // 避免 Gateway 启动后 MCP adapter 连不到 WS server 的竞态条件
      try {
        await PhoneBridgeService.startNodeWsServer();
        // startNodeWsServer 内部已等待端口就绪，无需额外 delay
      } catch (_) {}

      final refreshedDashboardUrl = await _readConfiguredDashboardUrl();
      if (refreshedDashboardUrl != null) {
        await _persistDashboardUrl(refreshedDashboardUrl);
        _updateState(_state.copyWith(dashboardUrl: refreshedDashboardUrl));
      }
      _startingAt = DateTime.now();
      _subscribeLogs();
      await NativeBridge.startGateway();
      _startHealthCheck();
      unawaited(_bootstrapDashboardUrlFromConfig());
    } catch (e) {
      _updateState(_state.copyWith(
        status: GatewayStatus.error,
        errorMessage: 'Failed to start: $e',
        logs: [..._state.logs, _ts('[ERROR] Failed to start: $e')],
      ));
    } finally {
      _startInProgress = false;
    }
  }

  Future<void> stop() async {
    _cancelAllTimers();
    _startingAt = null;

    if (_state.status == GatewayStatus.stopped ||
        _state.status == GatewayStatus.stopping) {
      return;
    }

    _updateState(_state.copyWith(
      status: GatewayStatus.stopping,
      clearError: true,
      clearStartedAt: true,
      logs: [..._state.logs, _ts('[INFO] Stopping gateway...')],
    ));

    try {
      // stopGateway() calls Kotlin stopAndWait() which blocks until
      // the process tree is killed and port 8642 is freed (max 15s).
      final stopped = await NativeBridge.stopGateway();

      await _logSubscription?.cancel();
      _logSubscription = null;

      if (stopped) {
        _updateState(_state.copyWith(
          status: GatewayStatus.stopped,
          clearError: true,
          clearStartedAt: true,
          logs: [..._state.logs, _ts('[INFO] Gateway stopped')],
        ));
      } else {
        // stopAndWait timed out — verify with a final check
        final stillRunning = await NativeBridge.isGatewayRunning();
        if (stillRunning) {
          _updateState(_state.copyWith(
            status: GatewayStatus.error,
            errorMessage: 'Gateway may still be running (stop timed out)',
            logs: [..._state.logs,
              _ts('[WARN] Stop timed out, gateway process may still be alive')],
          ));
        } else {
          _updateState(_state.copyWith(
            status: GatewayStatus.stopped,
            clearError: true,
            clearStartedAt: true,
            logs: [..._state.logs, _ts('[INFO] Gateway stopped (verified)')],
          ));
        }
      }
    } catch (e) {
      _updateState(_state.copyWith(
        status: GatewayStatus.error,
        errorMessage: 'Failed to stop: $e',
        logs: [..._state.logs, _ts('[ERROR] Failed to stop: $e')],
      ));
    }
  }

  /// Cancel both the initial delay timer and periodic health timer.
  void _cancelAllTimers() {
    _initialDelayTimer?.cancel();
    _initialDelayTimer = null;
    _healthTimer?.cancel();
    _healthTimer = null;
  }

  void _ensureHealthCheck() {
    if (_initialDelayTimer != null || _healthTimer != null) {
      return;
    }
    _startHealthCheck();
  }

  void _startHealthCheck() {
    _cancelAllTimers();
    // Poll health every 500ms, starting after 500ms.
    // The caller (_checkStartHealth / _checkStopHealth) enforces its own
    // timeout (15s for start, 5s for stop).
    _initialDelayTimer = Timer(const Duration(milliseconds: 500), () {
      _initialDelayTimer = null;
      if (_state.status == GatewayStatus.stopped ||
          _state.status == GatewayStatus.stopping) {
        return;
      }
      _checkHealth();
      _healthTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _checkHealth(),
      );
    });
  }

  Future<void> _checkHealth() async {
    try {
      final response = await _probeGatewayHealth();

      if (response.statusCode < 500 && _state.status != GatewayStatus.running) {
        _cancelAllTimers();
        _updateState(_state.copyWith(
          status: GatewayStatus.running,
          startedAt: _state.startedAt ?? DateTime.now(),
          logs: [..._state.logs, _ts('[INFO] Gateway is healthy')],
        ));
      }

      await _refreshDashboardUrlFromConfig(notify: false);
      if (response.statusCode < 500 &&
          !DashboardUrlResolver.hasToken(_state.dashboardUrl)) {
        unawaited(_maybeRefreshDashboardUrl());
      }
    } catch (_) {
      if (_state.status == GatewayStatus.stopping) {
        // During stop: connection failure means stop succeeded
        _cancelAllTimers();
        _updateState(_state.copyWith(
          status: GatewayStatus.stopped,
          clearError: true,
          clearStartedAt: true,
          logs: [..._state.logs, _ts('[INFO] Gateway stopped')],
        ));
        return;
      }
      // HTTP probe failed — check if the gateway process is still alive.
      // Hermes Agent may not expose an HTTP endpoint, so process-alive
      // is the only reliable health signal.
      final isRunning = await NativeBridge.isGatewayRunning();
      if (isRunning) {
        // Process is alive — treat as healthy even without HTTP response.
        if (_state.status != GatewayStatus.running) {
          _cancelAllTimers();
          _updateState(_state.copyWith(
            status: GatewayStatus.running,
            startedAt: _state.startedAt ?? DateTime.now(),
            logs: [..._state.logs, _ts('[INFO] Gateway process is running')],
          ));
        }
        return;
      }
      // Process not running
      if (_state.status != GatewayStatus.stopped) {
        // Grace period: 15s for start timeout
        if (_startingAt != null &&
            _state.status == GatewayStatus.starting &&
            DateTime.now().difference(_startingAt!).inSeconds < 15) {
          return;
        }
        _cancelAllTimers();
        _updateState(_state.copyWith(
          status: _state.status == GatewayStatus.starting
              ? GatewayStatus.error
              : GatewayStatus.stopped,
          errorMessage: _state.status == GatewayStatus.starting
              ? '网关启动超时，请查看服务器日志'
              : null,
          clearError: _state.status != GatewayStatus.starting,
          logs: [..._state.logs, _ts('[WARN] Gateway process not running')],
        ));
      }
    }
  }

  Future<http.Response> _probeGatewayHealth() async {
    // ★ Probe gateway API server (port 8642).
    // Try /health endpoint first, then root.
    final gatewayUri = Uri.parse(AppConstants.gatewayUrl);
    final gatewayHealthUri = gatewayUri.resolve('/health');

    for (final uri in [gatewayHealthUri, gatewayUri]) {
      try {
        return await http.get(uri).timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          return await http.head(uri).timeout(const Duration(seconds: 2));
        } catch (_) {
          // Try next URI
        }
      }
    }
    throw Exception('Gateway health check failed');
  }

  Future<bool> checkHealth() async {
    try {
      final response = await _probeGatewayHealth();
      return response.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  Future<void> applyConfigChanges({String source = 'configuration'}) async {
    await ProviderConfigService.migrateCustomProviderConfigIfNeeded();
    await ProviderConfigService.ensureGatewayDefaults();

    final isGatewayActive = _state.status == GatewayStatus.running ||
        _state.status == GatewayStatus.starting;

    if (!isGatewayActive) {
      _updateState(_state.copyWith(logs: [
        ..._state.logs,
        _ts('[INFO] $source updated. Changes will apply the next time the gateway starts.'),
      ]));
      return;
    }

    _updateState(_state.copyWith(logs: [
      ..._state.logs,
      _ts('[INFO] $source updated. Hermes will hot-reload the new configuration.'),
    ]));

    try {
      await _refreshDashboardUrlFromConfig(notify: false);
      unawaited(_maybeRefreshDashboardUrl(force: true));
      await syncStateFromSystem();
    } catch (e) {
      _updateState(_state.copyWith(logs: [
        ..._state.logs,
        _ts('[ERROR] Failed to refresh $source automatically: $e'),
      ]));
    }
  }

  void dispose() {
    _cancelAllTimers();
    _logSubscription?.cancel();
    _stateController.close();
  }
}
