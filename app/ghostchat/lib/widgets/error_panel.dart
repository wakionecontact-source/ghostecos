import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import '../screens/logs_screen.dart';
import 'glass.dart';

/// Turns a raw exception into a short message suitable for the main UI.
String errorSummary(
  Object error, {
  String fallback = 'Не удалось выполнить операцию',
}) {
  final raw = error.toString().trim();
  final text = raw
      .replaceFirst(RegExp(r'^Exception:\s*'), '')
      .replaceFirst(RegExp(r'^DioException\s*\[[^\]]*\]:\s*'), '')
      .trim();
  final lower = text.toLowerCase();
  if (text.isEmpty) return fallback;
  if (lower.contains('socketexception') ||
      lower.contains('connection refused') ||
      lower.contains('connection reset')) {
    return 'Нет соединения с сервером';
  }
  if (lower.contains('timeout') || lower.contains('timed out')) {
    return 'Сервер не ответил вовремя';
  }
  if (RegExp(r'\b401\b|\b403\b').hasMatch(text)) {
    return 'Доступ запрещён или сессия истекла';
  }
  if (RegExp(r'\b404\b').hasMatch(text)) return 'Данные не найдены';
  if (RegExp(r'\b5\d\d\b').hasMatch(text)) {
    return 'Сервер временно недоступен';
  }
  final firstLine = text.split(RegExp(r'[\r\n]+')).first.trim();
  if (firstLine.length <= 120) return firstLine;
  return '${firstLine.substring(0, 117)}...';
}

/// Keeps the complete technical text available without dumping it into the
/// normal layout. The same string is also written to AppLogger by callers.
String errorDetails(Object error) => error.toString().trim();

class AppErrorPanel extends StatefulWidget {
  final String title;
  final String message;
  final String? details;
  final int? logId;
  final VoidCallback? onRetry;
  final bool compact;

  const AppErrorPanel({
    super.key,
    this.title = 'Не удалось выполнить операцию',
    required this.message,
    this.details,
    this.logId,
    this.onRetry,
    this.compact = false,
  });

  @override
  State<AppErrorPanel> createState() => _AppErrorPanelState();
}

class _AppErrorPanelState extends State<AppErrorPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final details = widget.details?.trim();
    final hasDetails = details != null && details.isNotEmpty;
    final padding = widget.compact
        ? const EdgeInsets.all(10)
        : const EdgeInsets.all(14);
    return GlassCard(
      lite: true,
      isListSection: true,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                CupertinoIcons.exclamationmark_circle,
                color: GE.red,
                size: widget.compact ? 18 : 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        color: GE.text,
                        fontSize: widget.compact ? 12.5 : 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.message,
                      style: TextStyle(
                        color: GE.sub,
                        fontSize: widget.compact ? 11.5 : 12.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_expanded && hasDetails) ...[
            const SizedBox(height: 9),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 150),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  details,
                  style: TextStyle(
                    color: GE.muted,
                    fontFamily: 'monospace',
                    fontSize: 10,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              if (hasDetails)
                TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    size: 13,
                  ),
                  label: Text(_expanded ? 'Скрыть детали' : 'Подробности'),
                  style: _buttonStyle(GE.sub),
                ),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => LogsScreen(focusLogId: widget.logId),
                    ),
                  );
                },
                icon: const Icon(CupertinoIcons.doc_text, size: 13),
                label: const Text('Открыть логи'),
                style: _buttonStyle(GE.primary),
              ),
              if (widget.onRetry != null)
                TextButton.icon(
                  onPressed: widget.onRetry,
                  icon: const Icon(CupertinoIcons.refresh, size: 13),
                  label: const Text('Повторить'),
                  style: _buttonStyle(GE.primary),
                ),
            ],
          ),
        ],
      ),
    );
  }

  ButtonStyle _buttonStyle(Color color) => TextButton.styleFrom(
    foregroundColor: color,
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    minimumSize: Size.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: const TextStyle(fontSize: 11.5),
  );
}
