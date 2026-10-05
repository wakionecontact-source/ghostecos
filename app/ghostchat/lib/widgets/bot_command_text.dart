// Текст сообщения БОТА с кликабельными командами (/newbot и т.п.) — тап
// сразу отправляет эту команду как обычное сообщение, как гиперссылка.
// Обычные участки сообщения проходят через тот же emoji-pack renderer, что и
// остальные сообщения; команды остаются отдельными кликабельными spans.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import 'command_highlight.dart';
import 'emoji_text.dart';

class BotCommandText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final ValueChanged<String> onCommandTap;

  const BotCommandText(
    this.text, {
    super.key,
    this.style,
    required this.onCommandTap,
  });

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    if (!botCommandRe.hasMatch(text)) {
      return EmojiText(text, style: base, allowFormatting: false);
    }
    final spans = <InlineSpan>[];
    final size = (base.fontSize ?? 15) * 1.2;
    var last = 0;
    for (final m in botCommandRe.allMatches(text)) {
      if (m.start > last) {
        spans.addAll(
          EmojiText.packSpans(text.substring(last, m.start), base, size),
        );
      }
      final cmd = m.group(1) ?? m.group(2)!;
      spans.add(
        TextSpan(
          text: cmd,
          style: base.copyWith(color: GE.primary, fontWeight: FontWeight.w700),
          recognizer: TapGestureRecognizer()..onTap = () => onCommandTap(cmd),
        ),
      );
      last = m.end;
    }
    if (last < text.length) {
      spans.addAll(EmojiText.packSpans(text.substring(last), base, size));
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }
}
