// EmojiText — рендерит текст, заменяя эмодзи на картинки Twemoji (assets/twemoji,
// лицензия CC-BY 4.0, атрибуция в экране «Поддержка»). Для эмодзи без точного
// ассета пробуем базовый символ из того же пака, а не системный глиф.
// Используется в бабблах и пикере.
//
// Заодно:
// - лёгкое markdown-форматирование (**bold**, __bold__, *italic*, _italic_)
//   — распознаётся в уже отправленном тексте при рендере, без отдельной
//   панели инструментов в композере (как в Telegram — печатаешь звёздочки/
//   подчёркивания, они форматируются сами).
// - подсветка команд /command (см. command_highlight.dart) — ВО ВСЕХ чатах,
//   не только с ботами (там дополнительно кликабельно — см. BotCommandText).
// - подсветка+клик @username (переход на профиль) и ссылок (открыть в
//   браузере) — ВЕЗДЕ, где показывается пользовательский текст (сообщения,
//   профиль, посты, комментарии), т.к. это общий виджет для всего этого.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../screens/profile_screen.dart';
import '../services/public_page_link.dart';
import '../theme.dart';
import 'command_highlight.dart';

class EmojiText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final double scale; // размер эмодзи относительно fontSize
  final bool allowFormatting;
  final void Function(String username)? onMentionTap;
  final void Function(String url)? onUrlTap;
  final void Function(String tag)? onTagTap;

  final InlineSpan? trailing;

  const EmojiText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.scale = 1.2,
    this.allowFormatting = true,
    this.onMentionTap,
    this.onUrlTap,
    this.onTagTap,
    this.trailing,
  });

  // Одиночный эмодзи-codepoint в основных диапазонах + опц. VS16 и ZWJ-цепочка.
  static final RegExp _re = RegExp(
    r'(?:[\u{1F300}-\u{1FAFF}\u{1F000}-\u{1F0FF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{2190}-\u{21FF}\u{1F1E6}-\u{1F1FF}\u{2934}\u{2935}\u{3030}\u{303D}\u{3297}\u{3299}\u{00A9}\u{00AE}]'
    r'(?:\u{FE0F})?(?:\u{200D}[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}](?:\u{FE0F})?)*'
    r'|[0-9#*]\u{FE0F}?\u{20E3})',
    unicode: true,
  );

  // **bold** / __bold__ / *italic* / _italic_ — непустой текст внутри, без
  // переноса строки (иначе многострочные сообщения с одиночной звёздочкой
  // в начале и конце по ошибке "съедали" бы всё между ними).
  static final RegExp _mdRe = RegExp(
    r'\*\*(?<b1>[^\n]+?)\*\*'
    r'|__(?<b2>[^\n]+?)__'
    r'|\*(?<i1>[^\n*]+?)\*'
    r'|_(?<i2>[^\n_]+?)_',
  );
  static final RegExp _hashtagRe = RegExp(
    r'(?<![\w#])#[A-Za-zА-Яа-яЁё0-9_]{1,30}',
    unicode: true,
  );

  static String _fileFor(String e) => e.runes
      .where((r) => r != 0xFE0F)
      .map((r) => r.toRadixString(16))
      .join('-');

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    if (!allowFormatting) {
      // Имена/заголовки могут содержать '_' и '*', но это обычный текст, а не
      // сообщение с Markdown. Эмодзи при этом всё ещё получают Twemoji.
      if (trailing == null && !_re.hasMatch(text)) {
        return Text(
          text,
          style: base,
          maxLines: maxLines,
          overflow: overflow ?? TextOverflow.clip,
          textAlign: textAlign ?? TextAlign.start,
        );
      }
      final spans = packSpans(text, base, (base.fontSize ?? 15) * scale);
      if (trailing != null) {
        spans.add(const TextSpan(text: '  '));
        spans.add(trailing!);
      }
      return Text.rich(
        TextSpan(style: base, children: spans),
        maxLines: maxLines,
        overflow: overflow ?? TextOverflow.clip,
        textAlign: textAlign ?? TextAlign.start,
      );
    }
    // Ни эмодзи, ни markdown, ни команд/упоминаний/ссылок — обычный Text
    // (без накладных расходов на кучу проходов regex на КАЖДОЕ сообщение
    // в списке).
    if (trailing == null &&
        !_re.hasMatch(text) &&
        !_mdRe.hasMatch(text) &&
        !commandRe.hasMatch(text) &&
        !mentionRe.hasMatch(text) &&
        !_hashtagRe.hasMatch(text) &&
        !urlRe.hasMatch(text)) {
      return Text(
        text,
        style: base,
        maxLines: maxLines,
        overflow: overflow ?? TextOverflow.clip,
        textAlign: textAlign ?? TextAlign.start,
      );
    }
    final size = (base.fontSize ?? 15) * scale;
    // Команды/ссылки/упоминания находим на ПОЛНОМ тексте первыми (приоритет
    // — /my_command или @user_name не должны разрезаться на italic по
    // случайному подчёркиванию внутри), а markdown-совпадения, которые
    // ПЕРЕСЕКАЮТСЯ хоть с одним из них, отбрасываем целиком — иначе такое
    // совпадение посреди **bold** разрезает пару маркеров пополам и на
    // экране остаются голые "**" (реальный баг, найденный ревью 2026-07-20:
    // "**Use /start to begin**" рендерился как "**Use " + подсвеченная
    // команда + " to begin**" с видимыми звёздочками). Приоритет между
    // собой: команда > ссылка > упоминание (в реальном тексте они и так
    // почти никогда не пересекаются — разные стартовые символы).
    final cmdMatches = commandRe.allMatches(text).toList();
    bool overlapsAny(RegExpMatch m, List<RegExpMatch> reserved) =>
        reserved.any((r) => r.start < m.end && m.start < r.end);
    final urlMatches = urlRe
        .allMatches(text)
        .where((m) => !overlapsAny(m, cmdMatches))
        .toList();
    final reservedForMention = [...cmdMatches, ...urlMatches];
    final mentionMatches = mentionRe
        .allMatches(text)
        .where((m) => !overlapsAny(m, reservedForMention))
        .toList();
    final reserved = [...cmdMatches, ...urlMatches, ...mentionMatches];
    final hashtagMatches = _hashtagRe
        .allMatches(text)
        .where((m) => !overlapsAny(m, reserved))
        .toList();
    reserved.addAll(hashtagMatches);
    final mdMatches = _mdRe
        .allMatches(text)
        .where((md) => !overlapsAny(md, reserved))
        .toList();
    final events = <_TextEvent>[
      for (final m in cmdMatches) _TextEvent(m.start, m.end, command: m),
      for (final m in urlMatches) _TextEvent(m.start, m.end, url: m),
      for (final m in mentionMatches) _TextEvent(m.start, m.end, mention: m),
      for (final m in hashtagMatches) _TextEvent(m.start, m.end, hashtag: m),
      for (final m in mdMatches) _TextEvent(m.start, m.end, markdown: m),
    ]..sort((a, b) => a.start.compareTo(b.start));

    final spans = <InlineSpan>[];
    var last = 0;
    for (final e in events) {
      if (e.start > last) {
        spans.addAll(packSpans(text.substring(last, e.start), base, size));
      }
      if (e.command != null) {
        spans.add(
          TextSpan(
            text: e.command!.group(0),
            style: base.copyWith(
              color: GE.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      } else if (e.mention != null) {
        final handle = e.mention!.group(0)!;
        spans.add(
          TextSpan(
            text: handle,
            style: base.copyWith(
              color: GE.primary,
              fontWeight: FontWeight.w700,
            ),
            recognizer: TapGestureRecognizer()
              ..onTap = () {
                if (onMentionTap != null) {
                  onMentionTap!(handle.substring(1));
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          ProfileScreen(username: handle.substring(1)),
                    ),
                  );
                }
              },
          ),
        );
      } else if (e.url != null) {
        final link = e.url!.group(0)!;
        spans.add(
          TextSpan(
            text: link,
            style: base.copyWith(
              color: GE.primary,
              decoration: TextDecoration.underline,
            ),
            recognizer: TapGestureRecognizer()
              ..onTap = () {
                (onUrlTap ?? PublicPageLink.open)(link);
              },
          ),
        );
      } else if (e.hashtag != null) {
        final tag = e.hashtag!.group(0)!.substring(1);
        spans.add(
          TextSpan(
            text: e.hashtag!.group(0),
            style: base.copyWith(
              color: GE.primary,
              fontWeight: FontWeight.w700,
            ),
            recognizer: onTagTap == null
                ? null
                : (TapGestureRecognizer()..onTap = () => onTagTap!(tag)),
          ),
        );
      } else {
        final m = e.markdown!;
        final bold = m.namedGroup('b1') ?? m.namedGroup('b2');
        final italic = m.namedGroup('i1') ?? m.namedGroup('i2');
        if (bold != null) {
          spans.addAll(
            packSpans(bold, base.copyWith(fontWeight: FontWeight.w800), size),
          );
        } else if (italic != null) {
          spans.addAll(
            packSpans(italic, base.copyWith(fontStyle: FontStyle.italic), size),
          );
        }
      }
      last = e.end;
    }
    if (last < text.length) {
      spans.addAll(packSpans(text.substring(last), base, size));
    }
    if (trailing != null) {
      spans.add(const TextSpan(text: '  '));
      spans.add(trailing!);
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: maxLines,
      overflow: overflow ?? TextOverflow.clip,
      textAlign: textAlign ?? TextAlign.start,
    );
  }

  /// Разбивает ОДИН сегмент (без команд/markdown) на эмодзи-картинки +
  /// обычный текст, весь под заданным style (учитывает bold/italic сегмента).
  static List<InlineSpan> packSpans(
    String segment,
    TextStyle style,
    double size,
  ) {
    if (!_re.hasMatch(segment)) {
      return [TextSpan(text: segment, style: style)];
    }
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _re.allMatches(segment)) {
      if (m.start > last) {
        spans.add(
          TextSpan(text: segment.substring(last, m.start), style: style),
        );
      }
      final e = m.group(0)!;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _PackEmoji(emoji: e, size: size),
        ),
      );
      last = m.end;
    }
    if (last < segment.length) {
      spans.add(TextSpan(text: segment.substring(last), style: style));
    }
    return spans;
  }
}

