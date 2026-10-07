import 'dart:io' show Platform;
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import 'settings_service.dart';

class AuthService {
  static final AuthService instance = AuthService._();
  AuthService._();

  static const _kToken = 'gg_gs_token';
  static const _kUsername = 'gg_username';
  static const _kDisplay = 'gg_display_name';
  static const _kUserId = 'gg_user_id';
  static const _kIsGuest = 'gg_is_guest';

  final Dio _dio = Dio(BaseOptions(
    baseUrl: '${GG.baseUrl}/api/soc',
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    headers: {'Content-Type': 'application/json'},
    validateStatus: (s) => s != null && s < 500,
  ));

  Future<String?> token() async =>
      (await SharedPreferences.getInstance()).getString(_kToken);
  Future<String?> username() async =>
      (await SharedPreferences.getInstance()).getString(_kUsername);
  Future<String?> displayName() async =>
      (await SharedPreferences.getInstance()).getString(_kDisplay);
  Future<bool> isGuest() async =>
      (await SharedPreferences.getInstance()).getBool(_kIsGuest) ?? false;

  Future<bool> hasSession() async {
    final t = await token();
    return t != null && t.isNotEmpty;
  }

  /// Перечитать префы с диска (второй процесс мог сохранить сессию).
  Future<bool> refreshSession() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    final t = p.getString(_kToken);
    if (t != null && t.isNotEmpty) {
      await SettingsService.instance.setGsToken(t);
      return true;
    }
    return false;
  }

  Future<void> _save(Map d, {bool guest = false}) async {
    final p = await SharedPreferences.getInstance();
    final tok = (d['token'] ?? '').toString();
    await p.setString(_kToken, tok);
    await SettingsService.instance.setGsToken(tok);
    await p.setString(_kUsername, (d['username'] ?? '').toString());
    await p.setString(_kDisplay, (d['display_name'] ?? d['username'] ?? '').toString());
    final uid = d['user_id'] ?? d['id'];
    if (uid != null) await p.setString(_kUserId, uid.toString());
    await p.setBool(_kIsGuest, guest);
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final r = await _dio.post('/login', data: {
      'username': username.trim().toLowerCase(),
      'password': password,
      'device_name': 'GhostGem ${Platform.operatingSystem}',
      'platform': Platform.operatingSystem,
    });
    if (r.statusCode != 200) throw _err(r.data, r.statusCode ?? 0);
    final d = Map<String, dynamic>.from(r.data as Map);
    if (d['requires_approval'] == true) {
      throw StateError('Устройство требует подтверждения: код ${d['code']} — введи его на доверенном устройстве');
    }
    await _save(d);
    return d;
  }

  Future<Map<String, dynamic>> register({
    required String username,
    required String displayName,
    required String password,
  }) async {
    final r = await _dio.post('/register', data: {
      'username': username.trim().toLowerCase(),
      'display_name': displayName.trim(),
      'password': password,
      'age_18_confirm': true,
      'device_name': 'GhostGem ${Platform.operatingSystem}',
      'platform': Platform.operatingSystem,
    });
    if (r.statusCode != 200) throw _err(r.data, r.statusCode ?? 0);
    final d = Map<String, dynamic>.from(r.data as Map);
    await _save(d);
    return d;
  }

  Future<Map<String, dynamic>> loginAsGuest() async {
    try {
      final r = await _dio.post('/guest');
      if (r.statusCode == 200) {
        final d = Map<String, dynamic>.from(r.data as Map);
        await _save(d, guest: true);
        return d;
      }
    } catch (_) {}
    // оффлайн-гость: без сервера, только Work + anon
    final d = {
      'token': '',
      'username': 'guest',
      'display_name': 'Гость',
    };
    await _save(d, guest: true);
    return d;
  }

  /// Сессия с сайта /v2/auth: токен уже есть (из localStorage страницы),
  /// проверяем его через /me и сохраняем как обычную сессию.
  Future<Map<String, dynamic>> saveSiteSession(String token) async {
    final clean = token.trim().replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');
    if (clean.isEmpty || clean.startsWith('guest_')) {
      throw StateError('На сайте нет активной сессии — войди там и обнови страницу');
    }
    final r = await _dio.get(
      '/me',
      options: Options(headers: {'Authorization': 'Bearer $clean'}),
    );
    if (r.statusCode != 200) throw _err(r.data, r.statusCode ?? 0);
    final me = Map<String, dynamic>.from(r.data as Map);
    final d = {
      'token': clean,
      'username': me['username'],
      'display_name': me['display_name'] ?? me['username'],
      'user_id': me['user_id'] ?? me['id'],
    };
    await _save(d);
    return d;
  }

  Future<void> logout() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kToken);
    await p.remove(_kUsername);
    await p.remove(_kDisplay);
    await p.remove(_kUserId);
    await p.remove(_kIsGuest);
    await SettingsService.instance.setGsToken('');
  }

  String _err(dynamic data, int status) {
    if (data is Map && data['detail'] != null) return data['detail'].toString();
    return 'HTTP $status';
  }
}
