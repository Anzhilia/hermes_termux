import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/node_frame.dart';

/// 轻量级命令 WebSocket 服务器（纯 dart:io，无外部依赖）
///
/// 监听指定端口，接受桥接器连接，直接处理简单 JSON 命令。
/// 协议：
///   桥接器发来: {"type": "camera.snap", "id": "xxx", "payload": {...}}
///   App 回复:   {"type": "response", "id": "xxx", "payload": {...}}
///   App 失败:   {"type": "error", "id": "xxx", "error": "..."}
///
/// v2: 支持 bridge.hello 消息，检测桥接器连接/断开
class CommandWsServer {
  HttpServer? _server;
  final _activeConnections = <WebSocket>[];
  final Map<String, Future<NodeFrame> Function(String, Map<String, dynamic>)>
      _handlers = {};

  /// 桥接器连接状态回调
  void Function(bool connected)? onBridgeConnectionChanged;

  bool get isRunning => _server != null;
  int get connectionCount => _activeConnections.length;

  /// 是否有桥接器连接（至少有一个 bridge.hello 过的连接）
  bool _hasBridgeConnection = false;
  bool get hasBridgeConnection => _hasBridgeConnection;

  /// 注册命令处理器。格式: {"camera.snap": handler, "location.get": handler, ...}
  void registerHandlers(
      Map<String, Future<NodeFrame> Function(String, Map<String, dynamic>)>
          handlers) {
    _handlers.addAll(handlers);
  }

  /// 启动 WebSocket 服务器
  Future<void> start({int port = 18790}) async {
    if (_server != null) return;

    // Fix #19: Bind to loopback only — the bridge script runs on the same
    // device. Binding to 0.0.0.0 would let any device on the LAN send
    // commands (camera.snap, location.get, etc.).
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);

    _server!.listen((HttpRequest request) async {
      if (request.uri.path == '/ws' || request.uri.path == '/') {
        try {
          final ws = await WebSocketTransformer.upgrade(request);
          _activeConnections.add(ws);
          _handleConnection(ws);
        } catch (e) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..write('WebSocket upgrade failed')
            ..close();
        }
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not found. Connect via ws://host:$port/ws')
          ..close();
      }
    });
  }

  /// 停止服务器
  Future<void> stop() async {
    for (final ws in _activeConnections) {
      await ws.close();
    }
    _activeConnections.clear();
    _hasBridgeConnection = false;
    await _server?.close(force: true);
    _server = null;
  }

  void _handleConnection(WebSocket ws) {
    ws.listen(
      (data) => _onMessage(ws, data),
      onDone: () {
        _activeConnections.remove(ws);
        // 连接断开，如果没有其他连接了，标记桥接器断开
        if (_activeConnections.isEmpty && _hasBridgeConnection) {
          _hasBridgeConnection = false;
          onBridgeConnectionChanged?.call(false);
        }
      },
      onError: (_) {
        _activeConnections.remove(ws);
        if (_activeConnections.isEmpty && _hasBridgeConnection) {
          _hasBridgeConnection = false;
          onBridgeConnectionChanged?.call(false);
        }
      },
    );
  }

  Future<void> _onMessage(WebSocket ws, dynamic data) async {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      _sendError(ws, '', 'INVALID_JSON', '消息格式错误');
      return;
    }

    final type = msg['type'] as String? ?? '';
    final id = msg['id'] as String? ?? '';
    final payload = msg['payload'] as Map<String, dynamic>? ?? {};

    if (type.isEmpty) {
      _sendError(ws, id, 'MISSING_FIELDS', '缺少 type');
      return;
    }

    // ★ 处理 bridge.hello — 桥接器上线通知
    if (type == 'bridge.hello') {
      _hasBridgeConnection = true;
      onBridgeConnectionChanged?.call(true);
      _sendResponse(ws, id, {'status': 'ok', 'message': 'Bridge connected'});
      return;
    }

    if (id.isEmpty) {
      _sendError(ws, id, 'MISSING_FIELDS', '缺少 id');
      return;
    }

    final handler = _handlers[type];
    if (handler == null) {
      _sendError(ws, id, 'UNKNOWN_COMMAND', '未知命令: $type');
      return;
    }

    try {
      final result = await handler(type, payload);
      if (result.isError) {
        _sendError(ws, id,
            result.error?['code'] ?? 'ERROR', result.error?['message'] ?? '未知错误');
      } else {
        _sendResponse(ws, id, result.payload ?? {});
      }
    } catch (e) {
      _sendError(ws, id, 'INVOKE_ERROR', '$e');
    }
  }

  void _sendResponse(WebSocket ws, String id, Map<String, dynamic> payload) {
    ws.add(jsonEncode({
      'type': 'response',
      'id': id,
      'payload': payload,
    }));
  }

  void _sendError(WebSocket ws, String id, String code, String message) {
    ws.add(jsonEncode({
      'type': 'error',
      'id': id,
      'error': message,
    }));
  }
}
