import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:yaml/yaml.dart';
import 'native_bridge.dart';

/// 节点服务 — 部署 MCP 适配器脚本 + 配置 Gateway 的节点 WS Server
///
/// 架构:
///   Hermes Gateway (WS Server :18780) ◄── App (WS Client)
///
/// 本服务负责：
///   1. 从 assets 部署 node_mcp_adapter.py 到 rootfs
///   2. 在 config.yaml 写入 MCP 配置（让 Hermes 能调用节点工具）
///   3. 通过 NativeBridge 启动/停止 WS Server（持久化进程）
class PhoneBridgeService {
  static const _adapterAssetPath = 'assets/scripts/node_mcp_adapter.py';
  static const _adapterInstallPath = '/root/.hermes/scripts/node_mcp_adapter.py';
  static const _wsServerAssetPath = 'assets/scripts/node_ws_server.py';
  static const _wsServerInstallPath = '/root/.hermes/scripts/node_ws_server.py';
  static const _configPath = '/root/.hermes/config.yaml';
  static const _nodeWsPort = 18780;

  /// 检查节点服务是否就绪
  static Future<bool> isReady() async {
    try {
      return await NativeBridge.isNodeWsServerRunning();
    } catch (_) {
      return false;
    }
  }

  /// 部署脚本 + 写入配置（在 Gateway 启动前调用）
  static Future<void> setupNodeMcp() async {
    try {
      await _deployScript(_adapterAssetPath, _adapterInstallPath);
      await _deployScript(_wsServerAssetPath, _wsServerInstallPath);
      await _ensureNodeMcpConfig();
    } catch (_) {
      // 非致命错误，节点功能可能不可用
    }
  }

  /// 启动节点 WS Server
  /// ★ WS Server 现在由 GatewayService 在 Gateway 进程内启动（nohup + &），
  /// 与 hermes gateway run 共享同一个 proot 进程树，不再需要单独启动。
  static Future<bool> startNodeWsServer() async {
    // No-op: WS server starts inside the gateway process.
    // GatewayService.start() will launch it before hermes gateway run.
    return true;
  }

  /// 停止节点 WS Server
  static Future<void> stopNodeWsServer() async {
    try {
      await NativeBridge.stopNodeWsServer();
    } catch (_) {}
  }

  /// 从 assets 部署脚本到 rootfs
  static Future<void> _deployScript(String assetPath, String installPath) async {
    final scriptContent = await rootBundle.loadString(assetPath);
    await NativeBridge.writeRootfsFile(
      installPath.replaceFirst('/root/', 'root/'),
      scriptContent,
    );
  }

  /// 确保 config.yaml 中有 node_mcp 的 MCP 配置
  static Future<void> _ensureNodeMcpConfig() async {
    final rootfsPath = _configPath.replaceFirst('/root/', 'root/');
    final existing = await NativeBridge.readRootfsFile(rootfsPath);

    // 解析现有配置
    Map<String, dynamic> config = {};
    if (existing != null && existing.trim().isNotEmpty) {
      try {
        final yaml = _parseYaml(existing);
        if (yaml != null) config = yaml;
      } catch (_) {}
    }

    // 检查是否已有 node_mcp_adapter 配置
    final mcpServers = config['mcp_servers'] as Map<String, dynamic>? ?? {};
    if (mcpServers.containsKey('node_mcp_adapter')) {
      // 已有配置，检查是否需要更新 timeout
      final existingConfig = mcpServers['node_mcp_adapter'];
      if (existingConfig is Map<String, dynamic>) {
        final currentTimeout = existingConfig['timeout'];
        // 如果 timeout 小于 120，更新它（兼容旧版本）
        if (currentTimeout is int && currentTimeout < 120) {
          existingConfig['timeout'] = 120;
          config['mcp_servers'] = mcpServers;
          await NativeBridge.writeRootfsFile(rootfsPath, _toYamlString(config));
        }
      }
      return;
    }

    // 添加 node_mcp_adapter MCP 配置
    mcpServers['node_mcp_adapter'] = <String, dynamic>{
      // ★ 使用 venv Python，websockets 依赖装在 venv 里
      'command': '/root/.hermes/hermes-agent/venv/bin/python',
      'args': <String>[_adapterInstallPath],
      'env': <String, dynamic>{
        'NODE_WS_URL': 'ws://127.0.0.1:$_nodeWsPort',
        // adapter 内部会先等端口就绪再连接
        'NODE_PORT_WAIT_TIMEOUT': '90',
      },
      // ★ 增加超时：adapter 需要等待 WS server 启动 + 端口就绪
      'timeout': 120,
    };
    config['mcp_servers'] = mcpServers;

    await NativeBridge.writeRootfsFile(rootfsPath, _toYamlString(config));
  }

  /// 解析 YAML 字符串为 Map
  static Map<String, dynamic>? _parseYaml(String content) {
    if (content.trim().isEmpty) return null;
    try {
      final doc = loadYaml(content);
      if (doc is YamlMap) {
        return _convertYamlMap(doc);
      }
    } catch (_) {}
    return null;
  }

  /// YamlMap → Map 递归转换
  static Map<String, dynamic> _convertYamlMap(YamlMap yamlMap) {
    final result = <String, dynamic>{};
    for (final entry in yamlMap.entries) {
      final key = entry.key.toString();
      if (entry.value is YamlMap) {
        result[key] = _convertYamlMap(entry.value as YamlMap);
      } else if (entry.value is YamlList) {
        result[key] = (entry.value as YamlList).map((item) {
          if (item is YamlMap) return _convertYamlMap(item);
          return item;
        }).toList();
      } else {
        result[key] = entry.value;
      }
    }
    return result;
  }

  /// Map → YAML 字符串
  static String _toYamlString(Map<String, dynamic> config, {int indent = 0}) {
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
          buffer.write(_toYamlString(value, indent: indent + 1));
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
                buffer.writeln('$prefix    ${e.key}: ${_yamlValue(e.value)}');
              }
            } else {
              buffer.writeln('$prefix  - ${_yamlValue(item)}');
            }
          }
        }
      } else {
        buffer.writeln('$prefix$key: ${_yamlValue(value)}');
      }
    }
    return buffer.toString();
  }

  static String _yamlValue(dynamic value) {
    if (value == null) return '';
    if (value is String) {
      if (value.contains('\n') ||
          value.startsWith('{') ||
          value.startsWith('[') ||
          value == 'true' ||
          value == 'false' ||
          value == 'null' ||
          RegExp(r'^\d+$').hasMatch(value)) {
        return '"${value.replaceAll('"', '\\"')}"';
      }
      if (value.contains(': ')) {
        return '"${value.replaceAll('"', '\\"')}"';
      }
      return value;
    }
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) return value.toString();
    return value.toString();
  }
}
