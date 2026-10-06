import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_version.dart';
import '../core/constants.dart';
import '../core/local/app_logger.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/error_panel.dart';
import '../widgets/toast_overlay.dart';
import 'proxy_http_client.dart';

class BotCheckException implements Exception {
  final String message;
  const BotCheckException(this.message);

  @override
  String toString() => message;
}

class _BotCapability {
  final String token;
  final DateTime expiresAt;

  const _BotCapability(this.token, this.expiresAt);

  bool get usable =>
      DateTime.now().isBefore(expiresAt.subtract(const Duration(seconds: 30)));
}

class _CaptchaChallenge {
  final String id;
  final String purpose;
  final Uint8List image;
  final int length;

  const _CaptchaChallenge({
    required this.id,
    required this.purpose,
    required this.image,
    required this.length,
  });
}

/// Получает короткоживущий capability-токен после визуальной CAPTCHA.
/// Токен не является сессией и не заменяет Bearer-токен аккаунта.
class BotCheckService {
  BotCheckService._() {
    for (final dio in [_dio, _downloadDio]) {
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            options.headers[GhostChatAppVersion.headerName] =
                await GhostChatAppVersion.current();
            handler.next(options);
          },
        ),
      );
    }
    // The update CAPTCHA must follow the same user-selected proxy as the APK
    // stream itself; otherwise the first half of the flow could fail behind a
    // restricted network even though the download would be reachable.
    _downloadDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: ProxyHttpClient.create,
    );
  }
  static final BotCheckService instance = BotCheckService._();

  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: GE.apiSoc,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      validateStatus: (status) => status != null && status < 500,
    ),
  );
  // Update APK CAPTCHA belongs to the relay API (8080/8000 contour), while
  // legacy auth/social CAPTCHA stays on /api/soc. Keep both paths explicit.
  final Dio _downloadDio = Dio(
    BaseOptions(
      baseUrl: K.apiBase,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      validateStatus: (status) => status != null && status < 500,
    ),
  );
  final Map<String, _BotCapability> _capabilities = {};
  final Map<String, Future<String>> _inFlight = {};

  String? cachedToken(String purpose) {
    final capability = _capabilities[purpose];
    if (capability == null || !capability.usable) {
      _capabilities.remove(purpose);
      return null;
    }
    return capability.token;
  }

  Future<String> ensureToken(BuildContext context, {String purpose = 'auth'}) {
    final cached = cachedToken(purpose);
    if (cached != null) return Future.value(cached);
    final running = _inFlight[purpose];
    if (running != null) return running;
    final future = _issueToken(context, purpose);
    _inFlight[purpose] = future;
    return future.whenComplete(() {
      if (identical(_inFlight[purpose], future)) _inFlight.remove(purpose);
    });
  }

  Future<_CaptchaChallenge> _fetchChallenge(String purpose) async {
    try {
      final dio = purpose == 'download' ? _downloadDio : _dio;
      final path = purpose == 'download'
          ? '/api/bot-check/challenge'
          : '/bot-check/challenge';
      final response = await dio.get(
        path,
        queryParameters: {'purpose': purpose},
        options: Options(headers: {'Cache-Control': 'no-store'}),
      );
      if (response.statusCode != 200 || response.data is! Map) {
        throw const BotCheckException('CAPTCHA сейчас недоступна');
      }
      final data = Map<String, dynamic>.from(response.data as Map);
      final rawImage = '${data['image'] ?? ''}';
      final comma = rawImage.indexOf(',');
      if (comma < 0 || !rawImage.startsWith('data:image/png;base64,')) {
        throw const BotCheckException('Сервер прислал неверную CAPTCHA');
      }
      final id = '${data['challenge_id'] ?? ''}'.trim();
      final length = int.tryParse('${data['length'] ?? 5}') ?? 5;
      if (id.isEmpty || length < 3 || length > 8) {
        throw const BotCheckException('Сервер прислал неверную CAPTCHA');
      }
      return _CaptchaChallenge(
        id: id,
        purpose: purpose,
        image: base64Decode(rawImage.substring(comma + 1)),
        length: length,
      );
    } on BotCheckException {
      rethrow;
    } on DioException catch (e) {
      appLog.warn(
        'bot',
        'CAPTCHA challenge request failed status=${e.response?.statusCode}',
      );
      throw const BotCheckException('Не удалось загрузить CAPTCHA');
    } catch (e) {
      appLog.warn('bot', 'CAPTCHA challenge parse failed: $e');
      throw const BotCheckException('Не удалось загрузить CAPTCHA');
    }
  }

  Future<String> _verify(_CaptchaChallenge challenge, String solution) async {
    try {
      final dio = challenge.purpose == 'download' ? _downloadDio : _dio;
      final path = challenge.purpose == 'download'
          ? '/api/bot-check/verify'
          : '/bot-check/verify';
      final response = await dio.post(
        path,
        data: {
          'challenge_id': challenge.id,
          'solution': solution.trim().toUpperCase(),
        },
      );
      if (response.statusCode != 200 || response.data is! Map) {
        throw BotCheckException(
          _botCheckResponseMessage(
            response.data,
            fallback: 'Неверный код CAPTCHA',
          ),
        );
      }
      final data = Map<String, dynamic>.from(response.data as Map);
      final token = '${data['bot_token'] ?? ''}'.trim();
      if (token.isEmpty) {
        throw const BotCheckException('Сервер не выдал токен CAPTCHA');
      }
      return token;
    } on BotCheckException {
      rethrow;
    } on DioException catch (e) {
      appLog.warn(
        'bot',
        'CAPTCHA verify request failed status=${e.response?.statusCode}',
      );
      final status = e.response?.statusCode;
      if (status == 429) {
        throw const BotCheckException(
          'Слишком много попыток. Попробуйте немного позже',
        );
      }
      if (status != null && status >= 500) {
        throw const BotCheckException('Сервис CAPTCHA временно недоступен');
      }
      throw BotCheckException(
        _botCheckResponseMessage(
          e.response?.data,
          fallback: 'Не удалось проверить CAPTCHA',
        ),
      );
    }
  }

  Future<String> _issueToken(BuildContext context, String purpose) async {
    try {
      final challenge = await _fetchChallenge(purpose);
      if (!context.mounted) {
        throw const BotCheckException('Проверка CAPTCHA отменена');
      }
      final token = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CaptchaDialog(
          challenge: challenge,
          reload: () => _fetchChallenge(purpose),
          verify: _verify,
        ),
      );
      if (token == null || token.isEmpty) {
        throw const BotCheckException('Проверка CAPTCHA отменена');
      }
      // Expiry токена сервер не скрывает; используем безопасный локальный TTL.
      _capabilities[purpose] = _BotCapability(
        token,
        DateTime.now().add(const Duration(minutes: 14)),
      );
      appLog.info('bot', 'visual CAPTCHA capability issued purpose=$purpose');
      return token;
    } on BotCheckException {
      rethrow;
    } on DioException catch (e) {
      appLog.warn(
        'bot',
        'CAPTCHA verify request failed status=${e.response?.statusCode}',
      );
      throw const BotCheckException('Не удалось пройти CAPTCHA');
    } catch (e) {
      appLog.warn('bot', 'CAPTCHA flow failed: $e');
      throw const BotCheckException('Не удалось пройти CAPTCHA');
    }
  }

  void clear([String? purpose]) {
    if (purpose == null) {
      _capabilities.clear();
      _inFlight.clear();
      return;
    }
    _capabilities.remove(purpose);
    _inFlight.remove(purpose);
  }
}

