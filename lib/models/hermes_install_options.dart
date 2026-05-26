import 'dart:io';
import 'dart:math' as math;

import '../l10n/app_localizations.dart';

String formatHermesReleaseLabel(
  AppLocalizations l10n,
  String version, {
  String? latestVersion,
}) {
  final tags = <String>[];
  if (version == latestVersion) {
    tags.add(l10n.t('gatewayLatest'));
  }
  if (tags.isEmpty) {
    return version;
  }
  return '$version (${tags.join(' / ')})';
}

/// Installation method for Hermes Agent.
enum HermesInstallMethod {
  /// Direct pip install hermes-agent from PyPI.
  /// Fast and reliable, supports version selection and mirror configuration.
  pip,

  /// Terminal-based curl | bash install.
  /// Runs the official install.sh via curl pipe in a real terminal (PTY),
  /// so the user can see live output and interact with prompts.
  /// Uses GitHub proxy to accelerate downloads.
  terminal,
}

class HermesInstallOptions {
  final String? ubuntuRootfsUrl;
  final String? ubuntuRootfsArchivePath;
  final String? prebuiltRootfsUrl;
  final String? prebuiltRootfsArchivePath;

  /// Which installation method to use.
  final HermesInstallMethod installMethod;

  /// Custom URL for the hermes install.sh script.
  /// Only used when [installMethod] is [HermesInstallMethod.terminal].
  final String? hermesInstallScriptUrl;

  /// Custom pip index URL (e.g. mirror).
  /// Only used when [installMethod] is [HermesInstallMethod.pip].
  final String? pipIndexUrl;

  /// Custom URL for Node.js setup (NodeSource).
  /// Used by both methods when Node.js needs to be installed.
  final String? nodejsSetupUrl;

  const HermesInstallOptions({
    this.ubuntuRootfsUrl,
    this.ubuntuRootfsArchivePath,
    this.prebuiltRootfsUrl,
    this.prebuiltRootfsArchivePath,
    this.installMethod = HermesInstallMethod.pip,
    this.hermesInstallScriptUrl,
    this.pipIndexUrl,
    this.nodejsSetupUrl,
  });

  String? get normalizedUbuntuRootfsUrl {
    final value = ubuntuRootfsUrl?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  String? get normalizedUbuntuRootfsArchivePath {
    final value = ubuntuRootfsArchivePath?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  String? get normalizedPrebuiltRootfsUrl {
    final value = prebuiltRootfsUrl?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  String? get normalizedPrebuiltRootfsArchivePath {
    final value = prebuiltRootfsArchivePath?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  bool get hasBootstrapResourceOverrides =>
      normalizedUbuntuRootfsUrl != null ||
      normalizedUbuntuRootfsArchivePath != null ||
      normalizedPrebuiltRootfsUrl != null ||
      normalizedPrebuiltRootfsArchivePath != null;

  HermesInstallOptions copyWith({
    String? ubuntuRootfsUrl,
    String? ubuntuRootfsArchivePath,
    String? prebuiltRootfsUrl,
    String? prebuiltRootfsArchivePath,
    HermesInstallMethod? installMethod,
    String? hermesInstallScriptUrl,
    String? pipIndexUrl,
    String? nodejsSetupUrl,
    bool clearUbuntuRootfsUrl = false,
    bool clearUbuntuRootfsArchivePath = false,
    bool clearPrebuiltRootfsUrl = false,
    bool clearPrebuiltRootfsArchivePath = false,
    bool clearHermesInstallScriptUrl = false,
    bool clearPipIndexUrl = false,
    bool clearNodejsSetupUrl = false,
  }) {
    return HermesInstallOptions(
      ubuntuRootfsUrl: clearUbuntuRootfsUrl
          ? null
          : (ubuntuRootfsUrl ?? this.ubuntuRootfsUrl),
      ubuntuRootfsArchivePath: clearUbuntuRootfsArchivePath
          ? null
          : (ubuntuRootfsArchivePath ?? this.ubuntuRootfsArchivePath),
      prebuiltRootfsUrl: clearPrebuiltRootfsUrl
          ? null
          : (prebuiltRootfsUrl ?? this.prebuiltRootfsUrl),
      prebuiltRootfsArchivePath: clearPrebuiltRootfsArchivePath
          ? null
          : (prebuiltRootfsArchivePath ?? this.prebuiltRootfsArchivePath),
      installMethod: installMethod ?? this.installMethod,
      hermesInstallScriptUrl: clearHermesInstallScriptUrl
          ? null
          : (hermesInstallScriptUrl ?? this.hermesInstallScriptUrl),
      pipIndexUrl: clearPipIndexUrl
          ? null
          : (pipIndexUrl ?? this.pipIndexUrl),
      nodejsSetupUrl: clearNodejsSetupUrl
          ? null
          : (nodejsSetupUrl ?? this.nodejsSetupUrl),
    );
  }
}
