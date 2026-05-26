import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/gateway_state.dart';
import '../models/node_frame.dart';
import '../models/node_state.dart';
import '../services/capabilities/camera_capability.dart';
import '../services/capabilities/canvas_capability.dart';
import '../services/capabilities/flash_capability.dart';
import '../services/capabilities/location_capability.dart';
import '../services/capabilities/screen_capability.dart';
import '../services/capabilities/sensor_capability.dart';
import '../services/capabilities/serial_capability.dart';
import '../services/capabilities/vibration_capability.dart';
import '../services/native_bridge.dart';
import '../services/node_service.dart';
import '../services/preferences_service.dart';

/// 节点 Provider — App 作为 WS 客户端连接到 Hermes Gateway
///
/// 架构变更（移除旧的 bridge 模式）：
///   旧: App (WS Server :18790) ◄── Bridge (WS Client) ◄── Hermes (MCP)
///   新: Hermes Gateway (WS Server :18780) ◄── App (WS Client)
///
/// NodeService 已实现 OpenClaw Node Protocol v3：
///   connect.challenge → connect (签名认证) → node.invoke.request → node.invoke.result
class NodeProvider extends ChangeNotifier with WidgetsBindingObserver {
  final NodeService _nodeService = NodeService();
  StreamSubscription? _subscription;
  NodeState _state = const NodeState();
  GatewayState? _lastGatewayState;
  Timer? _watchdog;

  /// 当前 Gateway 状态（供 UI 展示）
  GatewayState? get gatewayState => _lastGatewayState;

  // Capabilities
  final _cameraCapability = CameraCapability();
  final _canvasCapability = CanvasCapability();
  final _flashCapability = FlashCapability();
  final _locationCapability = LocationCapability();
  final _screenCapability = ScreenCapability();
  final _sensorCapability = SensorCapability();
  final _serialCapability = SerialCapability();
  final _vibrationCapability = VibrationCapability();

  NodeState get state => _state;

  NodeProvider() {
    WidgetsBinding.instance.addObserver(this);
    _subscription = _nodeService.stateStream.listen((state) {
      _state = state;
      _updateServiceNotification(state);
      notifyListeners();
    });
    _registerCapabilities();
    _init();
  }

  /// Keep the foreground notification text in sync with the node status.
  void _updateServiceNotification(NodeState state) {
    if (state.isDisabled) return;
    String text;
    switch (state.status) {
      case NodeStatus.paired:
        text = 'Node connected';
        break;
      case NodeStatus.connecting:
      case NodeStatus.challenging:
      case NodeStatus.pairing:
        text = 'Node connecting...';
        break;
      case NodeStatus.disconnected:
        text = 'Node reconnecting...';
        break;
      case NodeStatus.error:
        text = 'Node error — retrying';
        break;
      default:
        return;
    }
    try {
      NativeBridge.updateNodeNotification(text);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _nodeService.setAppInForeground(true);
    } else if (state == AppLifecycleState.paused) {
      _nodeService.setAppInForeground(false);
    }
  }

  void _registerCapabilities() {
    void registerOne(
      dynamic capability,
      Future<NodeFrame> Function(String, Map<String, dynamic>) handler,
    ) {
      final cap = capability;
      final commands = cap.commands.map<String>((c) => '${cap.name}.$c').toList();
      _nodeService.registerCapability(cap.name, commands, handler);
    }

    registerOne(_cameraCapability,
        (cmd, params) => _cameraCapability.handleWithPermission(cmd, params));
    registerOne(_canvasCapability,
        (cmd, params) => _canvasCapability.handle(cmd, params));
    registerOne(_locationCapability,
        (cmd, params) => _locationCapability.handleWithPermission(cmd, params));
    registerOne(_screenCapability,
        (cmd, params) => _screenCapability.handle(cmd, params));
    registerOne(_flashCapability,
        (cmd, params) => _flashCapability.handleWithPermission(cmd, params));
    registerOne(_vibrationCapability,
        (cmd, params) => _vibrationCapability.handle(cmd, params));
    registerOne(_sensorCapability,
        (cmd, params) => _sensorCapability.handleWithPermission(cmd, params));
    registerOne(_serialCapability,
        (cmd, params) => _serialCapability.handleWithPermission(cmd, params));
  }

