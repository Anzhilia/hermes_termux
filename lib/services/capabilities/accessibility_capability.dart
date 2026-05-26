import 'dart:convert';
import '../../models/node_frame.dart';
import '../native_bridge.dart';
import '../operation_logger.dart';
import 'capability_handler.dart';

/// 无障碍服务能力 — 将 control-app (AutoServer) 的 UI 自动化能力
/// 通过 OpenClaw Node Protocol 暴露给 Gateway AI。
///
/// 支持的命令：
///   accessibility.tap           — 坐标点击
///   accessibility.swipe         — 滑动手势
///   accessibility.input         — 文本输入
///   accessibility.key           — 全局按键 (back/home/recents/notifications)
///   accessibility.scroll        — 滚动 (up/down/left/right)
///   accessibility.find          — 查找 UI 元素
///   accessibility.wait          — 等待元素出现
///   accessibility.click_text    — 按文本点击
///   accessibility.click_id      — 按 resource-id 点击
///   accessibility.screenshot    — 截图 (base64 JPEG)
///   accessibility.ui_tree       — dump UI 树 (XML)
///   accessibility.current_app   — 获取当前前台 App
///   accessibility.device_info   — 获取设备信息
///   accessibility.clipboard_read  — 读取剪贴板
///   accessibility.clipboard_write — 写入剪贴板
///   accessibility.volume        — 获取/设置音量
///   accessibility.color         — 获取像素颜色
///   accessibility.installed_apps — 已安装 App 列表
///   accessibility.launch_app    — 启动 App
///   accessibility.ocr           — OCR 识别 (截图 + ML Kit)
///   accessibility.batch         — 批量操作
class AccessibilityCapability extends CapabilityHandler {
  @override
  String get name => 'accessibility';

  final OperationLogger _logger = OperationLogger();

  @override
  List<String> get commands => [
        'tap',
        'swipe',
        'input',
        'key',
        'scroll',
        'find',
        'wait',
        'click_text',
        'click_id',
        'screenshot',
        'ui_tree',
        'current_app',
        'device_info',
        'clipboard_read',
        'clipboard_write',
        'volume',
        'color',
        'installed_apps',
        'launch_app',
        'ocr',
        'batch',
        'toast',
        'js_exec',
        'js_bridge_start',
        'js_bridge_stop',
        'js_bridge_info',
        'js_bridge_userscript',
        'logs',
        'logs_clear',
      ];