/// Tries the complete sequence first. For skin-tone and ZWJ sequences the
/// pack may only contain the base glyph, so each base codepoint is a safe
/// second choice. The final fallback is an empty box: it is preferable to
/// leaking a platform-dependent system emoji into the UI.
class _PackEmoji extends StatelessWidget {
  final String emoji;
  final double size;

  const _PackEmoji({required this.emoji, required this.size});

  List<String> _candidates() {
    final candidates = <String>[];
    void add(String value) {
      if (!candidates.contains(value)) candidates.add(value);
    }

    add('assets/twemoji/${EmojiText._fileFor(emoji)}.png');
    for (final rune in emoji.runes) {
      if (rune == 0xFE0F ||
          rune == 0x200D ||
          (rune >= 0x1F3FB && rune <= 0x1F3FF)) {
        continue;
      }
      add('assets/twemoji/${rune.toRadixString(16)}.png');
    }
    return candidates;
  }

  Widget _image(BuildContext context, List<String> candidates, int index) {
    if (index >= candidates.length) {
      return SizedBox(width: size, height: size);
    }
    return Image.asset(
      candidates[index],
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => _image(context, candidates, index + 1),
    );
  }

  @override
  Widget build(BuildContext context) => _image(context, _candidates(), 0);
}

/// Одно "событие" в тексте — команда, ссылка, упоминание или markdown-
/// совпадение, отсортированные по позиции для единого прохода в build().
class _TextEvent {
  final int start;
  final int end;
  final RegExpMatch? command;
  final RegExpMatch? mention;
  final RegExpMatch? hashtag;
  final RegExpMatch? url;
  final RegExpMatch? markdown;
  _TextEvent(
    this.start,
    this.end, {
    this.command,
    this.mention,
    this.hashtag,
    this.url,
    this.markdown,
  });
}
