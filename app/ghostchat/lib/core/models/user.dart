/// Модели пользователя и результата авторизации.
library;

class GcUser {
  final String username;
  final String displayName;
  final bool isPremium;
  final bool isBot;
  final String? botStatus;

  const GcUser({
    required this.username,
    required this.displayName,
    this.isPremium = false,
    this.isBot = false,
    this.botStatus,
  });

  factory GcUser.fromJson(Map<String, dynamic> j) => GcUser(
    username: (j['username'] ?? '') as String,
    displayName: (j['display_name'] ?? j['username'] ?? '') as String,
    isPremium: j['is_premium'] == true || j['is_premium'] == 1,
    isBot: j['is_bot'] == true || j['is_bot'] == 1,
    botStatus: j['bot_status'] as String?,
  );

  /// Инициал для аватара-заглушки.
  String get initial => displayName.isEmpty
      ? '?'
      : String.fromCharCode(displayName.runes.first).toUpperCase();
}

/// Итог попытки логина.
sealed class LoginOutcome {
  const LoginOutcome();
}

/// Вход успешен — есть токен.
class LoginSuccess extends LoginOutcome {
  final String token;
  final GcUser user;
  const LoginSuccess(this.token, this.user);
}

/// Новое устройство — нужно подтверждение (device trust).
class LoginPending extends LoginOutcome {
  final String requestId;
  const LoginPending(this.requestId);
}

/// Результат проверки 6-значного кода нового устройства.
class CodeResult {
  /// success | wrong | locked | expired
  final String result;
  final String? token;
  final String? username;
  final int? attemptsLeft;

  const CodeResult({
    required this.result,
    this.token,
    this.username,
    this.attemptsLeft,
  });

  bool get isSuccess => result == 'success';
}
