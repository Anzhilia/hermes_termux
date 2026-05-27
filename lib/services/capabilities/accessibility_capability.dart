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
        'help',
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
        // JS 命令已移除 — 由浏览器节点直接处理
        // 'js_exec',
        // 'js_bridge_start',
        // 'js_bridge_stop',
        // 'js_bridge_info',
        // 'js_bridge_userscript',
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
    // help 命令不需要无障碍服务运行
    if (command == 'accessibility.help') {
      final topic = params['topic'] as String?;
      return _help(topic);
    }

    // 检查无障碍服务是否连接
    final isRunning = await NativeBridge.isAccessibilityServiceRunning();
    if (!isRunning) {
      return NodeFrame.response('', error: {
        'code': 'A11Y_NOT_RUNNING',
        'message':
            'Accessibility service not connected. Enable it first:\n'
            'Android Settings > Accessibility > Hermes Agent > ON\n\n'
            'Then run: accessibility.help { "topic": "quickstart" }',
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
          // 未知命令：返回 help 提示 + 最接近的建议
          final suggestion = _suggestCommand(command);
          result = NodeFrame.response('', error: {
            'code': 'UNKNOWN_COMMAND',
            'message': 'Unknown command: $command\n'
                '${suggestion != null ? "Did you mean: $suggestion?\n" : ""}'
                'Run "accessibility.help" to see all available commands.',
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
        'message': 'Missing or invalid x, y coordinates.\n'
            'Usage: accessibility.tap { "x": 540, "y": 1200 }\n'
            'Tip: prefer click_text over raw coordinates. '
            'Run accessibility.help { "topic": "tap" } for details.',
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
        'message': 'Missing x1, y1, x2, y2.\n'
            'Usage: accessibility.swipe { "x1": 540, "y1": 1800, "x2": 540, "y2": 400, "duration": 300 }',
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
        'message': 'Missing text.\n'
            'Usage: accessibility.input { "text": "Hello World" }\n'
            'Tip: tap the input field first, then call input.',
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
        'message': 'Missing key.\n'
            'Usage: accessibility.key { "key": "back" }\n'
            'Valid keys: back, home, recents, notifications',
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
        'message': 'Provide at least one of: text, id, description.\n'
            'Usage: accessibility.find { "text": "Login" }\n'
            '       accessibility.find { "id": "com.example:id/btn" }\n'
            'Run accessibility.help { "topic": "find" } for details.',
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
        'message': 'Provide at least one of: text, id, description.\n'
            'Usage: accessibility.wait { "text": "Welcome", "timeout": 5000 }',
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
        'message': 'Missing text.\n'
            'Usage: accessibility.click_text { "text": "Login" }',
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
        'message': 'Missing id.\n'
            'Usage: accessibility.click_id { "id": "com.example:id/btn" }',
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
        'message': 'Missing text.\n'
            'Usage: accessibility.clipboard_write { "text": "Hello" }',
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
        'message': "Provide both 'stream' and 'level' to set, or neither to get.\n"
            'Get:  accessibility.volume {}\n'
            'Set:  accessibility.volume { "stream": "music", "level": 8 }',
      });
    }
  }

  Future<NodeFrame> _color(Map<String, dynamic> params) async {
    final x = params['x'] as int? ?? -1;
    final y = params['y'] as int? ?? -1;
    if (x < 0 || y < 0) {
      return NodeFrame.response('', error: {
        'code': 'INVALID_ARGS',
        'message': 'Missing x, y.\n'
            'Usage: accessibility.color { "x": 100, "y": 200 }',
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
        'message': 'Missing package name.\n'
            'Usage: accessibility.launch_app { "package": "com.tencent.mm" }\n'
            'Tip: use accessibility.installed_apps to find package names.',
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
        'message': 'Missing operations array.\n'
            'Usage: accessibility.batch {\n'
            '  "operations": [\n'
            '    {"action": "click_text", "text": "搜索"},\n'
            '    {"action": "wait", "ms": 500},\n'
            '    {"action": "input", "text": "hello"}\n'
            '  ]\n'
            '}\n'
            'Actions: tap, swipe, input, click_text, click_id, scroll, key, wait, launch',
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
        'message': 'Missing message.\n'
            'Usage: accessibility.toast { "message": "Done!", "long": false }',
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
        'message': 'Missing code.\n'
            'Usage: accessibility.js_exec { "code": "document.title" }',
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
        'message': 'No browser clients connected.\n'
            'Setup steps:\n'
            '1. accessibility.js_bridge_start { "port": 8767 }\n'
            '2. accessibility.js_bridge_userscript { "server_ip": "<phone_ip>" }\n'
            '3. Install userscript in Tampermonkey\n'
            '4. Open any webpage — wait for "Hermes: connected" badge',
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

  // ==========================================================================
  // Help System — 教 AI agent 如何使用无障碍能力
  // ==========================================================================

  /// 未知命令时，返回最接近的建议
  String? _suggestCommand(String unknown) {
    // 去掉前缀 "accessibility."
    final input = unknown.replaceFirst('accessibility.', '').toLowerCase();
    final allCommands = commands.where((c) => c != 'help').toList();

    // 简单编辑距离匹配
    String? best;
    int bestDist = 999;
    for (final cmd in allCommands) {
      final dist = _levenshtein(input, cmd);
      if (dist < bestDist && dist <= 3) {
        bestDist = dist;
        best = 'accessibility.$cmd';
      }
    }
    return best;
  }

  int _levenshtein(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final matrix = List.generate(
      a.length + 1,
      (i) => List.generate(b.length + 1, (j) => 0),
    );
    for (int i = 0; i <= a.length; i++) matrix[i][0] = i;
    for (int j = 0; j <= b.length; j++) matrix[0][j] = j;
    for (int i = 1; i <= a.length; i++) {
      for (int j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        matrix[i][j] = [
          matrix[i - 1][j] + 1,
          matrix[i][j - 1] + 1,
          matrix[i - 1][j - 1] + cost,
        ].reduce((a, b) => a < b ? a : b);
      }
    }
    return matrix[a.length][b.length];
  }

  Future<NodeFrame> _help(String? topic) async {
    final t = topic?.toLowerCase() ?? 'index';

    String content;
    switch (t) {
      case 'quickstart':
        content = _helpQuickstart();
        break;
      case 'tap':
      case 'click':
        content = _helpTap();
        break;
      case 'swipe':
        content = _helpSwipe();
        break;
      case 'input':
      case 'type':
      case 'text':
        content = _helpInput();
        break;
      case 'find':
      case 'search':
      case 'element':
        content = _helpFind();
        break;
      case 'scroll':
        content = _helpScroll();
        break;
      case 'key':
      case 'keys':
      case 'global':
        content = _helpKey();
        break;
      case 'screenshot':
      case 'screen':
        content = _helpScreenshot();
        break;
      case 'tree':
      case 'ui_tree':
      case 'uitree':
        content = _helpUiTree();
        break;
      case 'ocr':
        content = _helpOcr();
        break;
      case 'batch':
        content = _helpBatch();
        break;
      case 'app':
      case 'current_app':
      case 'launch':
        content = _helpApp();
        break;
      case 'js':
      case 'jsbridge':
      case 'js_bridge':
        content = _helpJsBridge();
        break;
      default:
        content = _helpIndex();
    }

    return NodeFrame.response('', payload: {
      'topic': t,
      'content': content,
    });
  }

  String _helpIndex() => '''
=== Accessibility Help ===

Run: accessibility.help { "topic": "<topic>" }

Topics:
  quickstart  — 上手指南（必读）
  tap         — 坐标点击
  swipe       — 滑动手势
  input       — 文本输入
  find        — 查找 UI 元素
  scroll      — 滚动
  key         — 全局按键（返回/主页/最近任务）
  screenshot  — 截图
  ui_tree     — 获取 UI 树结构
  ocr         — OCR 文字识别
  batch       — 批量操作
  app         — 当前 App / 启动 App
  js_bridge   — 浏览器 JS 注入

Commands (all prefixed with "accessibility."):
  help, tap, swipe, input, key, scroll, find, wait,
  click_text, click_id, screenshot, ui_tree, current_app,
  device_info, clipboard_read, clipboard_write, volume,
  color, installed_apps, launch_app, ocr, batch, toast,
  js_exec, js_bridge_start, js_bridge_stop, js_bridge_info,
  js_bridge_userscript, logs, logs_clear
''';

  String _helpQuickstart() => '''
=== Quickstart Guide ===

1. Check service status:
   → accessibility.current_app {}

2. See what's on screen:
   → accessibility.ui_tree {}       ← returns XML tree
   → accessibility.screenshot {}    ← returns base64 JPEG

3. Find and tap an element:
   → accessibility.find { "text": "Settings" }
   → accessibility.click_text { "text": "Settings" }

4. Wait for an element to appear:
   → accessibility.wait { "text": "Loading...", "timeout": 5000 }

5. Type text into a field:
   → accessibility.input { "text": "Hello World" }

6. Navigate:
   → accessibility.key { "key": "back" }
   → accessibility.key { "key": "home" }
   → accessibility.scroll { "direction": "down" }

7. Batch multiple actions:
   → accessibility.batch {
       "operations": [
         {"action": "tap", "x": 540, "y": 1200},
         {"action": "wait", "ms": 500},
         {"action": "input", "text": "hello"}
       ]
     }

Best Practice:
  ★ ALWAYS call ui_tree or find FIRST to understand the screen
  ★ Use click_text/find with text/id instead of raw coordinates
  ★ Use wait after actions that trigger page transitions
  ★ Use batch for multi-step workflows (faster than individual calls)
''';

  String _helpTap() => '''
=== accessibility.tap ===

Tap at screen coordinates.

Params:
  x (int, required) — X coordinate
  y (int, required) — Y coordinate

Example:
  → accessibility.tap { "x": 540, "y": 1200 }

Better approach — use click_text instead of raw coordinates:
  → accessibility.click_text { "text": "OK" }
  → accessibility.click_id { "id": "com.example:id/btn_submit" }
''';

  String _helpSwipe() => '''
=== accessibility.swipe ===

Swipe gesture from (x1,y1) to (x2,y2).

Params:
  x1, y1 (int, required) — start point
  x2, y2 (int, required) — end point
  duration (int, optional) — ms, default 300

Example:
  → accessibility.swipe { "x1": 540, "y1": 1800, "x2": 540, "y2": 400, "duration": 300 }
''';

  String _helpInput() => '''
=== accessibility.input ===

Type text into the currently focused input field.

Params:
  text (string, required) — text to type
  append (bool, optional) — append instead of replace, default false

Workflow:
  1. Tap the input field first:
     → accessibility.tap { "x": 300, "y": 500 }
  2. Then type:
     → accessibility.input { "text": "Hello" }

Or use find + click to focus, then input.
''';

  String _helpFind() => '''
=== accessibility.find ===

Find UI elements on screen. Provide at least one of: text, id, description.

Params:
  text (string) — match by visible text (partial match OK)
  id (string) — match by resource-id (exact)
  description (string) — match by content-description
  class_name (string) — filter by class
  clickable_only (bool) — only return clickable elements

Example:
  → accessibility.find { "text": "Login" }
  → accessibility.find { "id": "com.example:id/input_email" }

Returns: { "count": N, "nodes": [...] }
Each node: { text, resource_id, content_desc, class, bounds, clickable, ... }

=== accessibility.wait ===

Wait for an element to appear (polls repeatedly).

Params: same as find + timeout (int, ms, default 5000) + poll_interval (int, ms, default 300)

Example:
  → accessibility.wait { "text": "Welcome", "timeout": 10000 }

Returns: { "found": true/false, "node": {...} }
''';

  String _helpScroll() => '''
=== accessibility.scroll ===

Scroll the screen.

Params:
  direction (string) — "up" | "down" | "left" | "right"

Example:
  → accessibility.scroll { "direction": "down" }
''';

  String _helpKey() => '''
=== accessibility.key ===

Press a global navigation key.

Params:
  key (string) — "back" | "home" | "recents" | "notifications"

Example:
  → accessibility.key { "key": "back" }
  → accessibility.key { "key": "home" }
''';

  String _helpScreenshot() => '''
=== accessibility.screenshot ===

Take a screenshot. Returns base64-encoded JPEG.

No params required.
Example:
  → accessibility.screenshot {}

Returns: { "base64": "/9j/4AAQ...", "format": "jpeg" }
Requires Android 11+.
''';

  String _helpUiTree() => '''
=== accessibility.ui_tree ===

Dump the current screen's UI tree as XML.

No params required.
Example:
  → accessibility.ui_tree {}

Returns: { "xml": "<?xml ..." }

★ This is the MOST IMPORTANT command. Always use it first to understand the screen structure before tapping/finding elements.
''';

  String _helpOcr() => '''
=== accessibility.ocr ===

Screenshot + ML Kit OCR. Recognizes Chinese + English text.

No params required.
Example:
  → accessibility.ocr {}

Returns: { "blocks_count": N, "blocks": [...] }
Each block has text and bounding box.

Use this when ui_tree can't see text (e.g., Canvas, WebView, images).
''';

  String _helpBatch() => '''
=== accessibility.batch ===

Execute multiple actions in sequence.

Params:
  operations (array, required) — list of actions
  delay_ms (int, optional) — delay between actions, default 100

Each operation: { "action": "<action>", ...params }
Actions: tap, swipe, input, click_text, click_id, scroll, key, wait, launch

Example:
  → accessibility.batch {
      "delay_ms": 200,
      "operations": [
        {"action": "click_text", "text": "搜索"},
        {"action": "wait", "ms": 500},
        {"action": "input", "text": "张三"},
        {"action": "key", "key": "enter"}
      ]
    }
''';

  String _helpApp() => '''
=== accessibility.current_app ===

Get the current foreground app info.
No params. Returns: { "package_name", "app_name", "activity" }

=== accessibility.launch_app ===

Launch an app by package name.

Params:
  package (string, required) — e.g. "com.tencent.mm" (WeChat)
  action (string, optional) — Intent action
  uri (string, optional) — Intent data URI
  type (string, optional) — MIME type

Example:
  → accessibility.launch_app { "package": "com.tencent.mm" }

=== accessibility.installed_apps ===

List installed apps. No params.
Returns: { "count": N, "apps": [{ "package_name", "app_name" }] }
''';

  String _helpJsBridge() => '''
=== JS Bridge — 浏览器 JS 注入 ===

Execute JavaScript in a connected browser via WebSocket.

Setup:
  1. Start bridge:  accessibility.js_bridge_start { "port": 8767 }
  2. Get userscript: accessibility.js_bridge_userscript { "server_ip": "<phone_ip>" }
  3. Install userscript in phone browser (Tampermonkey)
  4. Open any webpage — green "Hermes: connected" badge appears

Execute JS:
  → accessibility.js_exec { "code": "document.title" }
  → accessibility.js_exec { "code": "document.querySelector('#btn').click()" }

Check status:
  → accessibility.js_bridge_info {}

Stop:
  → accessibility.js_bridge_stop {}
''';
}
