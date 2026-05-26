import 'package:flutter/services.dart';
import '../constants.dart';

class NativeBridge {
  static const _channel = MethodChannel(AppConstants.channelName);
  static const _eventChannel = EventChannel(AppConstants.eventChannelName);
  static const _setupLogEventChannel =
      EventChannel(AppConstants.setupLogEventChannelName);

  static Future<String> getProotPath() async {
    return await _channel.invokeMethod('getProotPath');
  }

  static Future<String> getArch() async {
    return await _channel.invokeMethod('getArch');
  }

  static Future<String> getAndroidApiLevel() async {
    final result = await _channel.invokeMethod('getAndroidApiLevel');
    return result?.toString() ?? '';
  }

  static Future<String> getFilesDir() async {
    return await _channel.invokeMethod('getFilesDir');
  }

  static Future<String> getNativeLibDir() async {
    return await _channel.invokeMethod('getNativeLibDir');
  }

  static Future<Map<String, dynamic>> getWebViewPackageInfo() async {
    final result = await _channel.invokeMethod('getWebViewPackageInfo');
    return Map<String, dynamic>.from(result);
  }

  static Future<bool> isBootstrapComplete() async {
    return await _channel.invokeMethod('isBootstrapComplete');
  }

  static Future<Map<String, dynamic>> getBootstrapStatus() async {
    final result = await _channel.invokeMethod('getBootstrapStatus');
    return Map<String, dynamic>.from(result);
  }

  static Future<bool> extractRootfs(String tarPath) async {
    return await _channel.invokeMethod('extractRootfs', {'tarPath': tarPath});
  }

  static Future<String> runInProot(String command, {int timeout = 900}) async {
    return await _channel
        .invokeMethod('runInProot', {'command': command, 'timeout': timeout});
  }

  static Future<bool> startGateway() async {
    return await _channel.invokeMethod('startGateway');
  }

  static Future<bool> stopGateway() async {
    return await _channel.invokeMethod('stopGateway');
  }

  static Future<bool> isGatewayRunning() async {
    return await _channel.invokeMethod('isGatewayRunning');
  }

  static Future<bool> isGatewayLogPersistenceEnabled() async {
    return await _channel.invokeMethod('isGatewayLogPersistenceEnabled');
  }

  static Future<bool> setGatewayLogPersistenceEnabled(bool enabled) async {
    return await _channel.invokeMethod(
      'setGatewayLogPersistenceEnabled',
      {'enabled': enabled},
    );
  }

  static Future<bool> setupDirs() async {
    return await _channel.invokeMethod('setupDirs');
  }

  static Future<bool> installBionicBypass() async {
    return await _channel.invokeMethod('installBionicBypass');
  }

  static Future<bool> writeResolv() async {
    return await _channel.invokeMethod('writeResolv');
  }

  static Future<bool> setupProotFromTermux({String? arch}) async {
    return await _channel
        .invokeMethod('setupProotFromTermux', {'arch': arch});
  }

  static Future<bool> copyBundledAssetToFile({
    required String assetPath,
    required String destinationPath,
  }) async {
    return await _channel.invokeMethod('copyBundledAssetToFile', {
      'assetPath': assetPath,
      'destinationPath': destinationPath,
    });
  }

  static Future<int> extractDebPackages() async {
    return await _channel.invokeMethod('extractDebPackages');
  }

  static Future<bool> extractPythonTarball(String tarPath) async {
    return await _channel
        .invokeMethod('extractPythonTarball', {'tarPath': tarPath});
  }

  static Future<bool> ensureHermesEntryPoint({
    String entryPoint = 'hermes',
    String moduleName = 'hermes_cli',
  }) async {
    return await _channel.invokeMethod('ensureHermesEntryPoint', {
      'entryPoint': entryPoint,
      'moduleName': moduleName,
    });
  }

  static Future<bool> startTerminalService() async {
    return await _channel.invokeMethod('startTerminalService');
  }

  static Future<bool> stopTerminalService() async {
    return await _channel.invokeMethod('stopTerminalService');
  }

  static Future<bool> isTerminalServiceRunning() async {
    return await _channel.invokeMethod('isTerminalServiceRunning');
  }

  static Future<bool> startNodeService() async {
    return await _channel.invokeMethod('startNodeService');
  }

  static Future<bool> stopNodeService() async {
    return await _channel.invokeMethod('stopNodeService');
  }

  static Future<bool> isNodeServiceRunning() async {
    return await _channel.invokeMethod('isNodeServiceRunning');
  }

