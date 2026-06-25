/// Валидация пользовательского ввода GhostChat.
///
/// Безопасность — приоритет №1. Правила (ТЗ):
///   • Имя (display_name): 2..100 символов, любые КРОМЕ «тяжёлых».
///       «Тяжёлые» = управляющие, zero-width, bidi-override и комбинирующие
///       (zalgo) символы. Именно zalgo-строкой проект однажды задосили —
///       тысячи комбинирующих марок на одном символе вешают рендер.
///   • Username: 3..60 символов БЕЗ учёта точек; разрешены только латиница,
///       цифры, '_' и '.'; общая длина ограничена (анти-DoS на спам точками).
///   • Пароль: 8..150 символов, любые КРОМЕ запрещённых (управляющих) и эмодзи.
///
/// Каждая функция возвращает `null`, если всё ок, иначе — текст ошибки (ru).
/// Те же правила ОБЯЗАНЫ дублироваться на сервере: клиенту доверять нельзя.
library;

import '../../core/constants.dart';

class Validators {
  Validators._();

  // ── Низкоуровневые проверки символов ───────────────────────────────────────

  /// Управляющие символы: C0 (0x00–0x1F), DEL (0x7F), C1 (0x80–0x9F).
  static bool _isControl(int cp) =>
      cp < 0x20 || (cp >= 0x7F && cp <= 0x9F);

  /// Zero-width / format / bidi-override — невидимый и опасный мусор.
  static bool _isInvisibleOrBidi(int cp) {
    return cp == 0x00AD || // soft hyphen
        cp == 0x034F || // combining grapheme joiner
        (cp >= 0x200B && cp <= 0x200F) || // ZWSP, ZWNJ, ZWJ, LRM, RLM
        (cp >= 0x202A && cp <= 0x202E) || // bidi embedding/override
        (cp >= 0x2060 && cp <= 0x2064) || // word joiner, invisible ops
        (cp >= 0x2066 && cp <= 0x206F) || // bidi isolates
        cp == 0xFEFF || // BOM / zero-width no-break space
        cp == 0x180E || // mongolian vowel separator
        (cp >= 0xFFF9 && cp <= 0xFFFB); // interlinear annotation
  }

  /// Комбинирующие марки (основа zalgo). Широкий охват по блокам Unicode.
  static bool _isCombiningMark(int cp) {
    return (cp >= 0x0300 && cp <= 0x036F) || // Combining Diacritical Marks
        (cp >= 0x0483 && cp <= 0x0489) || // Cyrillic combining
        (cp >= 0x0591 && cp <= 0x05BD) || // Hebrew
        cp == 0x05BF ||
        cp == 0x05C1 || cp == 0x05C2 ||
        cp == 0x05C4 || cp == 0x05C5 || cp == 0x05C7 ||
        (cp >= 0x0610 && cp <= 0x061A) || // Arabic
        (cp >= 0x064B && cp <= 0x065F) ||
        cp == 0x0670 ||
        (cp >= 0x06D6 && cp <= 0x06DC) ||
        (cp >= 0x06DF && cp <= 0x06E4) ||
        (cp >= 0x06E7 && cp <= 0x06E8) ||
        (cp >= 0x06EA && cp <= 0x06ED) ||
        (cp >= 0x0900 && cp <= 0x0903) || // Devanagari signs
        (cp >= 0x093A && cp <= 0x094F) ||
        (cp >= 0x0951 && cp <= 0x0957) ||
        (cp >= 0x1AB0 && cp <= 0x1AFF) || // Combining Diacritical Ext
        (cp >= 0x1DC0 && cp <= 0x1DFF) || // Combining Diacritical Supplement
        (cp >= 0x20D0 && cp <= 0x20FF) || // Combining for Symbols
        (cp >= 0xFE20 && cp <= 0xFE2F); // Combining Half Marks
  }

  /// «Тяжёлый» символ — запрещён в имени.
  static bool isHeavy(int cp) =>
      _isControl(cp) || _isInvisibleOrBidi(cp) || _isCombiningMark(cp);