  @override
  Future<bool> checkPermission() async {
    // 无障碍服务需要用户手动在系统设置中开启，无法自动检查权限
    // 通过尝试调用一个轻量操作来判断服务是否可用
    try {
      final result = await NativeBridge.isAccessibilityServiceRunning();
      return result;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    // 引导用户到无障碍设置页面
    try {
      await NativeBridge.openAccessibilitySettings();
    } catch (_) {}
    return false; // 返回 false，因为需要用户手动操作
  }

  @override
  Future<NodeFrame> handle(String command, Map<String, dynamic> params) async {
    // 检查无障碍服务是否连接
    final isRunning = await NativeBridge.isAccessibilityServiceRunning();
    if (!isRunning) {
      return NodeFrame.response('', error: {
        'code': 'A11Y_NOT_RUNNING',
        'message':
            'Accessibility service not connected. Please enable it in Android Settings > Accessibility > Hermes Agent.',
      });
    }

    try {
      NodeFrame result;
      switch (command) {
        case 'accessibility.tap':
          result = await _tap(params);
          break;
        case 'accessibility.swipe':
          result = await _swipe(params);
          break;
        case 'accessibility.input':
          result = await _input(params);
          break;
        case 'accessibility.key':
          result = await _key(params);
          break;
        case 'accessibility.scroll':
          result = await _scroll(params);
          break;
        case 'accessibility.find':
          result = await _find(params);
          break;
        case 'accessibility.wait':
          result = await _wait(params);
          break;
        case 'accessibility.click_text':
          result = await _clickText(params);
          break;
        case 'accessibility.click_id':
          result = await _clickId(params);
          break;
        case 'accessibility.screenshot':
          result = await _screenshot(params);
          break;
        case 'accessibility.ui_tree':
          result = await _uiTree(params);
          break;
        case 'accessibility.current_app':
          result = await _currentApp(params);
          break;
        case 'accessibility.device_info':
          result = await _deviceInfo(params);
          break;
        case 'accessibility.clipboard_read':
          result = await _clipboardRead(params);
          break;
        case 'accessibility.clipboard_write':
          result = await _clipboardWrite(params);
          break;
        case 'accessibility.volume':
          result = await _volume(params);
          break;
        case 'accessibility.color':
          result = await _color(params);
          break;
        case 'accessibility.installed_apps':
          result = await _installedApps(params);
          break;
        case 'accessibility.launch_app':
          result = await _launchApp(params);
          break;
        case 'accessibility.ocr':
          result = await _ocr(params);
          break;
        case 'accessibility.batch':
          result = await _batch(params);
          break;
        case 'accessibility.toast':
          result = await _toast(params);
          break;
        case 'accessibility.js_exec':
          result = await _jsExec(params);
          break;
        case 'accessibility.js_bridge_start':
          result = await _jsBridgeStart(params);
          break;
        case 'accessibility.js_bridge_stop':
          result = await _jsBridgeStop(params);
          break;
        case 'accessibility.js_bridge_info':
          result = await _jsBridgeInfo(params);
          break;
        case 'accessibility.js_bridge_userscript':
          result = await _jsBridgeUserscript(params);
          break;
        case 'accessibility.logs':
          result = await _logs(params);
          break;
        case 'accessibility.logs_clear':
          result = await _logsClear(params);
          break;
        default:
          result = NodeFrame.response('', error: {
            'code': 'UNKNOWN_COMMAND',
            'message': 'Unknown accessibility command: $command',
          });
      }

      // 记录操作日志（排除 logs/logs_clear/js_bridge_info 避免循环）
      if (!command.endsWith('.logs') &&
          !command.endsWith('.logs_clear') &&
          !command.endsWith('.js_bridge_info')) {
        _logger.log(
          command.replaceFirst('accessibility.', ''),
          success: !result.isError,
          details: result.isError
              ? (result.error?['message']?.toString() ?? '')
              : _summarizePayload(result.payload),
        );
      }

      return result;
    } catch (e) {
      return NodeFrame.response('', error: {
        'code': 'A11Y_ERROR',
        'message': '$e',
      });
    }
  }

  Future<NodeFrame> _tap(Map<String, dynamic> params) async {
    final x = params['x'] as int? ?? -1;
    final y = params['y'] as int? ?? -1;
    if (x < 0 || y < 0) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing or invalid x, y coordinates',
      });
    }
    final ok = await NativeBridge.a11yTap(x, y);
    return NodeFrame.response('', payload: {'success': ok, 'x': x, 'y': y});
  }

  Future<NodeFrame> _swipe(Map<String, dynamic> params) async {
    final x1 = params['x1'] as int? ?? -1;
    final y1 = params['y1'] as int? ?? -1;
    final x2 = params['x2'] as int? ?? -1;
    final y2 = params['y2'] as int? ?? -1;
    final duration = params['duration'] as int? ?? 300;
    if (x1 < 0 || y1 < 0 || x2 < 0 || y2 < 0) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing x1, y1, x2, y2',
      });
    }
    final ok = await NativeBridge.a11ySwipe(x1, y1, x2, y2, duration);
    return NodeFrame.response('', payload: {'success': ok});
  }

  Future<NodeFrame> _input(Map<String, dynamic> params) async {
    final text = params['text'] as String? ?? '';
    final append = params['append'] as bool? ?? false;
    if (text.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing text',
      });
    }
    final ok = await NativeBridge.a11yInput(text, append: append);
    return NodeFrame.response('', payload: {'success': ok});
  }

  Future<NodeFrame> _key(Map<String, dynamic> params) async {
    final key = params['key'] as String? ?? '';
    if (key.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing key (back/home/recents/notifications)',
      });
    }
    final ok = await NativeBridge.a11yKey(key);
    return NodeFrame.response('', payload: {'success': ok, 'key': key});
  }

  Future<NodeFrame> _scroll(Map<String, dynamic> params) async {
    final direction = params['direction'] as String? ?? 'down';
    final ok = await NativeBridge.a11yScroll(direction);
    return NodeFrame.response(
        '', payload: {'success': ok, 'direction': direction});
  }

  Future<NodeFrame> _find(Map<String, dynamic> params) async {
    final text = params['text'] as String?;
    final id = params['id'] as String?;
    final desc = params['description'] as String?;
    final className = params['class_name'] as String?;
    final clickableOnly = params['clickable_only'] as bool? ?? false;

    if ((text == null || text.isEmpty) &&
        (id == null || id.isEmpty) &&
        (desc == null || desc.isEmpty)) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Provide at least one of: text, id, description',
      });
    }

    final nodes = await NativeBridge.a11yFind(
      text: text?.isNotEmpty == true ? text : null,
      id: id?.isNotEmpty == true ? id : null,
      description: desc?.isNotEmpty == true ? desc : null,
      className: className?.isNotEmpty == true ? className : null,
      clickableOnly: clickableOnly,
    );

    return NodeFrame.response('', payload: {
      'count': nodes.length,
      'nodes': nodes,
    });
  }

  Future<NodeFrame> _wait(Map<String, dynamic> params) async {
    final text = params['text'] as String?;
    final id = params['id'] as String?;
    final desc = params['description'] as String?;
    final timeout = params['timeout'] as int? ?? 5000;
    final pollInterval = params['poll_interval'] as int? ?? 300;

    if ((text == null || text.isEmpty) &&
        (id == null || id.isEmpty) &&
        (desc == null || desc.isEmpty)) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Provide at least one of: text, id, description',
      });
    }

    final found = await NativeBridge.a11yWait(
      text: text?.isNotEmpty == true ? text : null,
      id: id?.isNotEmpty == true ? id : null,
      description: desc?.isNotEmpty == true ? desc : null,
      timeout: timeout,
      pollInterval: pollInterval,
    );

    return NodeFrame.response('', payload: {
      'found': found,
      if (!found) 'error': 'Element not found after ${timeout}ms',
    });
  }

  Future<NodeFrame> _clickText(Map<String, dynamic> params) async {
    final text = params['text'] as String? ?? '';
    if (text.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing text',
      });
    }
    final ok = await NativeBridge.a11yClickText(text);
    return NodeFrame.response(
        '', payload: {'success': ok, 'text': text, 'found': ok});
  }

  Future<NodeFrame> _clickId(Map<String, dynamic> params) async {
    final id = params['id'] as String? ?? '';
    if (id.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing id',
      });
    }
    final ok = await NativeBridge.a11yClickId(id);
    return NodeFrame.response(
        '', payload: {'success': ok, 'id': id, 'found': ok});
  }

  Future<NodeFrame> _screenshot(Map<String, dynamic> params) async {
    final b64 = await NativeBridge.a11yScreenshot();
    if (b64 == null || b64.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'SCREENSHOT_FAILED',
        'message': 'Screenshot failed (requires Android 11+)',
      });
    }
    return NodeFrame.response('', payload: {
      'base64': b64,
      'format': 'jpeg',
    });
  }

  Future<NodeFrame> _uiTree(Map<String, dynamic> params) async {
    final xml = await NativeBridge.a11yDumpTree();
    return NodeFrame.response('', payload: {'xml': xml});
  }

  Future<NodeFrame> _currentApp(Map<String, dynamic> params) async {
    final app = await NativeBridge.a11yCurrentApp();
    return NodeFrame.response('', payload: app);
  }

  Future<NodeFrame> _deviceInfo(Map<String, dynamic> params) async {
    final info = await NativeBridge.a11yDeviceInfo();
    return NodeFrame.response('', payload: info);
  }

  Future<NodeFrame> _clipboardRead(Map<String, dynamic> params) async {
    final text = await NativeBridge.a11yClipboardRead();
    return NodeFrame.response('', payload: {
      'text': text,
      'has_content': text.isNotEmpty,
    });
  }

  Future<NodeFrame> _clipboardWrite(Map<String, dynamic> params) async {
    final text = params['text'] as String? ?? '';
    if (text.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing text',
      });
    }
    final ok = await NativeBridge.a11yClipboardWrite(text);
    return NodeFrame.response('', payload: {'success': ok});
  }

  Future<NodeFrame> _volume(Map<String, dynamic> params) async {
    final stream = params['stream'] as String?;
    final level = params['level'] as int?;

    if (stream == null && level == null) {
      // 获取所有音量信息
      final info = await NativeBridge.a11yVolume();
      return NodeFrame.response('', payload: {'volumes': info});
    } else if (stream != null && level != null) {
      final ok = await NativeBridge.a11yVolume(stream: stream, level: level);
      return NodeFrame.response(
          '', payload: {'success': ok, 'stream': stream, 'level': level});
    } else {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': "Provide both 'stream' and 'level' to set, or neither to get",
      });
    }
  }

  Future<NodeFrame> _color(Map<String, dynamic> params) async {
    final x = params['x'] as int? ?? -1;
    final y = params['y'] as int? ?? -1;
    if (x < 0 || y < 0) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing x, y',
      });
    }
    final color = await NativeBridge.a11yColor(x, y);
    if (color == null || color.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'COLOR_FAILED',
        'message': 'Failed to get pixel color (requires Android 11+)',
      });
    }
    return NodeFrame.response(
        '', payload: {'color': color, 'x': x, 'y': y});
  }

  Future<NodeFrame> _installedApps(Map<String, dynamic> params) async {
    final apps = await NativeBridge.a11yInstalledApps();
    return NodeFrame.response('', payload: {
      'count': apps.length,
      'apps': apps,
    });
  }

  Future<NodeFrame> _launchApp(Map<String, dynamic> params) async {
    final pkg = params['package'] as String? ?? '';
    if (pkg.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing package name',
      });
    }
    final ok = await NativeBridge.a11yLaunchApp(
      pkg,
      action: params['action'] as String?,
      uri: params['uri'] as String?,
      type: params['type'] as String?,
    );
    return NodeFrame.response('', payload: {'success': ok, 'package': pkg});
  }

  Future<NodeFrame> _ocr(Map<String, dynamic> params) async {
    final json = await NativeBridge.a11yOcr();
    if (json == null || json.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'OCR_FAILED',
        'message': 'OCR failed (requires Android 11+ and ML Kit)',
      });
    }
    try {
      final blocks = jsonDecode(json) as List;
      return NodeFrame.response('', payload: {
        'blocks_count': blocks.length,
        'blocks': blocks,
      });
    } catch (e) {
      return NodeFrame.response('', payload: {
        'blocks_count': 0,
        'blocks': [],
        'raw': json,
      });
    }
  }

  Future<NodeFrame> _batch(Map<String, dynamic> params) async {
    final operations = params['operations'] as List?;
    final delayMs = params['delay_ms'] as int? ?? 100;

    if (operations == null || operations.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing operations array',
      });
    }

    final results = <Map<String, dynamic>>[];

    for (int i = 0; i < operations.length; i++) {
      final op = Map<String, dynamic>.from(operations[i] as Map);
      final action = op['action'] as String? ?? '';
      final startTime = DateTime.now().millisecondsSinceEpoch;

      NodeFrame result;
      switch (action) {
        case 'tap':
          result = await _tap(op);
          break;
        case 'swipe':
          result = await _swipe(op);
          break;
        case 'input':
          result = await _input(op);
          break;
        case 'click_text':
          result = await _clickText(op);
          break;
        case 'click_id':
          result = await _clickId(op);
          break;
        case 'scroll':
          result = await _scroll(op);
          break;
        case 'key':
          result = await _key(op);
          break;
        case 'wait':
          final ms = op['ms'] as int? ?? 1000;
          await Future.delayed(Duration(milliseconds: ms));
          result = NodeFrame.response('', payload: {'waited_ms': ms});
          break;
        case 'launch':
          result = await _launchApp(op);
          break;
        default:
          result = NodeFrame.response('', error: {
            'code': 'UNKNOWN_ACTION',
            'message': 'Unknown batch action: $action',
          });
      }

      final elapsed = DateTime.now().millisecondsSinceEpoch - startTime;
      results.add({
        'index': i,
        'action': action,
        'success': !result.isError,
        'elapsed_ms': elapsed,
        if (result.isError) 'error': result.error,
        if (!result.isError && result.payload != null)
          'payload': result.payload,
      });

      // 操作间延迟
      if (i < operations.length - 1 && delayMs > 0) {
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }

    return NodeFrame.response('', payload: {
      'total': operations.length,
      'results': results,
    });
  }

  // ==========================================================================
  // Toast
  // ==========================================================================

  Future<NodeFrame> _toast(Map<String, dynamic> params) async {
    final message = params['message'] as String? ?? '';
    if (message.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing message',
      });
    }
    final isLong = params['long'] as bool? ?? false;
    final ok = await NativeBridge.showToast(message, isLong: isLong);
    _logger.log('toast', details: message, success: ok);
    return NodeFrame.response('', payload: {'success': ok, 'message': message});
  }

  // ==========================================================================
  // JS Bridge
  // ==========================================================================

  Future<NodeFrame> _jsExec(Map<String, dynamic> params) async {
    final code = params['code'] as String? ?? '';
    final timeoutMs = params['timeout_ms'] as int? ?? 10000;
    if (code.isEmpty) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing code',
      });
    }

    // 检查 JS Bridge 是否启动
    final isRunning = await NativeBridge.isJsBridgeRunning();
    if (!isRunning) {
      // 自动启动
      await NativeBridge.startJsBridge();
    }

    // 检查浏览器客户端
    final info = await NativeBridge.jsBridgeInfo();
    final browserCount =
        int.tryParse(info['browser_clients']?.toString() ?? '0') ?? 0;
    if (browserCount == 0) {
      return NodeFrame.response('', error: {
        'code': 'NO_BROWSER_CLIENTS',
        'message':
            'No browser clients connected. Install the userscript and open a page.',
      });
    }

    _logger.log('js_exec',
        details: code.length > 80 ? '${code.substring(0, 80)}...' : code);

    try {
      final result =
          await NativeBridge.execJsOnBrowser(code, timeoutMs: timeoutMs);
      _logger.log('js_exec', details: 'ok', success: true);
      return NodeFrame.response('', payload: {
        'ok': true,
        'result': result,
      });
    } catch (e) {
      _logger.log('js_exec', details: '$e', success: false);
      return NodeFrame.response('', error: {
        'code': 'JS_EXEC_ERROR',
        'message': '$e',
      });
    }
  }

  Future<NodeFrame> _jsBridgeStart(Map<String, dynamic> params) async {
    final port = params['port'] as int? ?? 8767;
    try {
      await NativeBridge.startJsBridge(port: port);
      _logger.log('js_bridge_start', details: 'port=$port');
      return NodeFrame.response(
          '', payload: {'success': true, 'port': port});
    } catch (e) {
      return NodeFrame.response('', error: {
        'code': 'JS_BRIDGE_ERROR',
        'message': '$e',
      });
    }
  }

  Future<NodeFrame> _jsBridgeStop(Map<String, dynamic> params) async {
    try {
      await NativeBridge.stopJsBridge();
      _logger.log('js_bridge_stop');
      return NodeFrame.response('', payload: {'success': true});
    } catch (e) {
      return NodeFrame.response('', error: {
        'code': 'JS_BRIDGE_ERROR',
        'message': '$e',
      });
    }
  }

  Future<NodeFrame> _jsBridgeInfo(Map<String, dynamic> params) async {
    final info = await NativeBridge.jsBridgeInfo();
    return NodeFrame.response('', payload: info);
  }

  Future<NodeFrame> _jsBridgeUserscript(Map<String, dynamic> params) async {
    final serverIp = params['server_ip'] as String? ?? '127.0.0.1';
    final serverPort = params['server_port'] as int? ?? 8767;
    try {
      final script =
          await NativeBridge.getJsBridgeUserscript(serverIp, serverPort);
      return NodeFrame.response('', payload: {'script': script});
    } catch (e) {
      return NodeFrame.response('', error: {
        'code': 'JS_BRIDGE_ERROR',
        'message': '$e',
      });
    }
  }

  // ==========================================================================
  // Operation Logs
  // ==========================================================================

  Future<NodeFrame> _logs(Map<String, dynamic> params) async {
    final count = params['count'] as int? ?? 50;
    final fromFile = params['from_file'] as bool? ?? false;

    List<OperationLogEntry> entries;
    if (fromFile) {
      entries = await _logger.loadFromFile(limit: count);
    } else {
      entries = _logger.getRecent(count);
    }

    return NodeFrame.response('', payload: {
      'count': entries.length,
      'source': fromFile ? 'file' : 'memory',
      'logs': entries.map((e) => e.toJson()).toList(),
    });
  }

  Future<NodeFrame> _logsClear(Map<String, dynamic> params) async {
    _logger.clear();
    return NodeFrame.response('', payload: {'cleared': true});
  }

  /// 生成 payload 的简短摘要（用于日志）
  String _summarizePayload(Map<String, dynamic>? payload) {
    if (payload == null) return '';
    final keys = payload.keys.toList();
    if (keys.isEmpty) return '';

    // 特殊处理一些大 payload
    if (payload.containsKey('xml')) {
      final xml = payload['xml'] as String? ?? '';
      return 'xml=${xml.length}chars';
    }
    if (payload.containsKey('base64')) {
      return 'screenshot=${(payload['base64'] as String? ?? '').length}chars';
    }
    if (payload.containsKey('nodes')) {
      final nodes = payload['nodes'] as List? ?? [];
      return 'found=${nodes.length}';
    }
    if (payload.containsKey('blocks')) {
      final blocks = payload['blocks'] as List? ?? [];
      return 'blocks=${blocks.length}';
    }
    if (payload.containsKey('apps')) {
      final apps = payload['apps'] as List? ?? [];
      return 'apps=${apps.length}';
    }
    if (payload.containsKey('logs')) {
      final logs = payload['logs'] as List? ?? [];
      return 'logs=${logs.length}';
    }
    if (payload.containsKey('results')) {
      final results = payload['results'] as List? ?? [];
      return 'batch=${results.length}';
    }

    // 通用摘要
    final summary = keys.map((k) => '$k=${payload[k]}').join(',');
    return summary.length > 100 ? '${summary.substring(0, 100)}...' : summary;
  }
}
