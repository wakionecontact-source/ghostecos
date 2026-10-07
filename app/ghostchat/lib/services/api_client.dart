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
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import '../core/app_version.dart';
import '../theme.dart';
import 'auth_service.dart';
import 'bot_check_service.dart';
import 'proxy_http_client.dart';
import 'password_auth_protocol.dart';
import '../core/local/app_logger.dart';

enum ApiAuthFailure {
  none,
  missingToken,
  invalidHeader,
  invalidToken,
  expiredToken,
  revokedToken,
}

class ApiException implements Exception {
  final int status;
  final String message;
  final ApiAuthFailure authFailure;
  ApiException(
    this.status,
    this.message, {
    this.authFailure = ApiAuthFailure.none,
  });

  bool get isMissingToken => authFailure == ApiAuthFailure.missingToken;
  bool get isInvalidHeader => authFailure == ApiAuthFailure.invalidHeader;
  bool get isInvalidToken => authFailure == ApiAuthFailure.invalidToken;
  bool get isExpiredToken => authFailure == ApiAuthFailure.expiredToken;
  bool get isRevokedToken => authFailure == ApiAuthFailure.revokedToken;
  bool get invalidatesSession =>
      isInvalidToken || isExpiredToken || isRevokedToken;

  @override
  String toString() => 'ApiException($status): $message';
}

class OwnPasswordChallengeProof {
  final String challengeId;
  final String clientProof;
  final String expectedServerProof;

  const OwnPasswordChallengeProof({
    required this.challengeId,
    required this.clientProof,
    required this.expectedServerProof,
  });
}

class ApiClient {
  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;

  late final Dio _chat;
  late final Dio _soc;
  late final Dio _ghosou;
  late final Dio _core;
  late final Dio _bots;
  final Map<String, Dio> _serviceClients = {};
  final Map<String, List<String>> _serviceCandidates = {};
  late final Dio _discoveryDio = _createDiscoveryDio();
  DateTime? _lastDiscoveryAttempt;
  DateTime? _lastDiscoverySuccess;
  Future<void>? _serviceConfigLoad;
  String _serviceHealthPath = '/api/soc/health';

  ApiClient._internal() {
    _chat = _build('chat', GE.apiChat);
    _soc = _build('soc', GE.apiSoc);
    _ghosou = _build('root', GE.baseUrl);
    _core = _build('core', GE.apiCore);
    _bots = _build('bots', GE.apiBots);
    unawaited(_discoverAllServiceBases());
  }

