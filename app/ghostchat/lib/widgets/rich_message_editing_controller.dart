import 'package:flutter/material.dart';

import '../theme.dart';
import 'command_highlight.dart';

/// Keeps markdown markers in the actual message text while rendering the
/// parts that are already complete directly inside the native text field.
/// This means editing, selection, copy/paste and IME composition still use
/// ordinary TextEditingValue offsets.
class RichMessageEditingController extends TextEditingController {
  static final RegExp _markdown = RegExp(
    r'\*\*(?<b1>[^\n]+?)\*\*|__(?<b2>[^\n]+?)__|\*(?<i1>[^\n*]+?)\*|_(?<i2>[^\n_]+?)_',
  );
  static final RegExp _hashtag = RegExp(
    r'(?<![\w#])#[A-Za-zА-Яа-яЁё0-9_]{1,30}',
    unicode: true,
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final text = value.text;
    if (text.isEmpty) return TextSpan(style: base);

    final events = <_EditEvent>[];
    final reserved = <_SpanRange>[];
    void addMatches(RegExp regex, _EditEventKind kind) {
      for (final match in regex.allMatches(text)) {
        final range = _SpanRange(match.start, match.end);
        if (reserved.any((item) => item.overlaps(range))) continue;
        reserved.add(range);
        events.add(_EditEvent(range.start, range.end, kind, match));
      }
    }

    addMatches(_markdown, _EditEventKind.markdown);
    addMatches(urlRe, _EditEventKind.url);
    addMatches(mentionRe, _EditEventKind.mention);
    addMatches(_hashtag, _EditEventKind.hashtag);
    events.sort((a, b) => a.start.compareTo(b.start));

    final children = <InlineSpan>[];
    var cursor = 0;
    for (final event in events) {
      if (event.start > cursor) {
        children.add(
          TextSpan(text: text.substring(cursor, event.start), style: base),
        );
      }
      final raw = text.substring(event.start, event.end);
      switch (event.kind) {
        case _EditEventKind.markdown:
          final match = event.match!;
          final bold = match.namedGroup('b1') ?? match.namedGroup('b2');
          final italic = match.namedGroup('i1') ?? match.namedGroup('i2');
          final markerLength = bold != null || match.namedGroup('b2') != null
              ? 2
              : 1;
          final opening = raw.substring(0, markerLength);
          final closing = raw.substring(raw.length - markerLength);
          final inner = raw.substring(markerLength, raw.length - markerLength);
          final contentStyle = base.copyWith(
            fontWeight: bold != null ? FontWeight.w800 : base.fontWeight,
            fontStyle: italic != null ? FontStyle.italic : base.fontStyle,
          );
          final markerStyle = base.copyWith(
            color: (base.color ?? GE.text).withValues(alpha: 0.34),
          );
          children.add(TextSpan(text: opening, style: markerStyle));
          children.add(TextSpan(text: inner, style: contentStyle));
          children.add(TextSpan(text: closing, style: markerStyle));
          break;
        case _EditEventKind.url:
        case _EditEventKind.mention:
        case _EditEventKind.hashtag:
          children.add(
            TextSpan(
              text: raw,
              style: base.copyWith(
                color: GE.primary,
                fontWeight: FontWeight.w600,
                decoration: event.kind == _EditEventKind.url
                    ? TextDecoration.underline
                    : null,
              ),
            ),
          );
          break;
      }
      cursor = event.end;
    }
    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor), style: base));
    }
    return TextSpan(style: base, children: children);
  }
}

enum _EditEventKind { markdown, url, mention, hashtag }

class _EditEvent {
  final int start;
  final int end;
  final _EditEventKind kind;
  final RegExpMatch? match;

  const _EditEvent(this.start, this.end, this.kind, this.match);
}

class _SpanRange {
  final int start;
  final int end;

  const _SpanRange(this.start, this.end);

  bool overlaps(_SpanRange other) => start < other.end && other.start < end;
}
