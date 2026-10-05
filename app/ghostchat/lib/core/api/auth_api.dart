/// API авторизации GhostChat.
///
/// Регистрация генерирует крипто-идентичность (X25519/Ed25519) ДО запроса и
/// отправляет публичные ключи. Приватные части остаются в Keystore.
/// Логин с нового устройства запускает device-trust (поллинг + 6-значный код).
library;

import 'dart:io';

import '../crypto/key_manager.dart';
import '../models/user.dart';
import '../storage/secure_store.dart';
import 'http_client.dart';

class AuthApi {
  AuthApi._();
  static final AuthApi I = AuthApi._();

  final _http = HttpClient.I;

  String _deviceName() {
    try {
      // Имя хоста как человекочитаемый ярлык устройства.
      final h = Platform.localHostname;
      return h.isEmpty ? 'Android' : h;
    } catch (_) {
      return 'Android';
    }
  }

  /// Сохранить сессию после успешного входа/регистрации.
  Future<void> _persist(
    String token,
    String username, {
    bool premium = false,
  }) async {
    await SecureStore.I.setToken(token);
    await SecureStore.I.setUsername(username);
    await SecureStore.I.setPremium(premium);
  }

  // ── Регистрация ──────────────────────────────────────────────────────────────
  Future<LoginSuccess> register({
    required String username,
    required String password,
    required String displayName,
  }) async {
    final keys = await KeyManager.I.ensureIdentity();
    final deviceId = await KeyManager.I.ensureDeviceId();

    final r = await _http.postJson(
      '/api/register',
      body: {
        'username': username,
        'password': password,
        'display_name': displayName,
        'device_id': deviceId,
        'device_name': _deviceName(),
        'x25519_pub': keys.x25519PubB64,
        'ed25519_pub': keys.ed25519PubB64,
      },
    );

    final token = r['token'] as String;
    final uname = (r['username'] ?? username) as String;
    await _persist(token, uname);
    final dn = displayName.trim().isEmpty ? uname : displayName.trim();
    return LoginSuccess(token, GcUser(username: uname, displayName: dn));
  }

  // ── Логин ────────────────────────────────────────────────────────────────────
  Future<LoginOutcome> login({
    required String username,
    required String password,
  }) async {
    // Гарантируем наличие идентичности и device_id для этого устройства.
    await KeyManager.I.ensureIdentity();
    final deviceId = await KeyManager.I.ensureDeviceId();

    final r = await _http.postJson(
      '/api/login',
      body: {
        'username': username,
        'password': password,
        'device_id': deviceId,
        'device_name': _deviceName(),
      },
    );

    // Новое устройство — нужен device-trust.
    if (r['pending'] == true) {
      return LoginPending(r['request_id'] as String);
    }

    final token = r['token'] as String;
    final uname = (r['username'] ?? username) as String;
    final premium = r['is_premium'] == true || r['is_premium'] == 1;
    await _persist(token, uname, premium: premium);
    return LoginSuccess(
      token,
      GcUser(username: uname, displayName: uname, isPremium: premium),
    );
  }

  // ── Device trust: поллинг фазы ───────────────────────────────────────────────
  /// Возвращает текущую фазу запроса: pending | code_phase | success | denied |
  /// blocked | expired. При success в ответе уже есть token.
  Future<Map<String, dynamic>> pollLoginRequest(String requestId) async {
    return _http.getJson('/api/login_request/$requestId');
  }

  // ── Device trust: ввод 6-значного кода ───────────────────────────────────────
  Future<CodeResult> verifyCode(String requestId, String code) async {
    final r = await _http.postJson(
      '/api/login_request/$requestId/code_verify',
      body: {'code': code},
    );
    final result = (r['result'] ?? 'wrong') as String;
    if (result == 'success') {
      final token = r['token'] as String;
      final uname = (r['username'] ?? '') as String;
      await _persist(token, uname);
    }
    return CodeResult(
      result: result,
      token: r['token'] as String?,
      username: r['username'] as String?,
      attemptsLeft: r['attempts_left'] as int?,
    );
  }
}
