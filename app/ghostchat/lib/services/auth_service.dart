// Аутентификация и хранение токена. Токен — в flutter_secure_storage (Keychain
// на iOS / Keystore на Android / DPAPI на Windows). Юзернейм/display_name — в
// SharedPreferences (не секретно). Поддерживает гостевой режим (UUID-токен).
import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import '../core/app_version.dart';
import '../theme.dart';
import '../core/local/app_logger.dart';
import 'chat_repo.dart';
import 'profile_cache.dart';
import 'bot_check_service.dart';
import 'password_auth_protocol.dart';

class AuthService {
  static const _secureToken = 'gs_token';
  static const _kUsername = 'gs_username';
  static const _kDisplay = 'gs_display';
  static const _kUserId = 'gs_user_id';
  static const _kIsGuest = 'gs_is_guest';
  static const _kSeedHash = 'gs_seed_hash';
  // TDA-1: уникальный ID этого устройства. Хранится в SecureStorage навсегда,
  // переживает logout (но не удаление приложения), чтобы не triggerить 2FA
  // повторно при возврате юзера на то же устройство.
  static const _secureDeviceId = 'gs_device_id_v1';
  static const _kDeviceName = 'gs_device_name';

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );

  // Кэш на сессию — чтобы не дёргать secure storage каждый раз.
  static String? _cachedToken;
  static bool _cacheReady = false;

  // Сигнал для MainShell: сервер отверг сохранённую сессию. Это не попытка
  // восстановить токен — приложение должно выйти на экран авторизации.
  static final ValueNotifier<bool> sessionInvalidNotifier = ValueNotifier(
    false,
  );
  static Future<void>? _invalidateFuture;

  // Retained as a no-op for existing ChatRepo call sites. The password is no
  // longer cached after authentication and is never reused for key sync.
  @Deprecated('Passwords are not retained after authentication')
  static void clearPendingPwd() {}

  static Future<String?> token() async {
    if (_cacheReady) return _cachedToken;
    try {
      // Some vendor Keystore implementations can leave a secure-storage read
      // pending indefinitely. It must not hold the router on its loading view.
      _cachedToken = await _secure
          .read(key: _secureToken)
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      appLog.warn('auth', 'secure read failed: $e');
      // Fallback на SharedPreferences (для совместимости с веб/Mock)
      final p = await SharedPreferences.getInstance();
      _cachedToken = p.getString(_secureToken);
    }
    _cacheReady = true;
    return _cachedToken;
  }

  static Future<String?> username() async =>
      (await SharedPreferences.getInstance()).getString(_kUsername);
  static Future<String?> displayName() async =>
      (await SharedPreferences.getInstance()).getString(_kDisplay);
  static Future<String?> userId() async =>
      (await SharedPreferences.getInstance()).getString(_kUserId);
  static Future<bool> isGuest() async =>
      (await SharedPreferences.getInstance()).getBool(_kIsGuest) ?? false;

  /// Удаляет только текущий токен и сообщает UI о принудительном выходе.
  /// Имя аккаунта/данные БД здесь намеренно не трогаются: полный logout
  /// выполняет MainShell, когда закрывает соединения и очищает локальную
  /// сессию.
  static Future<void> invalidateSession({String reason = 'Invalid token'}) {
    final running = _invalidateFuture;
    if (running != null) return running;
    final future = _invalidateSession(reason);
    late Future<void> wrapped;
    wrapped = future.whenComplete(() {
      if (identical(_invalidateFuture, wrapped)) _invalidateFuture = null;
    });
    _invalidateFuture = wrapped;
    return wrapped;
  }

  static Future<void> _invalidateSession(String reason) async {
    if (await isGuest()) return;
    _cachedToken = null;
    _cacheReady = true;
    try {
      await _secure.delete(key: _secureToken);
    } catch (e) {
      appLog.warn('auth', 'invalid session secure delete failed: $e');
    }
    final p = await SharedPreferences.getInstance();
    await p.remove(_secureToken);
    await p.remove(_kIsGuest);
    sessionInvalidNotifier.value = true;
    appLog.warn('auth', 'session invalidated by server: $reason');
  }

  /// TDA-1: уникальный DID этого устройства. Генерируется один раз, потом
  /// читается из SecureStorage.
  static Future<String> deviceId() async {
    try {
      final existing = await _secure.read(key: _secureDeviceId);
      if (existing != null && existing.isNotEmpty) return existing;
    } catch (e) {
      appLog.warn('auth', 'device_id secure read failed: $e');
    }
    final fresh = _randUuidV4();
    try {
      await _secure.write(key: _secureDeviceId, value: fresh);
    } catch (e) {
      appLog.warn(
        'auth',
        'device_id secure write failed, falling back to SharedPreferences: $e',
      );
      // Fallback в SharedPrefs если SecureStorage недоступен
      final p = await SharedPreferences.getInstance();
      await p.setString(_secureDeviceId, fresh);
    }
    return fresh;
  }

  static Future<String> deviceName() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_kDeviceName);
    if (saved != null && saved.isNotEmpty) return saved;
    // Default: платформа + первые 4 символа DID
    final did = await deviceId();
    final platform =
        Platform.operatingSystem; // 'android' / 'ios' / 'windows' / ...
    final cap = platform[0].toUpperCase() + platform.substring(1);
    final name = '$cap · ${did.substring(0, 4)}';
    await p.setString(_kDeviceName, name);
    return name;
  }

  static Future<void> setDeviceName(String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kDeviceName, name);
  }

  /// Обновить несекретный кэш отображаемых данных активного аккаунта.
  /// Пароль сюда никогда не передаётся и не сохраняется.
  static Future<void> updateCachedProfile({
    String? username,
    String? displayName,
    String? userId,
  }) async {
    final p = await SharedPreferences.getInstance();
    if (username != null) await p.setString(_kUsername, username);
    if (displayName != null) await p.setString(_kDisplay, displayName);
    if (userId != null && userId.trim().isNotEmpty) {
      await p.setString(_kUserId, userId.trim());
    }
  }

  /// Сохранить новый токен, который Social API выдаёт после смены пароля.
  static Future<void> replaceToken(String token) async {
    if (token.isEmpty) return;
    _cachedToken = token;
    _cacheReady = true;
    sessionInvalidNotifier.value = false;
    try {
      await _secure.write(key: _secureToken, value: token);
    } catch (e) {
      final p = await SharedPreferences.getInstance();
      await p.setString(_secureToken, token);
    }
  }

  static Future<void> _saveAuth(Map d, {bool guest = false}) async {
    _cachedToken = d['token'] as String;
    _cacheReady = true;
    sessionInvalidNotifier.value = false;
    try {
      await _secure.write(key: _secureToken, value: _cachedToken!);
    } catch (e) {
      // Fallback
      final p = await SharedPreferences.getInstance();
      await p.setString(_secureToken, _cachedToken!);
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_kUsername, d['username'] as String);
    final userId = d['user_id'] ?? d['id'];
    if (userId != null && userId.toString().trim().isNotEmpty) {
      await p.setString(_kUserId, userId.toString());
    }
    if (d['display_name'] != null) {
      await p.setString(_kDisplay, d['display_name'] as String);
    }
    await p.setBool(_kIsGuest, guest);
    if (d['seed_phrase'] != null) {
      // храним только hash чтобы юзер мог в будущем подтвердить (для recovery
      // настоящую фразу он должен записать сам — мы её НЕ храним).
      await p.setString(_kSeedHash, _hashSeed(d['seed_phrase'] as String));
    }
    appLog.info('auth', guest ? 'guest session started' : 'session saved');
  }

  static Future<void> logout() async {
    appLog.info('auth', 'logout started');
    _cachedToken = null;
    _cacheReady = true;
    try {
      await _secure.delete(key: _secureToken);
    } catch (e) {
      appLog.warn('auth', 'logout secure delete failed: $e');
    }
    final p = await SharedPreferences.getInstance();
    await p.remove(_secureToken);
    await p.remove(_kUsername);
    await p.remove(_kDisplay);
    await p.remove(_kUserId);
    await p.remove(_kIsGuest);
    await p.remove(_kSeedHash);
    BotCheckService.instance.clear();
    sessionInvalidNotifier.value = false;
    // На общем устройстве следующий залогинившийся не должен видеть
    // кэш профилей/аватарок/бот-флагов предыдущего аккаунта (ревью 2026-07-20).
    await ProfileCache.instance.clearAll();
    await ChatRepo.instance.clearPeerInfoCache();
    appLog.info('auth', 'logout completed');
  }

  // ─── HTTP-ручки авторизации ──────────────────────────────────────────
  static final _dio = _createAuthDio();

  static Dio _createAuthDio() {
    final dio = Dio(
      BaseOptions(
        baseUrl: GE.apiSoc,
        headers: {'Content-Type': 'application/json'},
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          options.headers[GhostChatAppVersion.headerName] =
              await GhostChatAppVersion.current();
          handler.next(options);
        },
      ),
    );
    return dio;
  }

  /// Логин. Если аккаунт включил TDA (подтверждение новых устройств) и это
  /// устройство ещё не доверено — сервер НЕ выдаёт токен сразу, а возвращает
  /// {requires_approval: true, request_id, code, ...}. Код виден ЗДЕСЬ (на
  /// новом устройстве) — юзер вводит его на уже доверенном устройстве
  /// (Настройки → Устройства → Ожидают подтверждения), после чего это
  /// устройство поллит /devices/pending/{request_id}/status до token.
  /// НЕ сохраняем сессию в этом случае — только после подтверждения.
  static Future<Map<String, dynamic>> login(
    String username,
    String password,
  ) async {
    final botToken = BotCheckService.instance.cachedToken('auth') ?? '';
    final did = await deviceId();
    final dname = await deviceName();
    final platform = Platform.operatingSystem;
    final nonce = PasswordAuthProtocol.newNonce();
    final context = await PasswordAuthProtocol.contextForLogin(
      deviceId: did,
      deviceName: dname,
      platform: platform,
    );
    final headers = {'X-Ghost-Bot-Token': botToken};
    final challengeResponse = await _dio.post(
      '/auth/v2/login/challenge',
      data: jsonEncode({
        'username': username,
        'client_nonce': nonce,
        'device_id': did,
        'device_name': dname,
        'platform': platform,
      }),
      options: Options(headers: headers),
    );
    if (challengeResponse.statusCode != 200) {
      throw _err(challengeResponse.data, challengeResponse.statusCode!);
    }
    final challenge = Map<String, dynamic>.from(challengeResponse.data as Map);
    if (challenge['context'] != context || challenge['client_nonce'] != nonce) {
      throw StateError('Сервер вернул некорректный запрос авторизации');
    }
    final proof = await PasswordAuthProtocol.prove(password, challenge);
    final response = await _dio.post(
      '/auth/v2/login/finish',
      data: jsonEncode({
        'challenge_id': challenge['challenge_id'],
        'proof': proof.clientProof,
        'device_id': did,
        'device_name': dname,
        'platform': platform,
      }),
      options: Options(headers: headers),
    );
    if (response.statusCode != 200) {
      throw _err(response.data, response.statusCode!);
    }
    final d = Map<String, dynamic>.from(response.data as Map);
    if (!PasswordAuthProtocol.verifyServerProof(
      proof.expectedServerProof,
      d['server_proof'],
    )) {
      throw StateError('Не удалось подтвердить сервер авторизации');
    }
    if (d['requires_approval'] == true) return d;
    await _saveAuth(d);
    appLog.info('auth', 'login completed');
    return d;
  }

  /// Сохранить сессию после того, как pending-логин подтверждён на другом
  /// устройстве (вызывается из DeviceApprovalWaitScreen с полученным токеном).
  static Future<void> saveApprovedSession(String token, String username) async {
    await _saveAuth({'token': token, 'username': username});
  }

  static Future<Map<String, dynamic>> register({
    required String username,
    required String displayName,
    required String password,
    required bool age18,
    String? ref,
  }) async {
    final botToken = BotCheckService.instance.cachedToken('auth') ?? '';
    final did = await deviceId();
    final dname = await deviceName();
    final verifier = await PasswordAuthProtocol.createVerifier(password);
    final r = await _dio.post(
      '/auth/v2/register',
      data: jsonEncode({
        'username': username,
        'display_name': displayName,
        'verifier': verifier,
        'age_18_confirm': age18,
        if (ref != null) 'ref': ref,
        'device_id': did,
        'device_name': dname,
        'platform': Platform.operatingSystem,
      }),
      options: Options(headers: {'X-Ghost-Bot-Token': botToken}),
    );
    if (r.statusCode != 200) throw _err(r.data, r.statusCode!);
    final d = Map<String, dynamic>.from(r.data as Map);
    await _saveAuth(d);
    appLog.info('auth', 'registration completed');
    return d;
  }

  /// Публичная проверка username для формы регистрации. Проверка не требует
  /// CAPTCHA или авторизации; сам сервер всё равно повторяет её при register.
  static Future<Map<String, dynamic>> checkUsername(String username) async {
    final normalized = username.trim().toLowerCase().replaceFirst('@', '');
    final r = await _dio.get(
      '/username/check/${Uri.encodeComponent(normalized)}',
    );
    if (r.statusCode != 200) throw _err(r.data, r.statusCode!);
    return Map<String, dynamic>.from(r.data as Map);
  }

  /// Гостевой режим — UUID-токен, без сервера. Каналы и соц-сеть недоступны,
  /// но LAN/локальные чаты работают (когда LAN-фичу вернём).
  static Future<Map<String, dynamic>> loginAsGuest() async {
    final id = _randUuidV4();
    final d = {
      'token': 'guest_$id',
      'username': 'guest_${id.substring(0, 8)}',
      'display_name': 'Гость',
    };
    await _saveAuth(d, guest: true);
    return d;
  }

  static String _err(dynamic data, int status) {
    if (data is Map && data['detail'] != null) return data['detail'].toString();
    return 'HTTP $status';
  }

  static String _hashSeed(String s) {
    // Простой DJB2 hash — для подтверждения «знаю ли я свою seed-фразу».
    int h = 5381;
    for (final c in s.codeUnits) {
      h = ((h * 33) + c) & 0xFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  static String _randUuidV4() {
    final r = Random.secure();
    String hex(int n) =>
        List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${(8 + r.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }
}
