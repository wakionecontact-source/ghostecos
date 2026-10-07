import 'package:flutter/material.dart';
import '../core/models/bot_reply_markup.dart';
import '../theme.dart';

class BotInlineKeyboardView extends StatefulWidget {
  final BotReplyMarkup markup;
  final Future<void> Function(String) onCallback;
  final ValueChanged<String> onUrlTap;

  const BotInlineKeyboardView({
    super.key,
    required this.markup,
    required this.onCallback,
    required this.onUrlTap,
  });

  @override
  State<BotInlineKeyboardView> createState() => _BotInlineKeyboardViewState();
}

class _BotInlineKeyboardViewState extends State<BotInlineKeyboardView> {
  final Set<String> _busyCallbacks = <String>{};

  Future<void> _sendCallback(String data) async {
    if (!_busyCallbacks.add(data)) return;
    setState(() {});
    try {
      await widget.onCallback(data);
    } finally {
      if (mounted) setState(() => _busyCallbacks.remove(data));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.markup.inlineKeyboard;
    if (rows == null || rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var index = 0; index < row.length; index++) ...[
                      if (index > 0) const SizedBox(width: 4),
                      Builder(
                        builder: (context) {
                          final button = row[index];
                          final callbackData = button.callbackData;
                          final busy =
                              callbackData != null &&
                              _busyCallbacks.contains(callbackData);
                          return ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 180),
                            child: OutlinedButton(
                              onPressed: button.url != null
                                  ? () => widget.onUrlTap(button.url!)
                                  : callbackData == null || busy
                                  ? null
                                  : () => _sendCallback(callbackData),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: GE.text,
                                side: BorderSide(
                                  color: GE.primary.withValues(alpha: 0.55),
                                ),
                                minimumSize: const Size(52, 40),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (busy) ...[
                                    const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Flexible(
                                    child: Text(
                                      button.text,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class BotReplyKeyboardView extends StatelessWidget {
  final BotReplyMarkup markup;
  final ValueChanged<String> onTap;

  const BotReplyKeyboardView({
    super.key,
    required this.markup,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final rows = markup.keyboard;
    if (rows == null || rows.isEmpty) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: GE.bgDeep.withValues(alpha: 0.94),
        border: Border(
          top: BorderSide(color: GE.primary.withValues(alpha: 0.16)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    for (var index = 0; index < row.length; index++) ...[
                      if (index > 0) const SizedBox(width: 4),
                      Expanded(
                        child: SizedBox(
                          height: 42,
                          child: OutlinedButton(
                            onPressed: () => onTap(row[index].sendText),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: GE.text,
                              backgroundColor: GE.surface.withValues(
                                alpha: 0.72,
                              ),
                              side: BorderSide(
                                color: GE.primary.withValues(alpha: 0.30),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                            child: Text(
                              row[index].text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ),
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
}
