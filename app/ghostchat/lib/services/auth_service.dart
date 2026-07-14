// Аутентификация и хранение токена. Токен — в flutter_secure_storage (Keychain
// на iOS / Keystore на Android / DPAPI на Windows). Юзернейм/display_name — в
// SharedPreferences (не секретно). Поддерживает гостевой режим (UUID-токен).
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import '../theme.dart';
import '../core/local/app_logger.dart';

class AuthService {
  static const _secureToken = 'gs_token';
  static const _kUsername = 'gs_username';
  static const _kDisplay = 'gs_display';
  static const _kIsGuest = 'gs_is_guest';
  static const _kSeedHash = 'gs_seed_hash';
  // TDA-1: уникальный ID этого устройства. Хранится в SecureStorage навсегда,
  // переживает logout (но не удаление приложения), чтобы не triggerить 2FA
  // повторно при возврате юзера на то же устройство.
  static const _secureDeviceId = 'gs_device_id_v1';
  static const _kDeviceName = 'gs_device_name';

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device),
  );

  // Кэш на сессию — чтобы не дёргать secure storage каждый раз.
  static String? _cachedToken;
  static bool _cacheReady = false;

  // Пароль логина/регистрации, переданный синхронизации ключей (server-режим:
  // восстановить/опубликовать приватник под паролем). НЕ персистится — живёт
  // в RAM. НЕ читается-и-стирается за один раз (как раньше) — иначе первая
  // же неудачная попытка синка (например транзиентная сетевая ошибка, не
  // связанная с самим паролем) стирала его, и KeyGate был вынужден спрашивать
  // пароль у юзера ещё раз, хотя он его только что ввёл при входе. Теперь
  // держим его до УСПЕШНОГО синка (clearPendingPwd) — так и ChatRepo.init(),
  // и KeyGate.needPassword-автопопытка могут использовать один и тот же
  // пароль, не спрашивая юзера дважды за один логин.
  static String? _pendingPwd;
  static String? peekPendingPwd() => _pendingPwd;
  static void clearPendingPwd() => _pendingPwd = null;

  static Future<String?> token() async {
    if (_cacheReady) return _cachedToken;
    try {
      _cachedToken = await _secure.read(key: _secureToken);
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
  static Future<bool> isGuest() async =>
      (await SharedPreferences.getInstance()).getBool(_kIsGuest) ?? false;

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
      appLog.warn('auth', 'device_id secure write failed, falling back to SharedPreferences: $e');
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
    final platform = Platform.operatingSystem; // 'android' / 'ios' / 'windows' / ...
    final cap = platform[0].toUpperCase() + platform.substring(1);
    final name = '$cap · ${did.substring(0, 4)}';
    await p.setString(_kDeviceName, name);
    return name;
  }

  static Future<void> setDeviceName(String name) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kDeviceName, name);
  }

  static Future<void> _saveAuth(
    Map d, {
    bool guest = false,
    String? password,
  }) async {
    // Пароль (логин/регистрация) → синхронизации ключей, одноразово.
    _pendingPwd = password;
    _cachedToken = d['token'] as String;
    _cacheReady = true;
    try {
      await _secure.write(key: _secureToken, value: _cachedToken!);
    } catch (e) {
      // Fallback
      final p = await SharedPreferences.getInstance();
      await p.setString(_secureToken, _cachedToken!);
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_kUsername, d['username'] as String);
    if (d['display_name'] != null) {
      await p.setString(_kDisplay, d['display_name'] as String);
    }
    await p.setBool(_kIsGuest, guest);
    if (d['seed_phrase'] != null) {
      // храним только hash чтобы юзер мог в будущем подтвердить (для recovery
      // настоящую фразу он должен записать сам — мы её НЕ храним).
      await p.setString(_kSeedHash, _hashSeed(d['seed_phrase'] as String));
    }
  }

  static Future<void> logout() async {
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
    await p.remove(_kIsGuest);
    await p.remove(_kSeedHash);
  }

  // ─── HTTP-ручки авторизации ──────────────────────────────────────────
  static final _dio = Dio(BaseOptions(
    baseUrl: GE.apiSoc,
    headers: {'Content-Type': 'application/json'},
    validateStatus: (s) => s != null && s < 500,
  ));

  /// Логин. Если аккаунт включил TDA (подтверждение новых устройств) и это
  /// устройство ещё не доверено — сервер НЕ выдаёт токен сразу, а возвращает
  /// {requires_approval: true, request_id, code, ...}. Код виден ЗДЕСЬ (на
  /// новом устройстве) — юзер вводит его на уже доверенном устройстве
  /// (Настройки → Устройства → Ожидают подтверждения), после чего это
  /// устройство поллит /devices/pending/{request_id}/status до token.
  /// НЕ сохраняем сессию в этом случае — только после подтверждения.
  static Future<Map<String, dynamic>> login(String username, String password) async {
    final did = await deviceId();
    final dname = await deviceName();
    final r = await _dio.post('/login',
        data: jsonEncode({
          'username': username,
          'password': password,
          'device_id': did,
          'device_name': dname,
          'platform': Platform.operatingSystem,
        }));
    if (r.statusCode != 200) throw _err(r.data, r.statusCode!);
    final d = Map<String, dynamic>.from(r.data);
    if (d['requires_approval'] == true) return d;
    await _saveAuth(d, password: password);
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
    final did = await deviceId();
    final dname = await deviceName();
    final r = await _dio.post('/register',
        data: jsonEncode({
          'username': username,
          'display_name': displayName,
          'password': password,
          'age_18_confirm': age18,
          if (ref != null) 'ref': ref,
          'device_id': did,
          'device_name': dname,
          'platform': Platform.operatingSystem,
        }));
    if (r.statusCode != 200) throw _err(r.data, r.statusCode!);
    final d = Map<String, dynamic>.from(r.data);
    await _saveAuth(d, password: password);
    return d;
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
    String hex(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${(8 + r.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }
}