  /// Эмодзи и сопутствующие селекторы — запрещены в пароле.
  static bool _isEmoji(int cp) {
    return (cp >= 0x1F000 && cp <= 0x1FAFF) || // основной диапазон эмодзи
        (cp >= 0x2600 && cp <= 0x27BF) || // misc symbols + dingbats
        (cp >= 0x2300 && cp <= 0x23FF) || // misc technical (⌚⌛ и пр.)
        (cp >= 0x2B00 && cp <= 0x2BFF) || // звёзды/стрелки (⭐)
        (cp >= 0x1F1E6 && cp <= 0x1F1FF) || // regional indicators (флаги)
        (cp >= 0xFE00 && cp <= 0xFE0F) || // variation selectors
        cp == 0x200D || // ZWJ (склейка эмодзи)
        cp == 0x20E3 || // combining enclosing keycap
        cp == 0x203C || cp == 0x2049 || // ‼ ⁉
        cp == 0x2122 || cp == 0x2139 ||
        (cp >= 0x2194 && cp <= 0x21AA) || // стрелки-эмодзи
        (cp >= 0x231A && cp <= 0x231B) ||
        cp == 0x24C2 ||
        (cp >= 0x25AA && cp <= 0x25FE) ||
        (cp >= 0x2934 && cp <= 0x2935);
  }

  // ── Имя (display_name) ──────────────────────────────────────────────────────

  static String? name(String raw) {
    final value = raw.trim();
    final runes = value.runes.toList();
    if (runes.isEmpty) return 'Введите имя';
    if (runes.length < K.nameMin) return 'Имя слишком короткое (минимум ${K.nameMin})';
    if (runes.length > K.nameMax) return 'Имя слишком длинное (максимум ${K.nameMax})';
    for (final cp in runes) {
      if (isHeavy(cp)) {
        return 'Имя содержит недопустимые символы';
      }
    }
    return null;
  }

  // ── Username ────────────────────────────────────────────────────────────────

  /// Приводим к каноничному виду (сервер тоже делает .lower()).
  static String normalizeUsername(String raw) => raw.trim().toLowerCase();

  static String? username(String raw) {
    final value = normalizeUsername(raw);
    if (value.isEmpty) return 'Введите имя пользователя';
    if (value.length > K.usernameMaxTotal) {
      return 'Имя пользователя слишком длинное';
    }
    // Разрешены ТОЛЬКО латиница/цифры/'_'/'.' — НЕ \w (тот пропускает Unicode).
    for (final cp in value.runes) {
      final isLatin = (cp >= 0x61 && cp <= 0x7A); // a-z (уже lower)
      final isDigit = (cp >= 0x30 && cp <= 0x39); // 0-9
      final isAllowedPunct = cp == 0x5F || cp == 0x2E; // _ .
      if (!(isLatin || isDigit || isAllowedPunct)) {
        return 'Только латиница, цифры, _ и точка';
      }
    }
    // Точки не считаются в длине.
    final noDots = value.replaceAll('.', '');
    if (noDots.length < K.usernameMinNoDots) {
      return 'Минимум ${K.usernameMinNoDots} символа (точки не в счёт)';
    }
    if (noDots.length > K.usernameMaxNoDots) {
      return 'Максимум ${K.usernameMaxNoDots} символов (точки не в счёт)';
    }
    return null;
  }

  // ── Пароль ────────────────────────────────────────────────────────────────

  static String? password(String value) {
    final runes = value.runes.toList();
    if (runes.isEmpty) return 'Введите пароль';
    if (runes.length < K.passwordMin) {
      return 'Пароль слишком короткий (минимум ${K.passwordMin})';
    }
    if (runes.length > K.passwordMax) {
      return 'Пароль слишком длинный (максимум ${K.passwordMax})';
    }
    for (final cp in runes) {
      if (_isControl(cp)) return 'Пароль содержит запрещённые символы';
      if (_isEmoji(cp)) return 'Пароль не должен содержать эмодзи';
    }
    return null;
  }

  /// Совпадение паролей при регистрации.
  static String? passwordConfirm(String pass, String confirm) {
    if (confirm.isEmpty) return 'Повторите пароль';
    if (pass != confirm) return 'Пароли не совпадают';
    return null;
  }
}
