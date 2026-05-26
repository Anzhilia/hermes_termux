import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import '../services/native_bridge.dart';

/// 无障碍服务管理页
///
/// 展示无障碍服务状态、引导用户开启权限、提供快捷测试操作。
class AccessibilityScreen extends StatefulWidget {
  const AccessibilityScreen({super.key});

  @override
  State<AccessibilityScreen> createState() => _AccessibilityScreenState();
}

class _AccessibilityScreenState extends State<AccessibilityScreen> {
  bool _isRunning = false;
  bool _loading = true;
  String? _currentApp;
  Map<String, dynamic>? _deviceInfo;
  final List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    setState(() => _loading = true);
    try {
      final running = await NativeBridge.isAccessibilityServiceRunning();
      setState(() => _isRunning = running);

      if (running) {
        await _loadDeviceInfo();
        await _loadCurrentApp();
      }
    } catch (e) {
      _addLog('Error checking status: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadDeviceInfo() async {
    try {
      final info = await NativeBridge.a11yDeviceInfo();
      setState(() => _deviceInfo = info);
    } catch (e) {
      _addLog('Error loading device info: $e');
    }
  }

  Future<void> _loadCurrentApp() async {
    try {
      final app = await NativeBridge.a11yCurrentApp();
      setState(() {
        _currentApp = app['app_name']?.toString() ??
            app['package_name']?.toString() ??
            'Unknown';
      });
    } catch (e) {
      setState(() => _currentApp = 'Unable to determine');
    }
  }

  void _addLog(String message) {
    final ts = DateTime.now().toString().substring(11, 19);
    setState(() {
      _logs.insert(0, '[$ts] $message');
      if (_logs.length > 100) _logs.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(
        title: const Text('无障碍服务'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新状态',
            onPressed: _checkStatus,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── 状态卡片 ──
                _buildStatusCard(theme),
                const SizedBox(height: 16),

                // ── 开启引导 ──
                if (!_isRunning) ...[
                  _buildSetupGuide(theme),
                  const SizedBox(height: 16),
                ],

                // ── 设备信息 ──
                if (_isRunning && _deviceInfo != null) ...[
                  _buildDeviceInfoCard(theme),
                  const SizedBox(height: 16),
                ],

                // ── 快捷操作 ──
                if (_isRunning) ...[
                  _buildQuickActions(theme),
                  const SizedBox(height: 16),
                ],

                // ── 日志 ──
                _buildLogSection(theme),
              ],
            ),
    );
  }

  Widget _buildStatusCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              _isRunning ? Icons.check_circle : Icons.error_outline,
              color: _isRunning ? Colors.green : Colors.orange,
              size: 40,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isRunning ? '服务已连接' : '服务未开启',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isRunning
                        ? '无障碍服务正在运行，UI 自动化功能可用'
                        : '需要在系统设置中开启无障碍服务',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (_isRunning && _currentApp != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '当前 App: $_currentApp',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSetupGuide(ThemeData theme) {
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.settings_accessibility,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  '开启步骤',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _stepItem(theme, '1', '点击下方按钮打开系统无障碍设置'),
            _stepItem(theme, '2', '找到 "Hermes Agent" 并点击进入'),
            _stepItem(theme, '3', '开启无障碍服务开关'),
            _stepItem(theme, '4', '在弹出的权限对话框中点击"允许"'),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  await NativeBridge.openAccessibilitySettings();
                  _addLog('Opened accessibility settings');
                },
                icon: const Icon(Icons.open_in_new),
                label: const Text('打开无障碍设置'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepItem(ThemeData theme, String number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: TextStyle(
                  color: theme.colorScheme.onPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceInfoCard(ThemeData theme) {
    final info = _deviceInfo!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('设备信息', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            _infoRow('型号', '${info['model']}'),
            _infoRow('品牌', '${info['brand']}'),
            _infoRow('Android', '${info['android_version']}'),
            _infoRow('屏幕', '${info['screen_width']}×${info['screen_height']}'),
            _infoRow('电量', '${info['battery_level']}%'),
            _infoRow('网络', '${info['network_type']}'),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('快捷测试', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _actionChip('返回', Icons.arrow_back, () async {
                  final ok = await NativeBridge.a11yKey('back');
                  _addLog('Press back: $ok');
                }),
                _actionChip('主页', Icons.home, () async {
                  final ok = await NativeBridge.a11yKey('home');
                  _addLog('Press home: $ok');
                }),
                _actionChip('最近任务', Icons.apps, () async {
                  final ok = await NativeBridge.a11yKey('recents');
                  _addLog('Press recents: $ok');
                }),
                _actionChip('截图', Icons.camera, () async {
                  _addLog('Taking screenshot...');
                  final b64 = await NativeBridge.a11yScreenshot();
                  _addLog(
                      'Screenshot: ${b64 != null ? '${b64.length} bytes' : 'failed'}');
                }),
                _actionChip('UI 树', Icons.account_tree, () async {
                  _addLog('Dumping UI tree...');
                  final xml = await NativeBridge.a11yDumpTree();
                  _addLog(
                      'UI tree: ${xml.length} chars, first 100: ${xml.length > 100 ? xml.substring(0, 100) : xml}...');
                }),
                _actionChip('OCR', Icons.text_snippet, () async {
                  _addLog('Running OCR...');
                  final result = await NativeBridge.a11yOcr();
                  if (result != null && result.isNotEmpty) {
                    try {
                      final blocks = jsonDecode(result) as List;
                      _addLog('OCR: ${blocks.length} blocks found');
                    } catch (_) {
                      _addLog('OCR: completed');
                    }
                  } else {
                    _addLog('OCR: failed or empty');
                  }
                }),
                _actionChip('当前 App', Icons.phone_android, () async {
                  await _loadCurrentApp();
                  _addLog('Current app: $_currentApp');
                }),
                _actionChip('已安装 App', Icons.apps_outlined, () async {
                  final apps = await NativeBridge.a11yInstalledApps();
                  _addLog('Installed apps: ${apps.length}');
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionChip(String label, IconData icon, VoidCallback onPressed) {
    return ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: onPressed,
    );
  }

  Widget _buildLogSection(ThemeData theme) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Text('操作日志', style: theme.textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: '复制日志',
                  onPressed: _logs.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(
                              ClipboardData(text: _logs.join('\n')));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制到剪贴板')),
                          );
                        },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: '清空日志',
                  onPressed: _logs.isEmpty
                      ? null
                      : () => setState(() => _logs.clear()),
                ),
              ],
            ),
          ),
          Container(
            height: 200,
            padding: const EdgeInsets.all(12),
            child: _logs.isEmpty
                ? Center(
                    child: Text(
                      '暂无日志',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      return Text(
                        _logs[index],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
