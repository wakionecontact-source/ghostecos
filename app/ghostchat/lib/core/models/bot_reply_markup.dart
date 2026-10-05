import 'dart:convert';

class BotInlineButton {
  final String text;
  final String? callbackData;
  final String? url;

  const BotInlineButton({required this.text, this.callbackData, this.url});

  Map<String, String> toJson() => {
    'text': text,
    'callback_data': ?callbackData,
    'url': ?url,
  };
}

class BotKeyboardButton {
  final String text;
  final String sendText;

  const BotKeyboardButton({required this.text, required this.sendText});

  Map<String, String> toJson() => {'text': text, 'send_text': sendText};
}

/// Validated, bounded subset of the bot API's Telegram-style reply markup.
class BotReplyMarkup {
  final List<List<BotInlineButton>>? inlineKeyboard;
  final List<List<BotKeyboardButton>>? keyboard;
  final bool resizeKeyboard;
  final bool oneTimeKeyboard;

  const BotReplyMarkup._({
    this.inlineKeyboard,
    this.keyboard,
    this.resizeKeyboard = true,
    this.oneTimeKeyboard = false,
  });

  bool get isInline => inlineKeyboard != null;
  bool get isReplyKeyboard => keyboard != null;

  Map<String, dynamic> toJson() {
    if (inlineKeyboard case final rows?) {
      return {
        'inline_keyboard': rows
            .map((row) => row.map((button) => button.toJson()).toList())
            .toList(),
      };
    }
    final rows = keyboard;
    if (rows == null) return const {};
    return {
      'keyboard': rows
          .map((row) => row.map((button) => button.toJson()).toList())
          .toList(),
      'resize_keyboard': resizeKeyboard,
      'one_time_keyboard': oneTimeKeyboard,
    };
  }

  static BotReplyMarkup? tryParse(Object? source) {
    Object? decoded = source;
    if (source is String) {
      if (utf8.encode(source).length > 16_384) return null;
      try {
        decoded = jsonDecode(source);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) return null;
    try {
      if (utf8.encode(jsonEncode(decoded)).length > 16_384) return null;
    } on JsonUnsupportedObjectError {
      return null;
    }
    final value = Map<Object?, Object?>.from(decoded);

    if (value.keys.toSet().length == 1 &&
        value.containsKey('inline_keyboard')) {
      final rows = _parseRows<BotInlineButton>(
        value['inline_keyboard'],
        _parseInlineButton,
      );
      return rows == null ? null : BotReplyMarkup._(inlineKeyboard: rows);
    }

    const allowedReplyKeys = {
      'keyboard',
      'resize_keyboard',
      'one_time_keyboard',
    };
    if (!value.containsKey('keyboard') ||
        value.keys.any((key) => !allowedReplyKeys.contains(key))) {
      return null;
    }
    final resize = value['resize_keyboard'] ?? true;
    final oneTime = value['one_time_keyboard'] ?? false;
    if (resize is! bool || oneTime is! bool) return null;
    final rows = _parseRows<BotKeyboardButton>(
      value['keyboard'],
      _parseKeyboardButton,
    );
    return rows == null
        ? null
        : BotReplyMarkup._(
            keyboard: rows,
            resizeKeyboard: resize,
            oneTimeKeyboard: oneTime,
          );
  }

  static List<List<T>>? _parseRows<T>(
    Object? source,
    T? Function(Object?) parseButton,
  ) {
    if (source is! List || source.isEmpty || source.length > 10) return null;
    var buttonCount = 0;
    final result = <List<T>>[];
    for (final rawRow in source) {
      if (rawRow is! List || rawRow.isEmpty || rawRow.length > 10) {
        return null;
      }
      buttonCount += rawRow.length;
      if (buttonCount > 100) return null;
      final row = <T>[];
      for (final rawButton in rawRow) {
        final button = parseButton(rawButton);
        if (button == null) return null;
        row.add(button);
      }
      result.add(List<T>.unmodifiable(row));
    }
    return List<List<T>>.unmodifiable(result);
  }

  static BotInlineButton? _parseInlineButton(Object? source) {
    if (source is! Map) return null;
    final button = Map<Object?, Object?>.from(source);
    final text = button['text'];
    if (text is! String || text.trim().isEmpty || text.length > 64) {
      return null;
    }
    if (button.keys.toSet().length == 2 &&
        button.containsKey('callback_data')) {
      final data = button['callback_data'];
      if (data is! String || data.isEmpty || utf8.encode(data).length > 64) {
        return null;
      }
      return BotInlineButton(text: text, callbackData: data);
    }
    if (button.keys.toSet().length == 2 && button.containsKey('url')) {
      final rawUrl = button['url'];
      if (rawUrl is! String || !_isSafeHttpUrl(rawUrl)) return null;
      return BotInlineButton(text: text, url: rawUrl);
    }
    return null;
  }

  static BotKeyboardButton? _parseKeyboardButton(Object? source) {
    if (source is! Map) return null;
    final button = Map<Object?, Object?>.from(source);
    final text = button['text'];
    final sendText = button['send_text'] ?? text;
    if (button.keys.any((key) => key != 'text' && key != 'send_text') ||
        text is! String ||
        text.trim().isEmpty ||
        text.length > 64 ||
        sendText is! String ||
        sendText.trim().isEmpty ||
        sendText.length > 4000) {
      return null;
    }
    return BotKeyboardButton(text: text, sendText: sendText);
  }

  static bool _isSafeHttpUrl(String raw) {
    if (raw.isEmpty ||
        raw.length > 2048 ||
        raw.contains('\\') ||
        raw.runes.any((rune) => rune <= 32 || rune == 127)) {
      return false;
    }
    try {
      final uri = Uri.parse(raw);
      final validScheme = uri.scheme == 'https' || uri.scheme == 'http';
      final validHost = uri.host.isNotEmpty && uri.userInfo.isEmpty;
      final validPort = uri.port >= 0 && uri.port <= 65535;
      return validScheme && validHost && validPort;
    } on FormatException {
      return false;
    }
  }
}
