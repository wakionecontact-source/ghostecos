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

  ApiClient._internal() {
    _chat = _build(GE.apiChat);
    _soc = _build(GE.apiSoc);
  }

  Dio _build(String base) {
    final d = Dio(BaseOptions(
      baseUrl: base,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 60),
      validateStatus: (s) => s != null && s < 500,
    ));
    d.interceptors.add(InterceptorsWrapper(
      onRequest: (opts, handler) async {
        final token = await AuthService.token();
        if (token != null && token.isNotEmpty) {
          opts.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(opts);
      },
      onResponse: (resp, handler) {
        if (resp.statusCode != null && resp.statusCode! >= 400) {
          final msg = _extractError(resp.data);
          throw ApiException(resp.statusCode!, msg);
        }
        handler.next(resp);
      },
    ));
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
  }) async {
    final form = FormData.fromMap({
      'to_username': toUsername,
      'blob': MultipartFile.fromBytes(encryptedBytes, filename: name),
    });
    final r = await _chat.post('/file/upload', data: form);
    return Map<String, dynamic>.from(r.data);
  }

  /// Скачать зашифрованный blob по file_id (для receiver, после ack удалится).
  Future<List<int>?> downloadFile(int fileId) async {
    try {
      final r = await _chat.get(
        '/file/$fileId',
        options: Options(responseType: ResponseType.bytes),
      );
      return List<int>.from(r.data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }
}
