// EmojiText — рендерит текст, заменяя эмодзи на картинки Twemoji (assets/twemoji,
// лицензия CC-BY 4.0, атрибуция в экране «Поддержка»). Для эмодзи без ассета —
// откат на системный глиф (errorBuilder). Используется в бабблах и пикере.
import 'package:flutter/material.dart';

class EmojiText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final double scale; // размер эмодзи относительно fontSize

  const EmojiText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.scale = 1.2,
  });

  // Одиночный эмодзи-codepoint в основных диапазонах + опц. VS16 и ZWJ-цепочка.
  static final RegExp _re = RegExp(
    r'(?:[\u{1F300}-\u{1FAFF}\u{1F000}-\u{1F0FF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{2190}-\u{21FF}\u{1F1E6}-\u{1F1FF}\u{2934}\u{2935}\u{3030}\u{303D}\u{3297}\u{3299}\u{00A9}\u{00AE}]'
    r'(?:\u{FE0F})?(?:\u{200D}[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}](?:\u{FE0F})?)*'
    r'|[0-9#*]\u{FE0F}?\u{20E3})',
    unicode: true,
  );

  static String _fileFor(String e) =>
      e.runes.where((r) => r != 0xFE0F).map((r) => r.toRadixString(16)).join('-');

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    // Если эмодзи в тексте нет — обычный Text (без накладных расходов).
    if (!_re.hasMatch(text)) {
      return Text(
        text,
        style: base,
        maxLines: maxLines,
        overflow: overflow ?? TextOverflow.clip,
        textAlign: textAlign ?? TextAlign.start,
      );
    }
    final size = (base.fontSize ?? 15) * scale;
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _re.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final e = m.group(0)!;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Image.asset(
            'assets/twemoji/${_fileFor(e)}.png',
            width: size,
            height: size,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, __, ___) => Text(e, style: base),
          ),
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
      textAlign: textAlign ?? TextAlign.start,
    );
  }
}