  /// 启动节点 WS Server（持久化进程，非 runInProot）
  static Future<bool> startNodeWsServer() async {
    return await _channel.invokeMethod('startNodeWsServer');
  }

  /// 停止节点 WS Server
  static Future<bool> stopNodeWsServer() async {
    return await _channel.invokeMethod('stopNodeWsServer');
  }

  /// 检查节点 WS Server 是否在运行
  static Future<bool> isNodeWsServerRunning() async {
    return await _channel.invokeMethod('isNodeWsServerRunning');
  }

  static Future<bool> updateNodeNotification(String text) async {
    return await _channel
        .invokeMethod('updateNodeNotification', {'text': text});
  }

  static Future<bool> requestBatteryOptimization() async {
    return await _channel.invokeMethod('requestBatteryOptimization');
  }

  static Future<bool> isBatteryOptimized() async {
    return await _channel.invokeMethod('isBatteryOptimized');
  }

  static Future<bool> startSetupService() async {
    return await _channel.invokeMethod('startSetupService');
  }

  static Future<bool> updateSetupNotification(String text,
      {int progress = -1}) async {
    return await _channel.invokeMethod(
        'updateSetupNotification', {'text': text, 'progress': progress});
  }

  static Future<bool> stopSetupService() async {
    return await _channel.invokeMethod('stopSetupService');
  }

  static Future<bool> showUrlNotification(String url,
      {String title = 'URL Detected'}) async {
    return await _channel
        .invokeMethod('showUrlNotification', {'url': url, 'title': title});
  }

