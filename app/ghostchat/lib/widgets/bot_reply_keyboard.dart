import 'package:flutter/material.dart';
import '../core/models/bot_reply_markup.dart';
import '../theme.dart';

class BotInlineKeyboardView extends StatelessWidget {
  final BotReplyMarkup markup;
  final ValueChanged<String> onCallback;
  final ValueChanged<String> onUrlTap;

  const BotInlineKeyboardView({
    super.key,
    required this.markup,
    required this.onCallback,
    required this.onUrlTap,
  });

  @override
  Widget build(BuildContext context) {
    final rows = markup.inlineKeyboard;
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
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final button in row)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: OutlinedButton(
                        onPressed: button.url != null
                            ? () => onUrlTap(button.url!)
                            : () => onCallback(button.callbackData!),
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
                        child: Text(
                          button.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
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
