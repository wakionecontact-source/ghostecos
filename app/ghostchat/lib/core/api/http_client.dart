/// HTTP-клиент GhostChat поверх dio.
/// Автоматически добавляет Bearer-токен. Все запросы — только https (K.apiBase).
library;

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../app_version.dart';
import '../constants.dart';
import '../storage/secure_store.dart';
import '../../services/bot_check_service.dart';
import '../../services/proxy_http_client.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);
  @override
  String toString() => 'ApiException($statusCode): $message';

  bool get isAuth => statusCode == 401 || statusCode == 403;
  bool get isRateLimited => statusCode == 429;
}

class HttpClient {
  HttpClient._() {
    dio = Dio(
      BaseOptions(
        baseUrl: K.apiBase,
        connectTimeout: K.connectTimeout,
        receiveTimeout: K.receiveTimeout,
        headers: {'Content-Type': 'application/json'},
        // 4xx обрабатываем сами, 5xx → исключение dio
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: ProxyHttpClient.create,
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          options.headers[GhostChatAppVersion.headerName] =
              await GhostChatAppVersion.current();

          // Public update metadata/APK requests still use the configured
          // transport (including SOCKS5), but must not inherit account or
          // auth-CAPTCHA headers.  The update download supplies its own
          // purpose-scoped CAPTCHA token.
          if (options.extra['skipAuth'] == true) {
            handler.next(options);
            return;
          }
          final token = await SecureStore.I.token;
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          final botToken = BotCheckService.instance.cachedToken('auth');
          if (botToken != null && botToken.isNotEmpty) {
            options.headers['X-Ghost-Bot-Token'] = botToken;
          }
          handler.next(options);
        },
      ),
    );
  }
  static final HttpClient I = HttpClient._();

  late final Dio dio;

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final r = await dio.get(path, queryParameters: query);
      return _unwrap(r);
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  Future<Map<String, dynamic>> postJson(String path, {Object? body}) async {
    try {
      final r = await dio.post(path, data: body);
      return _unwrap(r);
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  Future<Map<String, dynamic>> deleteJson(String path, {Object? body}) async {
    try {
      final r = await dio.delete(path, data: body);
      return _unwrap(r);
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  Map<String, dynamic> _unwrap(Response r) {
    final code = r.statusCode ?? 0;
    if (code >= 200 && code < 300) {
      final data = r.data;
      if (data is Map<String, dynamic>) return data;
      return {'data': data};
    }
    throw ApiException(code, _extractMessage(r.data, code));
  }

  String _extractMessage(dynamic data, int code) {
    if (data is Map && data['detail'] != null) return data['detail'].toString();
    if (data is String && data.isNotEmpty) return data;
    return 'Ошибка $code';
  }

  ApiException _fromDio(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError) {
      return ApiException(0, 'Нет соединения с сервером');
    }
    final code = e.response?.statusCode ?? 0;
    return ApiException(code, _extractMessage(e.response?.data, code));
  }
}
