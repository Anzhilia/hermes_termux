import 'dart:convert';
import 'package:yaml/yaml.dart';

import '../constants.dart';
import 'dashboard_url_resolver.dart';
import 'native_bridge.dart';

/// Reads gateway auth data from Hermes's persisted config.
///
/// Auth tokens are stored under `gateway.auth.token` in config.yaml.
/// Some installs still keep legacy variants, so we probe those as fallbacks.
class GatewayAuthConfigService {
  static const _configPaths = [
    'root/.hermes/config.yaml',
    '/root/.hermes/config.yaml',
  ];
  static const _envPaths = [
    'root/.hermes/.env',
    '/root/.hermes/.env',
  ];

  static Future<String?> readGatewayAuthToken() async {
    final configContent = await _readFirstExistingFile(_configPaths);
    final envContent = await _readFirstExistingFile(_envPaths);
    return extractGatewayAuthToken(
      configContent,
      envContent: envContent,
    );
  }

  static Future<String?> readDashboardUrl({Uri? baseUri}) async {
    final token = await readGatewayAuthToken();
    if (token == null) {
      return null;
    }
    return DashboardUrlResolver.buildDashboardUrl(
      baseUri ?? Uri.parse(AppConstants.gatewayUrl),
      token,
    );
  }

  static String? extractGatewayAuthToken(
    String? configContent, {
    String? envContent,
  }) {
    if (configContent == null || configContent.trim().isEmpty) {
      return null;
    }

    try {
      // Try parsing as YAML first (Hermes format)
      final doc = loadYaml(configContent);
      if (doc is YamlMap) {
        final config = _convertYamlMap(doc);
        final token = _resolveTokenValue(_findGatewayToken(config),
            envContent: envContent);
        if (token != null) {
          return token;
        }
      }
    } catch (_) {
      // Fall back to JSON parsing
      try {
        final decoded = jsonDecode(configContent);
        if (decoded is Map) {
          final config = _asStringKeyedMap(decoded);
          final token = _resolveTokenValue(_findGatewayToken(config),
              envContent: envContent);
          if (token != null) {
            return token;
          }
        }
      } catch (_) {
        // Fall back to text-based extraction below.
      }
    }

    return DashboardUrlResolver.extractToken(configContent);
  }

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

  static Future<String?> _readFirstExistingFile(List<String> paths) async {
    for (final path in paths) {
      try {
        final content = await NativeBridge.readRootfsFile(path);
        if (content != null && content.trim().isNotEmpty) {
          return content;
        }
      } catch (_) {
        // Ignore and continue to the next candidate path.
      }
    }
    return null;
  }

  static Map<String, dynamic> _asStringKeyedMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), item),
      );
    }
    return <String, dynamic>{};
  }

  static dynamic _readPath(Map<String, dynamic> source, List<String> path) {
    dynamic current = source;
    for (final segment in path) {
      if (current is! Map) {
        return null;
      }
      current = current[segment];
    }
    return current;
  }

  static String? _findGatewayToken(Map<String, dynamic> config) {
    const candidatePaths = <List<String>>[
      ['gateway', 'auth', 'token'],
      ['gateway', 'controlUi', 'auth', 'token'],
      ['gateway', 'controlUI', 'auth', 'token'],
      ['gateway', 'controlUi', 'token'],
      ['gateway', 'controlUI', 'token'],
      ['gateway', 'token'],
    ];

    for (final path in candidatePaths) {
      final value = _readPath(config, path);
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }

    final gateway = _asStringKeyedMap(config['gateway']);
    return _findNestedToken(gateway);
  }

  static String? _findNestedToken(Map<String, dynamic> source) {
    for (final entry in source.entries) {
      final key = entry.key.toLowerCase();
      final value = entry.value;

      if (key == 'token' && value is String && value.trim().isNotEmpty) {
        return value.trim();
      }

      if (value is Map) {
        final nested = _findNestedToken(_asStringKeyedMap(value));
        if (nested != null) {
          return nested;
        }
      }
    }
    return null;
  }

  static String? _resolveTokenValue(
    String? rawValue, {
    String? envContent,
  }) {
    if (rawValue == null || rawValue.trim().isEmpty) {
      return null;
    }

    final trimmed = rawValue.trim();
    final envPattern = RegExp(
      r'^(?:\$\{([A-Z0-9_]+)\}|\$([A-Z0-9_]+))$',
      caseSensitive: false,
    );
    final envMatch = envPattern.firstMatch(trimmed);
    if (envMatch != null) {
      final envName = envMatch.group(1) ?? envMatch.group(2)!;
      final envValue = _readEnvValue(envContent, envName);
      return DashboardUrlResolver.sanitizeTokenValue(envValue);
    }

    return DashboardUrlResolver.sanitizeTokenValue(trimmed);
  }

  static String? _readEnvValue(String? envContent, String name) {
    if (envContent == null || envContent.trim().isEmpty) {
      return null;
    }

    for (final rawLine in const LineSplitter().convert(envContent)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }

      final separatorIndex = line.indexOf('=');
      if (separatorIndex <= 0) {
        continue;
      }

      final key = line.substring(0, separatorIndex).trim();
      if (key != name) {
        continue;
      }

      final value = line.substring(separatorIndex + 1).trim();
      return _stripQuotes(value);
    }

    return null;
  }

  static String _stripQuotes(String value) {
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }
}
