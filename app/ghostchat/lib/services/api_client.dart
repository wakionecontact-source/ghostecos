// HTTP-клиент к бэкенду Ghost.
//
// Базовые URL: GE.apiChat (https://.../api/chat) и GE.apiSoc (https://.../api/soc).
// Токен берётся из AuthService и автоматически добавляется в Authorization-хэдер.
// Ошибки бэка превращаются в ApiException.
//
// Использование:
//   final api = ApiClient();
//   final me = await api.socPost('/login', {...});
//   final dialogs = await api.chatGet('/contacts');
import 'package:dio/dio.dart';
import '../theme.dart';
import 'auth_service.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => 'ApiException($status): $message';
}

class ApiClient {
  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;

  late final Dio _chat;
  late final Dio _soc;
  late final Dio _core;

  ApiClient._internal() {
    _chat = _build(GE.apiChat);
    _soc = _build(GE.apiSoc);
    _core = _build(GE.apiCore);
  }

  Dio _build(String base) {
    final d = Dio(
      BaseOptions(
        baseUrl: base,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 60),
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    d.interceptors.add(
      InterceptorsWrapper(
        onRequest: (opts, handler) async {
          final token = await AuthService.token();
          if (token != null && token.isNotEmpty) {
            opts.headers['Authorization'] = 'Bearer $token';
          }
          // X-Device-Id: persistent UUID устройства — сервер требует для
          // multi-device delivery (без него fallback hash(token) → сообщения
          // дублируются/теряются по /pending). См. ответ Web/keys на .session_bus.
          opts.headers['X-Device-Id'] = await AuthService.deviceId();
          handler.next(opts);
        },
        onResponse: (resp, handler) {
          if (resp.statusCode != null && resp.statusCode! >= 400) {
            final msg = _extractError(resp.data);
            // Через handler.reject ApiException дойдёт до caller'а в .error
            // DioException — а сам caller увидит человеческий toString().
            handler.reject(
              DioException(
                requestOptions: resp.requestOptions,
                response: resp,
                type: DioExceptionType.badResponse,
                error: ApiException(resp.statusCode!, msg),
                message: msg,
              ),
            );
            return;
          }
          handler.next(resp);
        },
        onError: (err, handler) {
          // Если в err.error лежит наш ApiException — заменяем сообщение
          // на человеческое, чтобы print('$e') показывал текст ошибки.
          final inner = err.error;
          if (inner is ApiException) {
            handler.next(
              DioException(
                requestOptions: err.requestOptions,
                response: err.response,
                type: err.type,
                error: inner,
                message: inner.message,
              ),
            );
            return;
          }
          handler.next(err);
        },
      ),
    );
    return d;
  }

  String _extractError(dynamic data) {
    if (data is Map && data['detail'] != null) return data['detail'].toString();
    if (data is String) return data;
    return 'HTTP ошибка';
  }

  // ─── Социальные ручки ───────────────────────────────────────────────────
  Future<dynamic> socGet(String path, [Map<String, dynamic>? query]) async {
    final r = await _soc.get(path, queryParameters: query);
    return r.data;
  }

  Future<dynamic> socPost(String path, [dynamic body]) async {
    final r = await _soc.post(path, data: body);
    return r.data;
  }

  Future<dynamic> socPatch(String path, [dynamic body]) async {
    final r = await _soc.patch(path, data: body);
    return r.data;
  }

  Future<dynamic> socDelete(String path) async {
    final r = await _soc.delete(path);
    return r.data;
  }

  // ─── Core-профиль (display_name/about/avatar_bg_color/glow_color) ───────
  // Живёт на bare /api (backchat/routers/users.py), не под /chat и не /soc.
  Future<dynamic> coreGet(String path, [Map<String, dynamic>? query]) async {
    final r = await _core.get(path, queryParameters: query);
    return r.data;
  }

  Future<dynamic> corePost(String path, [dynamic body]) async {
    final r = await _core.post(path, data: body);
    return r.data;
  }

  // ─── Чат-ручки ──────────────────────────────────────────────────────────
  Future<dynamic> chatGet(String path, [Map<String, dynamic>? query]) async {
    final r = await _chat.get(path, queryParameters: query);
    return r.data;
  }

  Future<dynamic> chatPost(String path, [dynamic body]) async {
    final r = await _chat.post(path, data: body);
    return r.data;
  }

  Future<dynamic> chatDelete(String path, [Map<String, dynamic>? query]) async {
    final r = await _chat.delete(path, queryParameters: query);
    return r.data;
  }

  // ─── Загрузка файла (multipart) ─────────────────────────────────────────
  Future<Map<String, dynamic>> uploadFile({
    required String toUsername,
    required List<int> encryptedBytes,
    String name = 'enc',
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final form = FormData.fromMap({
      'to_username': toUsername,
      'blob': MultipartFile.fromBytes(encryptedBytes, filename: name),
    });
    final r = await _chat.post(
      '/file/upload',
      data: form,
      // Прогресс отдачи тела (для спиннера-% на медиа, как в TG).
      onSendProgress: onSendProgress,
      options: Options(
        // Большие медиа (видео 5-10 МБ) не успевают за дефолтные 30с →
        // DioException[receive timeout]. Поднимаем до 5 минут на upload.
        sendTimeout: const Duration(minutes: 5),
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
    return Map<String, dynamic>.from(r.data);
  }

  /// Загрузить картинку/видео/аудио на соц-бэк (/api/soc/upload).
  /// Возвращает {url, type, ...} как отдаёт сервер.
  Future<Map<String, dynamic>> uploadSocFile({
    required List<int> bytes,
    required String filename,
    String? mime,
  }) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: mime != null ? DioMediaType.parse(mime) : null,
      ),
    });
    final r = await _soc.post('/upload', data: form);
    return Map<String, dynamic>.from(r.data);
  }

  /// Загрузить свою аватарку (POST /api/soc/me/avatar) — jpeg/png/webp,
  /// сервер ресайзит до 512×512. Возвращает {avatar_url: "/media/avatars/.."}.
  Future<String> uploadOwnAvatar({
    required List<int> bytes,
    required String filename,
    String? mime,
  }) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: mime != null ? DioMediaType.parse(mime) : null,
      ),
    });
    final r = await _soc.post('/me/avatar', data: form);
    return Map<String, dynamic>.from(r.data)['avatar_url'] as String;
  }

  /// Снять свою аватарку.
  Future<void> deleteOwnAvatar() async {
    await _soc.delete('/me/avatar');
  }

  /// Скачать зашифрованный blob по file_id (для receiver, после ack удалится).
  Future<List<int>?> downloadFile(int fileId) async {
    try {
      final r = await _chat.get(
        '/file/$fileId',
        options: Options(
          responseType: ResponseType.bytes,
          // Чужое видео 5-10 МБ не успевает скачаться за дефолтные 30с.
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      return List<int>.from(r.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }
}
