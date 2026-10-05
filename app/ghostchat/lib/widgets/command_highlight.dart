// Общие regex-ы для подсветки текста — используются и в bot_command_text.dart
// (кликабельные команды в чате с ботом), и в emoji_text.dart (подсветка +
// клик во ВСЕХ чатах/профилях/постах, где показывается текст пользователя).

// От слэша (включительно) до пробела или знака препинания — не только
// identifier-подобное /command, а вообще всё до ближайшего разделителя.
final RegExp commandRe = RegExp(r'''(?<![\w/])/[^\s.,!?;:()\[\]{}"'«»]+''');

// Bot commands may carry a simple argument (for example `/buy power`). A
// bracketed hint such as `[число]` is deliberately not part of the command.
// In prose, fall back to just the slash-command token (`use /start to begin`).
final RegExp botCommandRe = RegExp(
  r'''(?<![\w/])(/[A-Za-z][A-Za-z0-9_]*(?:[ \t]+[A-Za-z0-9_-]+)?)(?=[ \t]*(?:\[[^\]\r\n]*\]|[—–,:;.!?]|$))|(?<![\w/])(/[A-Za-z][A-Za-z0-9_]*)''',
  multiLine: true,
);

// @username — юзернеймы на сервере: строчная латиница, цифры, "_" и "."
// (см. _val_username в social_router.py), 2-32 значащих символа без точек.
// Отрицательный lookbehind на \w/@/. — не путаем с email (word@domain) и не
// матчим второй "@" внутри уже начавшегося совпадения.
final RegExp mentionRe = RegExp(r'''(?<![\w@.])@[a-zA-Z0-9_.]{2,32}''');

// http(s)://... или www.домен — простая, не претендующая на RFC-полноту
// эвристика, достаточная для подсветки+клика в чате (как в Telegram).
final RegExp urlRe = RegExp(
  r'''(https?://[^\s<>"'«»]+)|(www\.[^\s<>"'«»]+\.[a-zA-Z]{2,}[^\s<>"'«»]*)''',
  caseSensitive: false,
);
