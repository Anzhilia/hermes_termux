import 'package:flutter/material.dart';

import '../app.dart';
import '../l10n/app_localizations.dart';
import '../services/native_bridge.dart';

/// Simple syntax highlighter for .env files.
/// Highlights KEY=VALUE patterns with distinct colors.
class EnvSyntaxTextController extends TextEditingController {
  EnvSyntaxTextController({super.text});

  static final _commentPattern = RegExp(r'^#.*$', multiLine: true);
  static final _kvPattern = RegExp(
    r'^([A-Za-z_][A-Za-z0-9_]*)(=)(.*)$',
    multiLine: true,
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final baseStyle = style ?? DefaultTextStyle.of(context).style;
    final source = text;
    final spans = <TextSpan>[];
    var index = 0;

    // Process line by line for better control
    for (final line in source.split('\n')) {
      final lineStart = index;
      final lineEnd = index + line.length;

      // Check if comment
      if (line.trimLeft().startsWith('#')) {
        spans.add(TextSpan(
          text: '$line\n',
          style: baseStyle.copyWith(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF6B7280)
                : const Color(0xFF9CA3AF),
            fontStyle: FontStyle.italic,
          ),
        ));
        index = lineEnd + 1; // +1 for \n
        continue;
      }

      // Check if KEY=VALUE
      final kvMatch = _kvPattern.firstMatch(line);
      if (kvMatch != null) {
        final key = kvMatch.group(1)!;
        final eq = kvMatch.group(2)!;
        final value = kvMatch.group(3)!;
        final isDark = Theme.of(context).brightness == Brightness.dark;

        spans.add(TextSpan(
          text: key,
          style: baseStyle.copyWith(
            color: isDark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8),
            fontWeight: FontWeight.w700,
          ),
        ));
        spans.add(TextSpan(
          text: eq,
          style: baseStyle.copyWith(
            color: isDark ? const Color(0xFF6B7280) : const Color(0xFF9CA3AF),
            fontWeight: FontWeight.w700,
          ),
        ));
        spans.add(TextSpan(
          text: value,
          style: baseStyle.copyWith(
            color: isDark ? const Color(0xFF86EFAC) : const Color(0xFF047857),
          ),
        ));
        spans.add(TextSpan(text: '\n', style: baseStyle));
        index = lineEnd + 1;
        continue;
      }

      // Empty or other lines
      spans.add(TextSpan(text: '$line\n', style: baseStyle));
      index = lineEnd + 1;
    }

    return TextSpan(style: baseStyle, children: spans);
  }
}

/// Editor screen for ~/.hermes/.env file.
/// Similar to ConfigEditorScreen but for KEY=VALUE .env format.
class EnvEditorScreen extends StatefulWidget {
  const EnvEditorScreen({super.key});

  @override
  State<EnvEditorScreen> createState() => _EnvEditorScreenState();
}

class _EnvEditorScreenState extends State<EnvEditorScreen> {
  static const _envPath = 'root/.hermes/.env';

  final _controller = EnvSyntaxTextController();
  final _editorFocusNode = FocusNode();
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _editorFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
    _loadEnv();
  }

  @override
  void dispose() {
    _controller.dispose();
    _editorFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadEnv() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final content = await NativeBridge.readRootfsFile(_envPath);
      if (content != null && content.trim().isNotEmpty) {
        _controller.text = content;
      } else {
        // File doesn't exist yet — show template
        _controller.text =
            '# Hermes Agent environment configuration\n'
            '# Add your API keys and settings here\n'
            '#\n'
            '# Example:\n'
            '# OPENAI_API_KEY=sk-xxx\n'
            '# ANTHROPIC_API_KEY=sk-ant-xxx\n'
            '#\n';
      }
    } catch (e) {
      _loadError = e.toString();
      // Show empty template on error
      _controller.text =
          '# Hermes Agent environment configuration\n'
          '# Add your API keys and settings here\n';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveEnv() async {
    setState(() => _saving = true);
    try {
      await NativeBridge.writeRootfsFile(_envPath, _controller.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10nSaved)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10nSaveFailed(e))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get l10nSaved {
    try {
      return context.l10n.t('envEditorSaved');
    } catch (_) {
      return '.env 已保存';
    }
  }

  String l10nSaveFailed(dynamic error) {
    try {
      return context.l10n.t('envEditorSaveFailed', {'error': error});
    } catch (_) {
      return '保存失败: $error';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final isDark = theme.brightness == Brightness.dark;
    final editorBg = isDark ? AppColors.darkSurfaceAlt : AppColors.lightSurface;
    final isEditingCompact = _editorFocusNode.hasFocus ||
        MediaQuery.viewInsetsOf(context).bottom > 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('envEditorTitle')),
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadEnv,
            tooltip: l10n.t('configEditorRefresh'),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : AnimatedPadding(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: EdgeInsets.fromLTRB(
                16,
                isEditingCompact ? 8 : 16,
                16,
                isEditingCompact ? 8 : 16,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header / toolbar
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    child: isEditingCompact
                        ? _buildCompactToolbar(theme, l10n)
                        : _buildExpandedHeader(theme, l10n),
                  ),
                  SizedBox(height: isEditingCompact ? 8 : 12),
                  // Save button (expanded mode)
                  if (!isEditingCompact)
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: _saving ? null : _saveEnv,
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.save_outlined),
                          label: Text(
                            _saving
                                ? l10n.t('configEditorSaving')
                                : l10n.t('configEditorSave'),
                          ),
                        ),
                      ],
                    ),
                  if (!isEditingCompact) const SizedBox(height: 12),
                  // Editor
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: editorBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: theme.colorScheme.outline.withAlpha(60),
                        ),
                      ),
                      child: TextField(
                        controller: _controller,
                        focusNode: _editorFocusNode,
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.multiline,
                        smartDashesType: SmartDashesType.disabled,
                        smartQuotesType: SmartQuotesType.disabled,
                        scrollPadding:
                            const EdgeInsets.fromLTRB(16, 16, 16, 140),
                        style: (isEditingCompact
                                ? theme.textTheme.bodySmall
                                : theme.textTheme.bodyMedium)
                            ?.copyWith(
                          fontFamily: 'DejaVuSansMono',
                          height: 1.5,
                        ),
                        decoration: InputDecoration(
                          hintText: '# KEY=value\nOPENAI_API_KEY=sk-xxx',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(
                            isEditingCompact ? 12 : 16,
                          ),
                          filled: false,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildExpandedHeader(ThemeData theme, AppLocalizations l10n) {
    return Card(
      key: const ValueKey('expanded-header'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.t('envEditorSubtitle'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _envPath,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'DejaVuSansMono',
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_loadError != null) ...[
              const SizedBox(height: 12),
              Text(
                _loadError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCompactToolbar(ThemeData theme, AppLocalizations l10n) {
    return Container(
      key: const ValueKey('compact-header'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withAlpha(40)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _envPath,
              style: theme.textTheme.labelSmall?.copyWith(
                fontFamily: 'DejaVuSansMono',
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: _saving ? null : _saveEnv,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(
              _saving
                  ? l10n.t('configEditorSaving')
                  : l10n.t('configEditorSave'),
            ),
          ),
        ],
      ),
    );
  }
}