  static Future<Map<String, dynamic>?> pickSnapshotFile() async {
    final result = await _channel.invokeMethod('pickSnapshotFile');
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>?> saveSnapshotFile({
    required String suggestedName,
    required String content,
  }) async {
    final result = await _channel.invokeMethod('saveSnapshotFile', {
      'suggestedName': suggestedName,
      'content': content,
    });
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>?> pickBackupFile() async {
    final result = await _channel.invokeMethod('pickBackupFile');
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>?> pickBootstrapArchiveFile() async {
    final result = await _channel.invokeMethod('pickBootstrapArchiveFile');
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>?> exportWorkspaceBackup({
    required String suggestedName,
    required String appVersion,
    String? hermesVersion,
  }) async {
    final result = await _channel.invokeMethod('exportWorkspaceBackup', {
      'suggestedName': suggestedName,
      'appVersion': appVersion,
      'hermesVersion': hermesVersion,
    });
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  static Future<Map<String, dynamic>?> inspectWorkspaceBackup(
    String path,
  ) async {
    final result = await _channel.invokeMethod(
      'inspectWorkspaceBackup',
      {'path': path},
    );
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  static Future<bool> restoreWorkspaceBackup(String path) async {
    return await _channel.invokeMethod(
      'restoreWorkspaceBackup',
      {'path': path},
    );
  }

  static Stream<String> get gatewayLogStream {
    return _eventChannel
        .receiveBroadcastStream()
        .map((event) => event.toString());
  }

  static Stream<String> get setupLogStream {
    return _setupLogEventChannel
        .receiveBroadcastStream()
        .map((event) => event.toString());
  }

  static Future<String?> requestScreenCapture(int durationMs) async {
    return await _channel
        .invokeMethod('requestScreenCapture', {'durationMs': durationMs});
  }

  static Future<bool> stopScreenCapture() async {
    return await _channel.invokeMethod('stopScreenCapture');
  }

  static Future<bool> requestStoragePermission() async {
    return await _channel.invokeMethod('requestStoragePermission');
  }

  static Future<bool> hasStoragePermission() async {
    return await _channel.invokeMethod('hasStoragePermission');
  }

  static Future<String> getExternalStoragePath() async {
    return await _channel.invokeMethod('getExternalStoragePath');
  }

  static Future<bool> installApk(String apkPath) async {
    return await _channel.invokeMethod('installApk', {'apkPath': apkPath});
  }

  static Future<String?> readRootfsFile(String path) async {
    return await _channel.invokeMethod('readRootfsFile', {'path': path});
  }

  static Future<bool> writeRootfsFile(String path, String content) async {
    return await _channel
        .invokeMethod('writeRootfsFile', {'path': path, 'content': content});
  }

  // SSH Service
  static Future<bool> startSshd({int port = 8022}) async {
    return await _channel.invokeMethod('startSshd', {'port': port});
  }

  static Future<bool> stopSshd() async {
    return await _channel.invokeMethod('stopSshd');
  }

  static Future<bool> isSshdRunning() async {
    return await _channel.invokeMethod('isSshdRunning');
  }

  static Future<int> getSshdPort() async {
    return await _channel.invokeMethod('getSshdPort');
  }

  static Future<bool> startCpolarService({
    required String binaryPath,
    required String configPath,
    required String logPath,
    int webPort = 9200,
  }) async {
    return await _channel.invokeMethod('startCpolarService', {
      'binaryPath': binaryPath,
      'configPath': configPath,
      'logPath': logPath,
      'webPort': webPort,
    });
  }

  static Future<bool> stopCpolarService() async {
    return await _channel.invokeMethod('stopCpolarService');
  }

  static Future<bool> isCpolarServiceRunning() async {
    return await _channel.invokeMethod('isCpolarServiceRunning');
  }

  static Future<bool> startLocalModelService({
    required String binaryPath,
    required String modelPath,
    required String logPath,
    required int port,
    required String alias,
    required int contextSize,
    required int threads,
    required int threadsBatch,
    required int batchSize,
    required int ubatchSize,
  }) async {
    return await _channel.invokeMethod('startLocalModelService', {
      'binaryPath': binaryPath,
      'modelPath': modelPath,
      'logPath': logPath,
      'port': port,
      'alias': alias,
      'contextSize': contextSize,
      'threads': threads,
      'threadsBatch': threadsBatch,
      'batchSize': batchSize,
      'ubatchSize': ubatchSize,
    });
  }

  static Future<bool> stopLocalModelService() async {
    return await _channel.invokeMethod('stopLocalModelService');
  }

  static Future<bool> isLocalModelServiceRunning() async {
    return await _channel.invokeMethod('isLocalModelServiceRunning');
  }

  static Future<Map<String, dynamic>?> getLocalModelRuntimeStats() async {
    final result = await _channel.invokeMethod('getLocalModelRuntimeStats');
    if (result == null) {
      return null;
    }
    return Map<String, dynamic>.from(result);
  }

  static Future<List<String>> getDeviceIps() async {
    final result = await _channel.invokeMethod('getDeviceIps');
    return List<String>.from(result);
  }

  static Future<bool> bringToForeground() async {
    return await _channel.invokeMethod('bringToForeground');
  }

  static Future<bool> setRootPassword(String password) async {
    return await _channel
        .invokeMethod('setRootPassword', {'password': password});
  }

  // ==========================================================================
  // Accessibility Service — UI Automation
  // ==========================================================================

  /// 无障碍服务是否已连接
  static Future<bool> isAccessibilityServiceRunning() async {
    return await _channel.invokeMethod('isAccessibilityServiceRunning');
  }

  /// 打开系统无障碍设置页面
  static Future<bool> openAccessibilitySettings() async {
    return await _channel.invokeMethod('openAccessibilitySettings');
  }

  /// dump UI 树 (XML)
  static Future<String> a11yDumpTree() async {
    return await _channel.invokeMethod('a11yDumpTree');
  }

  /// 手势点击
  static Future<bool> a11yTap(int x, int y) async {
    return await _channel.invokeMethod('a11yTap', {'x': x, 'y': y});
  }

  /// 滑动手势
  static Future<bool> a11ySwipe(
      int x1, int y1, int x2, int y2, int duration) async {
    return await _channel.invokeMethod('a11ySwipe', {
      'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'duration': duration,
    });
  }

  /// 输入文本
  static Future<bool> a11yInput(String text, {bool append = false}) async {
    return await _channel
        .invokeMethod('a11yInput', {'text': text, 'append': append});
  }

  /// 全局按键 (back / home / recents / notifications)
  static Future<bool> a11yKey(String key) async {
    return await _channel.invokeMethod('a11yKey', {'key': key});
  }

  /// 滚动 (up / down / left / right)
  static Future<bool> a11yScroll(String direction) async {
    return await _channel.invokeMethod('a11yScroll', {'direction': direction});
  }

  /// 查找 UI 元素
  static Future<List<dynamic>> a11yFind({
    String? text,
    String? id,
    String? description,
    String? className,
    bool clickableOnly = false,
  }) async {
    final result = await _channel.invokeMethod('a11yFind', {
      'text': text ?? '',
      'id': id ?? '',
      'description': description ?? '',
      'class_name': className ?? '',
      'clickable_only': clickableOnly,
    });
    return List<dynamic>.from(result ?? []);
  }

  /// 等待元素出现
  static Future<bool> a11yWait({
    String? text,
    String? id,
    String? description,
    int timeout = 5000,
    int pollInterval = 300,
  }) async {
    return await _channel.invokeMethod('a11yWait', {
      'text': text ?? '',
      'id': id ?? '',
      'description': description ?? '',
      'timeout': timeout,
      'poll_interval': pollInterval,
    });
  }

  /// 按文本点击
  static Future<bool> a11yClickText(String text) async {
    return await _channel.invokeMethod('a11yClickText', {'text': text});
  }

  /// 按 resource-id 点击
  static Future<bool> a11yClickId(String id) async {
    return await _channel.invokeMethod('a11yClickId', {'id': id});
  }

  /// 截图 (返回 base64 JPEG)
  static Future<String?> a11yScreenshot() async {
    return await _channel.invokeMethod('a11yScreenshot');
  }

  /// 获取当前前台 App
  static Future<Map<String, dynamic>> a11yCurrentApp() async {
    final result = await _channel.invokeMethod('a11yCurrentApp');
    return Map<String, dynamic>.from(result);
  }

  /// 获取设备信息
  static Future<Map<String, dynamic>> a11yDeviceInfo() async {
    final result = await _channel.invokeMethod('a11yDeviceInfo');
    return Map<String, dynamic>.from(result);
  }

  /// 读取剪贴板
  static Future<String> a11yClipboardRead() async {
    return await _channel.invokeMethod('a11yClipboardRead') ?? '';
  }

  /// 写入剪贴板
  static Future<bool> a11yClipboardWrite(String text) async {
    return await _channel.invokeMethod('a11yClipboardWrite', {'text': text});
  }

  /// 获取/设置音量
  static Future<dynamic> a11yVolume({String? stream, int? level}) async {
    final args = <String, dynamic>{};
    if (stream != null) args['stream'] = stream;
    if (level != null) args['level'] = level;
    return await _channel.invokeMethod('a11yVolume', args);
  }

  /// 获取像素颜色
  static Future<String?> a11yColor(int x, int y) async {
    return await _channel.invokeMethod('a11yColor', {'x': x, 'y': y});
  }

  /// 获取已安装 App 列表
  static Future<List<dynamic>> a11yInstalledApps() async {
    final result = await _channel.invokeMethod('a11yInstalledApps');
    return List<dynamic>.from(result ?? []);
  }

  /// 启动 App
  static Future<bool> a11yLaunchApp(String package,
      {String? action, String? uri, String? type}) async {
    return await _channel.invokeMethod('a11yLaunchApp', {
      'package': package,
      'action': action ?? '',
      'uri': uri ?? '',
      'type': type ?? '',
    });
  }

  /// OCR 识别 (截图 + ML Kit)
  static Future<String?> a11yOcr() async {
    return await _channel.invokeMethod('a11yOcr');
  }

  /// 是否有 UsageStats 权限
  static Future<bool> a11yHasUsageStatsPermission() async {
    return await _channel.invokeMethod('a11yHasUsageStatsPermission');
  }

  /// 打开 UsageStats 设置页
  static Future<bool> a11yOpenUsageStatsSettings() async {
    return await _channel.invokeMethod('a11yOpenUsageStatsSettings');
  }

  // ==========================================================================
  // Toast
  // ==========================================================================

  /// 显示 Toast 提示
  static Future<bool> showToast(String message, {bool isLong = false}) async {
    return await _channel.invokeMethod(
        'showToast', {'message': message, 'long': isLong});
  }

  // ==========================================================================
  // JS Bridge — 浏览器 JS 注入
  // ==========================================================================

  /// 启动 JS Bridge WebSocket Server
  static Future<bool> startJsBridge({int port = 8767}) async {
    return await _channel.invokeMethod('startJsBridge', {'port': port});
  }

  /// 停止 JS Bridge Server
  static Future<bool> stopJsBridge() async {
    return await _channel.invokeMethod('stopJsBridge');
  }

  /// JS Bridge 是否在运行
  static Future<bool> isJsBridgeRunning() async {
    return await _channel.invokeMethod('isJsBridgeRunning');
  }

  /// 获取 JS Bridge 状态信息
  static Future<Map<String, dynamic>> jsBridgeInfo() async {
    final result = await _channel.invokeMethod('jsBridgeInfo');
    return Map<String, dynamic>.from(result);
  }

  /// 在已连接的浏览器中执行 JS 代码
  static Future<String> execJsOnBrowser(String code,
      {int timeoutMs = 10000}) async {
    return await _channel.invokeMethod('execJsOnBrowser', {
      'code': code,
      'timeout_ms': timeoutMs,
    });
  }

  /// 获取 JS Bridge 油猴脚本
  static Future<String> getJsBridgeUserscript(
      String serverIp, int serverPort) async {
    return await _channel.invokeMethod('getJsBridgeUserscript', {
      'server_ip': serverIp,
      'server_port': serverPort,
    });
  }
}