class _CaptchaDialog extends StatefulWidget {
  final _CaptchaChallenge challenge;
  final Future<_CaptchaChallenge> Function() reload;
  final Future<String> Function(_CaptchaChallenge challenge, String solution)
  verify;

  const _CaptchaDialog({
    required this.challenge,
    required this.reload,
    required this.verify,
  });

  @override
  State<_CaptchaDialog> createState() => _CaptchaDialogState();
}

class _CaptchaDialogState extends State<_CaptchaDialog> {
  late _CaptchaChallenge _challenge = widget.challenge;
  final _solution = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _errorDetails;
  int? _errorLogId;

  @override
  void dispose() {
    _solution.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _errorDetails = null;
      _errorLogId = null;
    });
    try {
      final next = await widget.reload();
      if (!mounted) return;
      setState(() {
        _challenge = next;
        _solution.clear();
      });
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final value = _solution.text.trim().toUpperCase();
    if (value.length != _challenge.length) {
      _showError(const BotCheckException('Введите все символы с картинки'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _errorDetails = null;
      _errorLogId = null;
    });
    try {
      final token = await widget.verify(_challenge, value);
      if (mounted) Navigator.of(context).pop(token);
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(Object error) {
    final details = errorDetails(error);
    final entry = appLog.error('bot', 'CAPTCHA dialog failed: $details');
    if (!mounted) return;
    setState(() {
      _error = _captchaErrorMessage(error);
      _errorDetails = details;
      _errorLogId = entry.id;
    });
    toast.show('Ошибка CAPTCHA', level: ToastLevel.error, logId: entry.id);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 390, maxHeight: size.height - 48),
        child: GlassCard(
          strong: true,
          radius: GE.radiusLg,
          padding: EdgeInsets.zero,
          ignoreSurfaceToggle: true,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: GE.primary.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(GE.radiusSm),
                        border: Border.all(
                          color: GE.primary.withValues(alpha: 0.30),
                        ),
                      ),
                      child: Icon(
                        Icons.verified_user_outlined,
                        color: GE.primary,
                        size: 23,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Проверка безопасности',
                            style: TextStyle(
                              color: GE.text,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Подтвердите, что вы человек',
                            style: TextStyle(color: GE.sub, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'Введите символы с картинки',
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  height: 104,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: GE.bg.withValues(alpha: 0.48),
                    borderRadius: BorderRadius.circular(GE.radiusSm),
                    border: Border.all(color: GE.borderStrong),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.memory(
                    _challenge.image,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => Center(
                      child: Text(
                        'Не удалось показать CAPTCHA',
                        style: TextStyle(color: GE.sub, fontSize: 13),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _busy ? null : _refresh,
                    style: TextButton.styleFrom(
                      foregroundColor: GE.primary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 8,
                      ),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: const Text('Другая картинка'),
                  ),
                ),
                const SizedBox(height: 4),
                GlassInput(
                  controller: _solution,
                  hint: 'Код с картинки',
                  icon: Icons.keyboard_alt_outlined,
                  autofocus: true,
                  enabled: !_busy,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  textAlign: TextAlign.center,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w400,
                    letterSpacing: 3.2,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                    LengthLimitingTextInputFormatter(_challenge.length),
                  ],
                  onSubmitted: (_) => _submit(),
                  lite: true,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  AppErrorPanel(
                    title: 'Ошибка CAPTCHA',
                    message: _error!,
                    details: _errorDetails,
                    logId: _errorLogId,
                    compact: true,
                    onRetry: _submit,
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: GlassButton(
                        label: 'Отмена',
                        onTap: _busy ? null : () => Navigator.of(context).pop(),
                        ignoreSurfaceToggle: true,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GlassButton(
                        label: 'Проверить',
                        icon: Icons.arrow_forward_rounded,
                        primary: true,
                        loading: _busy,
                        onTap: _busy ? null : _submit,
                        ignoreSurfaceToggle: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _botCheckResponseMessage(dynamic data, {required String fallback}) {
  if (data is Map) {
    final detail = data['detail'];
    if (detail is String && detail.trim().isNotEmpty) return detail.trim();
    if (detail is Map && detail['message'] is String) {
      final message = '${detail['message']}'.trim();
      if (message.isNotEmpty) return message;
    }
    final message = data['message'];
    if (message is String && message.trim().isNotEmpty) return message.trim();
  }
  return fallback;
}

String _captchaErrorMessage(Object error) {
  if (error is BotCheckException) return error.message;
  return 'Не удалось пройти CAPTCHA. Попробуйте ещё раз';
}