  Dio _build(String serviceKey, String base) {
    final service = _serviceLabel(base);
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
          appLog.debug('api', '${opts.method} ${service}${opts.path}');
          opts.headers[GhostChatAppVersion.headerName] =
              await GhostChatAppVersion.current();
          final token = await AuthService.token();
          if (token != null && token.isNotEmpty) {
            opts.headers['Authorization'] = 'Bearer $token';
          }
          final botToken = BotCheckService.instance.cachedToken('auth');
          if (botToken != null && botToken.isNotEmpty) {
            opts.headers['X-Ghost-Bot-Token'] = botToken;
          }
          // X-Device-Id: persistent UUID устройства — сервер требует для
          // multi-device delivery (без него fallback hash(token) → сообщения
          // дублируются/теряются по /pending). См. ответ Web/keys на .session_bus.
          opts.headers['X-Device-Id'] = await AuthService.deviceId();
          handler.next(opts);
        },
        onResponse: (resp, handler) async {
          if (resp.statusCode == 404 &&
              (resp.requestOptions.method == 'GET' ||
                  resp.requestOptions.method == 'HEAD') &&
              resp.requestOptions.extra['gc_endpoint_retry'] != true) {
            final oldBase = resp.requestOptions.baseUrl;
            final replacement = await _discoverServiceBase(
              serviceKey,
              excludeBase: oldBase,
              updateClient: false,
            );
            if (replacement != null && replacement != oldBase) {
              try {
                final retry = await d.fetch<dynamic>(
                  resp.requestOptions.copyWith(
                    baseUrl: replacement,
                    extra: {
                      ...resp.requestOptions.extra,
                      'gc_endpoint_retry': true,
                    },
                  ),
                );
                d.options.baseUrl = replacement;
                handler.resolve(retry);
                return;
              } catch (_) {
                // Preserve the original 404 if the discovered endpoint is
                // unavailable too; discovery must never hide the API error.
              }
            }
          }
          if (resp.statusCode != null && resp.statusCode! >= 400) {
            final rawMessage = _extractError(resp.data);
            final authFailure = _classifyAuthFailure(
              resp.statusCode!,
              rawMessage,
              resp.requestOptions,
            );
            final msg = _authMessage(rawMessage, authFailure);
            final apiError = ApiException(
              resp.statusCode!,
              msg,
              authFailure: authFailure,
            );
            if (apiError.invalidatesSession) {
              // Не блокируем обработку ответа удалением secure storage.
              unawaited(AuthService.invalidateSession(reason: msg));
            }
            // Через handler.reject ApiException дойдёт до caller'а в .error
            // DioException — а сам caller увидит человеческий toString().
            handler.reject(
              DioException(
                requestOptions: resp.requestOptions,
                response: resp,
                type: DioExceptionType.badResponse,
                error: apiError,
                message: msg,
              ),
            );
            return;
          }
          appLog.debug(
            'api',
            '${resp.requestOptions.method} $service${resp.requestOptions.path} '
                '→ ${resp.statusCode}',
          );
          handler.next(resp);
        },
        onError: (err, handler) async {
          final request = err.requestOptions;
          final safeToRetry =
              request.method == 'GET' || request.method == 'HEAD';
          final status = err.response?.statusCode;
          final canDiscover =
              safeToRetry &&
              request.extra['gc_endpoint_retry'] != true &&
              (err.type == DioExceptionType.connectionError ||
                  err.type == DioExceptionType.connectionTimeout ||
                  err.type == DioExceptionType.receiveTimeout ||
                  (status != null && status >= 500));
          if (canDiscover) {
            final replacement = await _discoverServiceBase(
              serviceKey,
              excludeBase: request.baseUrl,
              updateClient: false,
            );
            if (replacement != null && replacement != request.baseUrl) {
              try {
                final retry = await d.fetch<dynamic>(
                  request.copyWith(
                    baseUrl: replacement,
                    extra: {...request.extra, 'gc_endpoint_retry': true},
                  ),
                );
                d.options.baseUrl = replacement;
                handler.resolve(retry);
                return;
              } catch (_) {
                // Keep the original connection failure if the alternate also
                // fails; endpoint discovery must not hide the API error.
              }
            }
          }
          // Если в err.error лежит наш ApiException — заменяем сообщение
          // на человеческое, чтобы print('$e') показывал текст ошибки.
          final inner = err.error;
          if (inner is ApiException) {
            appLog.error(
              'api',
              '${err.requestOptions.method} $service${err.requestOptions.path} '
                  '→ ${inner.status}: ${inner.message}',
            );
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
          appLog.error(
            'api',
            '${err.requestOptions.method} $service${err.requestOptions.path} '
                '→ ${err.type}: ${err.message ?? err.error}',
          );
          handler.next(err);
        },
      ),
    );
    _applyProxy(d);
    _serviceClients[serviceKey] = d;
    return d;
  }

  Dio _createDiscoveryDio() {
    final client = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    client.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          options.headers[GhostChatAppVersion.headerName] =
              await GhostChatAppVersion.current();
          handler.next(options);
        },
      ),
    );
    _applyProxy(client);
    return client;
  }

  Future<void> _discoverAllServiceBases() async {
    await _ensureServiceConfig();
    await Future.wait(
      _serviceClients.keys.map((key) => _discoverServiceBase(key)),
    );
  }

  Future<String?> _discoverServiceBase(
    String serviceKey, {
    String? excludeBase,
    bool updateClient = true,
  }) async {
    await _ensureServiceConfig();
    final candidates = _serviceCandidates[serviceKey] ?? const <String>[];
    final eligible = candidates
        .where((candidate) => candidate != excludeBase)
        .toList();
    final healthy = await Future.wait(eligible.map(_probeServiceBase));
    for (var index = 0; index < eligible.length; index++) {
      if (!healthy[index]) continue;
      final candidate = eligible[index];
      final client = _serviceClients[serviceKey];
      if (updateClient && client != null) {
        client.options.baseUrl = candidate;
      }
      appLog.info('api', 'selected healthy endpoint for $serviceKey');
      return candidate;
    }
    return null;
  }

  /// Builds WSS endpoints from the same trusted root-service list used by
  /// automatic API discovery. The configured host remains the final fallback.
  Future<List<Uri>> webSocketEndpointCandidates() async {
    await _ensureServiceConfig();
    final endpoints = <Uri>[];
    for (final base in _serviceCandidates['soc'] ?? const <String>[]) {
      final uri = Uri.tryParse(base);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) continue;
      final endpoint = uri.replace(
        scheme: 'wss',
        path: '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/ws',
        query: null,
        fragment: null,
      );
      if (!endpoints.contains(endpoint)) endpoints.add(endpoint);
    }
    final fallback = Uri.parse(GE.wsUrl);
    if (!endpoints.contains(fallback)) endpoints.add(fallback);
    return endpoints;
  }

  Future<void> _ensureServiceConfig() async {
    final inFlight = _serviceConfigLoad;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final now = DateTime.now();
    final lastSuccess = _lastDiscoverySuccess;
    if (lastSuccess != null &&
        now.difference(lastSuccess) < const Duration(minutes: 5)) {
      return;
    }
    final lastAttempt = _lastDiscoveryAttempt;
    if (lastAttempt != null &&
        now.difference(lastAttempt) < const Duration(seconds: 15)) {
      return;
    }

    _lastDiscoveryAttempt = now;
    final load = _fetchServiceConfig();
    _serviceConfigLoad = load;
    try {
      await load;
    } finally {
      if (identical(_serviceConfigLoad, load)) _serviceConfigLoad = null;
    }
  }

  Future<void> _fetchServiceConfig() async {
    try {
      final response = await _discoveryDio.get<dynamic>(
        '${GE.baseUrl}/api/soc/client-config',
        options: Options(
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
        ),
      );
      if (response.statusCode != 200 || response.data is! Map) return;
      final config = Map<String, dynamic>.from(response.data as Map);
      final healthPath = config['health_path']?.toString();
      if (healthPath != null &&
          healthPath.startsWith('/') &&
          !healthPath.startsWith('//') &&
          !healthPath.contains('?') &&
          !healthPath.contains('#')) {
        _serviceHealthPath = healthPath;
      }
      final services = config['services'];
      if (services is! Map) return;
      _serviceCandidates.clear();
      var foundEndpoint = false;
      for (final entry in services.entries) {
        final key = entry.key.toString();
        final rawValues = entry.value is Iterable
            ? (entry.value as Iterable).toList()
            : <dynamic>[entry.value];
        final candidates = <String>[];
        for (final value in rawValues.take(8)) {
          final raw = value?.toString().trim() ?? '';
          if (raw.isEmpty) continue;
          final uri = Uri.tryParse(raw);
          final resolved = uri != null && uri.hasScheme
              ? uri
              : Uri.parse(GE.baseUrl).resolve(raw);
          if (resolved.scheme != 'https' ||
              resolved.host.isEmpty ||
              resolved.userInfo.isNotEmpty ||
              resolved.hasFragment ||
              resolved.hasQuery) {
            continue;
          }
          final normalized = resolved.toString().replaceFirst(
            RegExp(r'/+$'),
            '',
          );
          if (!candidates.contains(normalized)) candidates.add(normalized);
          foundEndpoint = true;
        }
        _serviceCandidates[key] = candidates;
      }
      if (foundEndpoint) _lastDiscoverySuccess = DateTime.now();
    } catch (e) {
      appLog.warn('api', 'endpoint discovery failed: $e');
    }
  }

  Future<bool> _probeServiceBase(String base) async {
    try {
      final uri = Uri.parse(base);
      final probe = uri.replace(
        path: _serviceHealthPath,
        query: null,
        fragment: null,
      );
      final response = await _discoveryDio.get<dynamic>(
        probe.toString(),
        options: Options(
          connectTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      return response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300;
    } catch (_) {
      return false;
    }
  }

  String _serviceLabel(String base) {
    final path = Uri.tryParse(base)?.path ?? base;
    if (path.isEmpty || path == '/') return '';
    return path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  }

  // Прокси — опциональный, настраивается в Настройки → Сеть. Фабрика
  // одинаково поддерживает HTTP и настоящий SOCKS5 CONNECT.
  void _applyProxy(Dio d) {
    d.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: ProxyHttpClient.create,
    );
  }

  /// Вызывается из Настройки → Сеть после сохранения — пересоздаёт адаптеры
  /// всех клиентов с новым правилом прокси, без перезапуска приложения.
  void applyProxySettings() {
    _applyProxy(_chat);
    _applyProxy(_soc);
    _applyProxy(_ghosou);
    _applyProxy(_core);
    _applyProxy(_bots);
    _applyProxy(_discoveryDio);
  }

  String _extractError(dynamic data) {
    final detail = data is Map && data['detail'] != null
        ? data['detail']
        : null;
    if (detail is List) {
      for (final item in detail) {
        if (item is! Map) continue;
        final rawLoc = item['loc'];
        final loc = rawLoc is List
            ? rawLoc.map((part) => part.toString()).join('.')
            : rawLoc?.toString() ?? '';
        final type = item['type']?.toString().toLowerCase() ?? '';
        final message = item['msg']?.toString().toLowerCase() ?? '';
        if (loc.contains('ciphertext') &&
            (type.contains('too_long') ||
                message.contains('too long') ||
                message.contains('max'))) {
          return 'Служебные данные сообщения превышают лимит сервера';
        }
      }
    }
    if (detail != null) return detail.toString();
    if (data is String) return data;
    return 'HTTP ошибка';
  }

  ApiAuthFailure _classifyAuthFailure(
    int status,
    String message,
    RequestOptions options,
  ) {
    if (status != 401) return ApiAuthFailure.none;
    final lower = message.trim().toLowerCase();
    if (lower.contains('expired') ||
        lower.contains('истёк') ||
        lower.contains('истек')) {
      return ApiAuthFailure.expiredToken;
    }
    if (lower.contains('revoked') || lower.contains('отозван')) {
      return ApiAuthFailure.revokedToken;
    }
    if (lower.contains('missing') || lower.contains('отсутств')) {
      return ApiAuthFailure.missingToken;
    }
    if (lower.contains('authorization header') || lower.contains('заголов')) {
      return ApiAuthFailure.invalidHeader;
    }
    if (lower.contains('invalid token') || lower.contains('недействитель')) {
      return ApiAuthFailure.invalidToken;
    }

    // Старый сервер мог ответить общим Unauthorized. Если Bearer реально
    // ушёл в запросе, это отказ сохранённого токена. При этом не считаем
    // недействительной сессией любой произвольный 401: например, "Неверный
    // пароль" тоже может быть ответом защищённой ручки.
    final header = options.headers['Authorization']?.toString() ?? '';
    final genericAuthError =
        lower == 'unauthorized' ||
        lower == 'не авторизован' ||
        lower == 'не авторизовано' ||
        lower.contains('authentication required');
    if (genericAuthError &&
        header.toLowerCase().startsWith('bearer ') &&
        header.substring(7).trim().isNotEmpty) {
      return ApiAuthFailure.invalidToken;
    }
    if (genericAuthError) return ApiAuthFailure.missingToken;
    return ApiAuthFailure.none;
  }

  String _authMessage(String raw, ApiAuthFailure failure) {
    switch (failure) {
      case ApiAuthFailure.invalidToken:
        return 'Недействительный токен';
      case ApiAuthFailure.expiredToken:
        return 'Срок действия токена истёк';
      case ApiAuthFailure.revokedToken:
        return 'Токен отозван';
      case ApiAuthFailure.missingToken:
        return 'Токен отсутствует';
      case ApiAuthFailure.invalidHeader:
        return 'Неверный заголовок авторизации';
      case ApiAuthFailure.none:
        return raw;
    }
  }

  // ─── Социальные ручки ───────────────────────────────────────────────────
  Future<dynamic> socGet(String path, [Map<String, dynamic>? query]) async {
    final r = await _soc.get(path, queryParameters: query);
    return r.data;
  }

  /// GhoSou is mounted under the same ecosystem host but authenticates with
  /// the shared GhostEcos token header. Catalog reads never publish anything.
  Future<dynamic> ghosouGet(String path, [Map<String, dynamic>? query]) async {
    final token = await AuthService.token();
    final r = await _ghosou.get(
      path,
      queryParameters: query,
      options: Options(
        headers: {if (token != null && token.isNotEmpty) 'X-GS-Token': token},
      ),
    );
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

  /// Загрузить собственный профиль через актуальный Social API.
  Future<Map<String, dynamic>> getOwnProfile() async {
    final r = await _soc.get('/me');
    return Map<String, dynamic>.from(r.data as Map);
  }

  /// Проверить текущий пароль без изменения профиля.
  Future<Map<String, dynamic>> verifyOwnPassword(String password) async {
    final proof = await createOwnPasswordChallengeProof(password, context: '');
    final response = await _soc.post(
      '/auth/v2/password/verify',
      data: {'challenge_id': proof.challengeId, 'proof': proof.clientProof},
    );
    final result = Map<String, dynamic>.from(response.data as Map);
    if (!verifyOwnPasswordServerProof(
      proof.expectedServerProof,
      result['server_proof'],
    )) {
      throw StateError('Не удалось подтвердить сервер авторизации');
    }
    return result;
  }

  /// Create a password proof bound to a specific server-side action.
  /// The password itself is never sent over HTTP.
  Future<OwnPasswordChallengeProof> createOwnPasswordChallengeProof(
    String password, {
    required String context,
  }) async {
    if (context.length > 128) {
      throw ArgumentError.value(context, 'context', 'Не более 128 символов');
    }
    final nonce = PasswordAuthProtocol.newNonce();
    final challengeResponse = await _soc.post(
      '/auth/v2/password/challenge',
      data: {
        'purpose': 'verify_password',
        'client_nonce': nonce,
        'context': context,
      },
    );
    final challenge = Map<String, dynamic>.from(challengeResponse.data as Map);
    if (challenge['client_nonce'] != nonce ||
        challenge['context'] != context ||
        challenge['purpose'] != 'verify_password') {
      throw StateError('Сервер вернул некорректный запрос проверки пароля');
    }
    final result = await PasswordAuthProtocol.prove(password, challenge);
    final challengeId = challenge['challenge_id'];
    if (challengeId is! String || challengeId.isEmpty) {
      throw StateError('Сервер не вернул идентификатор проверки пароля');
    }
    return OwnPasswordChallengeProof(
      challengeId: challengeId,
      clientProof: result.clientProof,
      expectedServerProof: result.expectedServerProof,
    );
  }

  bool verifyOwnPasswordServerProof(String expected, dynamic received) =>
      PasswordAuthProtocol.verifyServerProof(expected, received);

  /// Обновить данные своего профиля через актуальный Social API.
  ///
  /// Любой настоящий 401 обрабатывается общим interceptor'ом и инвалидирует
  /// сессию. Поэтому здесь важен именно актуальный Social API route.
  Future<Map<String, dynamic>> updateOwnProfile({
    String? displayName,
    String? about,
    String? username,
    String? oldPassword,
    String? newPassword,
    Map<String, dynamic>? banner,
    bool clearBanner = false,
    dynamic profileMusic,
    bool clearMusic = false,
  }) async {
    final data = <String, dynamic>{
      if (displayName != null) 'display_name': displayName,
      if (about != null) 'about': about,
      if (username != null) 'username': username,
      if (banner != null) 'banner': banner,
      if (clearBanner) 'banner_clear': true,
      if (profileMusic != null) 'profile_music': profileMusic,
      if (clearMusic) 'music_clear': true,
    };
    if (data.isEmpty) {
      throw ArgumentError('Профиль не содержит изменений');
    }

    if (username != null || newPassword != null) {
      if (oldPassword == null || oldPassword.isEmpty) {
        throw ArgumentError('Для этого изменения требуется текущий пароль');
      }
      final verifier = newPassword == null
          ? null
          : await PasswordAuthProtocol.createVerifier(newPassword);
      final context = verifier == null
          ? ''
          : await PasswordAuthProtocol.contextForVerifier(verifier);
      final nonce = PasswordAuthProtocol.newNonce();
      final challengeResponse = await _soc.post(
        '/auth/v2/password/challenge',
        data: {
          'purpose': verifier == null ? 'verify_password' : 'change_password',
          'client_nonce': nonce,
          'context': context,
        },
      );
      final challenge = Map<String, dynamic>.from(
        challengeResponse.data as Map,
      );
      if (challenge['client_nonce'] != nonce ||
          challenge['context'] != context) {
        throw StateError('Сервер вернул некорректный запрос смены пароля');
      }
      final proof = await PasswordAuthProtocol.prove(oldPassword, challenge);
      data['password_challenge_id'] = challenge['challenge_id'];
      data['password_proof'] = proof.clientProof;
      if (verifier != null) data['new_password_verifier'] = verifier;

      final response = await _soc.patch('/me/profile', data: data);
      final result = Map<String, dynamic>.from(response.data as Map);
      if (!PasswordAuthProtocol.verifyServerProof(
        proof.expectedServerProof,
        result['server_proof'],
      )) {
        throw StateError('Не удалось подтвердить сервер авторизации');
      }
      return result;
    }

    final r = await _soc.patch('/me/profile', data: data);
    return Map<String, dynamic>.from(r.data as Map);
  }

  Future<dynamic> socDelete(String path) async {
    final r = await _soc.delete(path);
    return r.data;
  }

  Future<dynamic> coreDelete(String path, [dynamic body]) async {
    final r = await _core.delete(path, data: body);
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

  /// Upload an image to a chat service endpoint using the same authenticated
  /// Dio client as ordinary room requests.
  Future<Map<String, dynamic>> uploadChatFile({
    required String path,
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
    final r = await _chat.post(
      path,
      data: form,
      options: Options(
        sendTimeout: const Duration(minutes: 5),
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
    return Map<String, dynamic>.from(r.data as Map);
  }

  Future<List<int>?> downloadChatFile(String path) async {
    try {
      final r = await _chat.get(
        path,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(minutes: 5),
        ),
      );
      return List<int>.from(r.data as List);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<dynamic> chatPatch(String path, [dynamic body]) async {
    final r = await _chat.patch(path, data: body);
    return r.data;
  }

  Future<dynamic> chatDelete(String path, [Map<String, dynamic>? query]) async {
    final r = await _chat.delete(path, queryParameters: query);
    return r.data;
  }

  // ─── Bot API (создание своих ботов, /api/bots) ──────────────────────────
  Future<dynamic> botsGet(String path, [Map<String, dynamic>? query]) async {
    final r = await _bots.get(path, queryParameters: query);
    return r.data;
  }

  Future<dynamic> botsPost(String path, [dynamic body]) async {
    final r = await _bots.post(path, data: body);
    return r.data;
  }

  Future<dynamic> botsPut(String path, [dynamic body]) async {
    final r = await _bots.put(path, data: body);
    return r.data;
  }

  Future<dynamic> botsDelete(String path) async {
    final r = await _bots.delete(path);
    return r.data;
  }

  /// Upload a bot's public profile avatar through the owner-authenticated
  /// Bot API. The server applies the same image validation and resizing used
  /// for human profile avatars.
  Future<String> uploadBotAvatar({
    required int botId,
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
    final r = await _bots.post(
      '/$botId/avatar',
      data: form,
      options: Options(
        sendTimeout: const Duration(minutes: 2),
        receiveTimeout: const Duration(minutes: 2),
      ),
    );
    return Map<String, dynamic>.from(r.data as Map)['avatar_url'] as String;
  }

  Future<void> deleteBotAvatar(int botId) async {
    await _bots.delete('/$botId/avatar');
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

  /// Потоковая загрузка уже зашифрованного файла с диска. В отличие от
  /// uploadFile, Dio не создаёт вторую копию всего вложения в памяти.
  Future<Map<String, dynamic>> uploadFileFromPath({
    required String toUsername,
    required String encryptedPath,
    String name = 'encrypted.bin',
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final part = await MultipartFile.fromFile(encryptedPath, filename: name);
    final form = FormData.fromMap({'to_username': toUsername, 'blob': part});
    final response = await _chat.post(
      '/file/upload',
      data: form,
      onSendProgress: onSendProgress,
      options: Options(
        sendTimeout: const Duration(minutes: 30),
        receiveTimeout: const Duration(minutes: 30),
      ),
    );
    final status = response.statusCode ?? 500;
    if (status >= 400) {
      final body = response.data;
      final message = body is Map
          ? (body['detail'] ?? body['message'] ?? 'Ошибка загрузки файла')
                .toString()
          : 'Ошибка загрузки файла';
      throw ApiException(status, message);
    }
    return Map<String, dynamic>.from(response.data as Map);
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

  /// Upload a profile-only track. This endpoint extracts common tags and an
  /// embedded cover, but deliberately does not create a public GhoSou entry.
  Future<Map<String, dynamic>> uploadProfileMusic({
    required List<int> bytes,
    required String filename,
    String? mime,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: mime != null ? DioMediaType.parse(mime) : null,
      ),
    });
    final r = await _soc.post(
      '/profile-music/upload',
      data: form,
      onSendProgress: onSendProgress,
      options: Options(
        sendTimeout: const Duration(minutes: 5),
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
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

  /// Скачивает шифротекст сразу на диск, не создавая Uint8List размером с файл.
  Future<bool> downloadFileToPath({
    required int fileId,
    required String destinationPath,
    void Function(int received, int total)? onReceiveProgress,
  }) async {
    try {
      final response = await _chat.download(
        '/file/$fileId',
        destinationPath,
        onReceiveProgress: onReceiveProgress,
        options: Options(
          receiveTimeout: const Duration(minutes: 30),
          sendTimeout: const Duration(minutes: 2),
        ),
      );
      final status = response.statusCode ?? 500;
      if (status == 404) return false;
      if (status >= 400) {
        throw ApiException(status, 'Не удалось скачать вложение');
      }
      return true;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return false;
      rethrow;
    }
  }
}
