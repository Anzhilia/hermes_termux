import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'native_bridge.dart';

/// 操作日志记录器
///
/// 记录所有无障碍操作的历史，支持内存缓存 + 文件持久化。
/// 供 AI 排查操作历史、调试失败步骤。
class OperationLogger {
  static final OperationLogger _instance = OperationLogger._();
  factory OperationLogger() => _instance;
  OperationLogger._();

  static const int _maxMemoryLogs = 200;
  static const int _maxFileLogs = 2000;

  final List<OperationLogEntry> _logs = [];
  final _logController = StreamController<OperationLogEntry>.broadcast();

  /// 日志流（UI 可监听实时更新）
  Stream<OperationLogEntry> get logStream => _logController.stream;

  /// 获取所有日志（内存中）
  List<OperationLogEntry> get logs => List.unmodifiable(_logs);

  /// 最近 N 条日志
  List<OperationLogEntry> getRecent(int count) {
    final start = _logs.length > count ? _logs.length - count : 0;
    return _logs.sublist(start);
  }

  /// 记录一条操作日志
  void log(
    String operation, {
    String details = '',
    bool success = true,
    String source = 'node',
    int? elapsedMs,
  }) {
    final entry = OperationLogEntry(
      timestamp: DateTime.now(),
      operation: operation,
      details: details,
      success: success,
      source: source,
      elapsedMs: elapsedMs,
    );

    _logs.add(entry);
    _logController.add(entry);

    // 内存缓存限制
    while (_logs.length > _maxMemoryLogs) {
      _logs.removeAt(0);
    }

    // 异步写入文件
    _persistLog(entry);
  }

  /// 记录一个操作的执行（自动计时）
  Future<T> track<T>(
    String operation,
    Future<T> Function() action, {
    String Function(T)? detailsBuilder,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await action();
      stopwatch.stop();
      log(
        operation,
        details: detailsBuilder?.call(result) ?? '',
        success: true,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      return result;
    } catch (e) {
      stopwatch.stop();
      log(
        operation,
        details: 'Error: $e',
        success: false,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
      rethrow;
    }
  }

  /// 清空日志
  void clear() {
    _logs.clear();
    _clearLogFile();
  }

  /// 导出日志为 JSON 字符串
  String toJson({int? limit}) {
    final entries = limit != null ? getRecent(limit) : _logs;
    return jsonEncode(entries.map((e) => e.toJson()).toList());
  }

  // ── 文件持久化 ──

  String? _logFilePath;

  Future<String> _getLogFilePath() async {
    if (_logFilePath != null) return _logFilePath!;
    try {
      final filesDir = await NativeBridge.getFilesDir();
      _logFilePath = '$filesDir/a11y_operation_logs.json';
    } catch (_) {
      _logFilePath = '/data/data/com.nousresearch.hermes/files/a11y_operation_logs.json';
    }
    return _logFilePath!;
  }

  Future<void> _persistLog(OperationLogEntry entry) async {
    try {
      final path = await _getLogFilePath();
      final file = File(path);

      // 如果文件不存在，创建并写入数组开头
      if (!await file.exists()) {
        await file.writeAsString('[\n${entry.toJsonString()}\n]',
            mode: FileMode.write);
        return;
      }

      // 追加模式：在 ] 前插入新条目
      // 简化实现：直接追加 JSON 行，读取时解析
      await file.writeAsString('${entry.toJsonString()}\n',
          mode: FileMode.append);

      // 定期清理过大文件
      final stat = await file.stat();
      if (stat.size > 500 * 1024) {
        // 500KB 限制，截断保留最后部分
        await _truncateLogFile(file);
      }
    } catch (_) {
      // 文件写入失败不影响主流程
    }
  }

  Future<void> _truncateLogFile(File file) async {
    try {
      final lines = await file.readAsLines();
      final keepLines = lines.length > _maxFileLogs
          ? lines.sublist(lines.length - _maxFileLogs)
          : lines;
      await file.writeAsString(keepLines.join('\n') + '\n',
          mode: FileMode.write);
    } catch (_) {}
  }

  Future<void> _clearLogFile() async {
    try {
      final path = await _getLogFilePath();
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  /// 从文件加载历史日志（App 重启后恢复）
  Future<List<OperationLogEntry>> loadFromFile({int limit = 100}) async {
    try {
      final path = await _getLogFilePath();
      final file = File(path);
      if (!await file.exists()) return [];

      final lines = await file.readAsLines();
      final entries = <OperationLogEntry>[];
      for (final line in lines.reversed) {
        if (entries.length >= limit) break;
        if (line.trim().isEmpty) continue;
        try {
          entries.add(OperationLogEntry.fromJsonString(line));
        } catch (_) {}
      }
      return entries.reversed.toList();
    } catch (_) {
      return [];
    }
  }
}

/// 操作日志条目
class OperationLogEntry {
  final DateTime timestamp;
  final String operation;
  final String details;
  final bool success;
  final String source;
  final int? elapsedMs;

  const OperationLogEntry({
    required this.timestamp,
    required this.operation,
    this.details = '',
    this.success = true,
    this.source = 'node',
    this.elapsedMs,
  });

  Map<String, dynamic> toJson() => {
        'time': timestamp.toIso8601String(),
        'timestamp': timestamp.millisecondsSinceEpoch,
        'operation': operation,
        'details': details,
        'success': success,
        'source': source,
        if (elapsedMs != null) 'elapsed_ms': elapsedMs,
      };

  String toJsonString() => jsonEncode(toJson());

  factory OperationLogEntry.fromJsonString(String jsonStr) {
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    return OperationLogEntry(
      timestamp: DateTime.fromMillisecondsSinceEpoch(
          map['timestamp'] as int? ?? 0),
      operation: map['operation'] as String? ?? '',
      details: map['details'] as String? ?? '',
      success: map['success'] as bool? ?? true,
      source: map['source'] as String? ?? 'node',
      elapsedMs: map['elapsed_ms'] as int?,
    );
  }

  @override
  String toString() {
    final ts = timestamp.toString().substring(11, 23);
    final status = success ? '✅' : '❌';
    final elapsed = elapsedMs != null ? ' (${elapsedMs}ms)' : '';
    return '[$ts] $status $operation$elapsed${details.isNotEmpty ? " — $details" : ""}';
  }
}