  Future<void> _init() async {
    await _nodeService.init();
    final prefs = PreferencesService();
    await prefs.init();
    if (prefs.nodeEnabled) {
      await _requestNodePermissions();
      await _requestBatteryOptimization();
      // ★ 不再自动连接，等用户手动点击"启用节点"
      // 恢复 UI 状态为已启用但未连接
      _nodeService.updateStateForEnable();
      _startWatchdog();
    }
  }

  /// 连接到 Hermes Gateway（本地或远程）
  Future<void> _connectToGateway() async {
    final prefs = PreferencesService();
    await prefs.init();
    final host = prefs.nodeGatewayHost ?? '127.0.0.1';
    final port = prefs.nodeGatewayPort ?? 18780;
    await _nodeService.connect(host: host, port: port);
  }

  void onGatewayStateChanged(GatewayState gatewayState) {
    final wasRunning = _lastGatewayState?.isRunning ?? false;
    _lastGatewayState = gatewayState;

    // ★ 随网关自动连接/断开
    _handleAutoConnectWithGateway(gatewayState, wasRunning);

    notifyListeners();
  }

  /// 随网关状态自动连接/断开节点
  Future<void> _handleAutoConnectWithGateway(
      GatewayState gatewayState, bool wasRunning) async {
    final prefs = PreferencesService();
    await prefs.init();

    // 仅在"随网关自动连接"开启 + 节点已启用时生效
    if (!prefs.nodeAutoConnectWithGateway || !prefs.nodeEnabled) return;

    final isNowRunning = gatewayState.isRunning;

    // 网关刚启动 → 自动连接节点
    if (isNowRunning && !wasRunning) {
      await _connectToGateway();
      return;
    }

    // 网关刚停止 → 自动断开节点
    if (!isNowRunning && wasRunning) {
      await _nodeService.disconnect();
    }
  }

  Future<void> _requestNodePermissions() async {
    await [
      Permission.camera,
      Permission.location,
      Permission.sensors,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();
  }

  Future<void> _requestBatteryOptimization() async {
    try {
      final optimized = await NativeBridge.isBatteryOptimized();
      if (optimized) {
        await NativeBridge.requestBatteryOptimization();
      }
    } catch (_) {}
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 45), (_) async {
      if (_state.isDisabled) return;
      // 如果连接断开，尝试重连
      if (!_nodeService.isConnectionStale &&
          _state.status == NodeStatus.disconnected) {
        await _connectToGateway();
      }
    });
  }

  void _stopWatchdog() {
    _watchdog?.cancel();
    _watchdog = null;
  }

  /// 启用节点：连接到 Hermes Gateway
  Future<void> enable() async {
    final prefs = PreferencesService();
    await prefs.init();
    prefs.nodeEnabled = true;
    await _requestNodePermissions();
    await _requestBatteryOptimization();

    _nodeService.updateStateForEnable();
    _startWatchdog();

    // 连接到 Gateway
    await _connectToGateway();
  }

  Future<void> disable() async {
    final prefs = PreferencesService();
    await prefs.init();
    prefs.nodeEnabled = false;
    _stopWatchdog();
    await _nodeService.disable();
    await NativeBridge.stopNodeService();
  }

  /// 连接到远程 Gateway
  Future<void> connectRemote(String host, int port, {String? token}) async {
    final prefs = PreferencesService();
    await prefs.init();
    prefs.nodeGatewayHost = host;
    prefs.nodeGatewayPort = port;
    if (token != null && token.isNotEmpty) {
      prefs.nodeGatewayToken = token;
    }
    await enable();
  }

  Future<void> reconnect() async {
    await _nodeService.disconnect();
    await _connectToGateway();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopWatchdog();
    _subscription?.cancel();
    _nodeService.dispose();
    _cameraCapability.dispose();
    _flashCapability.dispose();
    _serialCapability.dispose();
    NativeBridge.stopNodeService();
    super.dispose();
  }
}
