import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api/http_client.dart';
import '../core/constants.dart';
import '../core/local/app_logger.dart';
import '../theme.dart';
import '../widgets/error_panel.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';
import 'bot_check_service.dart';
import 'notification_service.dart';

class UpdateException implements Exception {
  final String message;
  final String? details;

  const UpdateException(this.message, {this.details});

  @override
  String toString() => message;
}

class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final bool critical;
  final String title;
  final String notes;
  final List<String> whatsNew;
  final DateTime? releaseAt;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.critical,
    required this.title,
    required this.notes,
    required this.whatsNew,
    required this.releaseAt,
  });

  factory AppUpdateInfo.fromJson({
    required String currentVersion,
    required String latestVersion,
    required Map<String, dynamic> json,
  }) {
    final rawChanges = json['whats_new'] ?? json['whatsNew'];
    final changes = rawChanges is List
        ? rawChanges
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final rawRelease = '${json['release_at'] ?? ''}'.trim();
    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      critical: json['critical'] == true,
      title: '${json['title'] ?? 'Обновление GhostChat'}'.trim(),
      notes: '${json['notes'] ?? ''}'.trim(),
      whatsNew: changes,
      releaseAt: DateTime.tryParse(rawRelease),
    );
  }
}

class AppUpdateCheckResult {
  final String currentVersion;
  final String latestVersion;
  final AppUpdateInfo? update;

  const AppUpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    this.update,
  });

  bool get updateAvailable => update != null;
}

/// Проверяет релиз при входе в приложение и на каждом возвращении из фона.
/// Пока процесс приложения жив, периодический таймер позволяет показать
/// локальное Android-уведомление даже в фоне; запуск установки всегда идёт
/// через системный APK-инсталлятор Android.
class UpdateService with WidgetsBindingObserver {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const _snoozeKey = 'app_update_snooze_until';
  static const _skipKey = 'app_update_skip_until';
  static const _checksEnabledKey = 'app_update_checks_enabled_v1';
  static const _checkInterval = Duration(minutes: 15);
  static const _resumeDebounce = Duration(seconds: 45);

  Timer? _timer;
  Future<void>? _checkInFlight;
  DateTime? _lastCheck;
  DateTime? _snoozeUntil;
  DateTime? _skipUntil;
  AppUpdateInfo? _pending;
  String? _shownVersion;
  String? _notifiedVersion;
  bool _openRequested = false;
  bool _started = false;
  bool _checksEnabled = true;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  AppUpdateInfo? get pending => _pending;
  bool get checksEnabled => _checksEnabled;

  Future<void> loadSettings() => _loadSuppression();

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    await _loadSuppression();
    unawaited(checkNow());
    if (_lifecycle == AppLifecycleState.resumed) _startTimer();
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _stopTimer();
    _pending = null;
    _shownVersion = null;
    _notifiedVersion = null;
    _openRequested = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed) {
      _startTimer();
      unawaited(checkNow());
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Проверка обновлений не должна будить сеть каждые 15 минут, пока
      // приложение свёрнуто. При возврате в foreground проверим сразу.
      _stopTimer();
    }
  }

  void _startTimer() {
    if (!_started || _timer != null) return;
    _timer = Timer.periodic(_checkInterval, (_) {
      unawaited(checkNow());
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _loadSuppression() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _snoozeUntil = _dateFromMillis(prefs.getInt(_snoozeKey));
      _skipUntil = _dateFromMillis(prefs.getInt(_skipKey));
      _checksEnabled = prefs.getBool(_checksEnabledKey) ?? true;
    } catch (error) {
      appLog.warn('update', 'suppression preferences unavailable: $error');
    }
  }

  DateTime? _dateFromMillis(int? value) =>
      value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);

  Future<void> checkNow({bool force = false}) async {
    if (!_started && !force) return;
    if (!_checksEnabled && !force) return;
    final now = DateTime.now();
    // «Пропустить на час» — это именно пауза проверки, а не только скрытие
    // окна. Проверяем до force, чтобы перезапуск приложения и возврат из фона
    // также не отправляли запросы к /api/version в течение этого часа.
    if (_skipUntil?.isAfter(now) == true) return;
    final running = _checkInFlight;
    if (running != null) return running;
    if (!force &&
        _lastCheck != null &&
        now.difference(_lastCheck!) < _resumeDebounce) {
      return;
    }
    _lastCheck = now;
    final future = _checkInternal();
    _checkInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_checkInFlight, future)) _checkInFlight = null;
    }
  }

  Future<void> setChecksEnabled(bool enabled) async {
    _checksEnabled = enabled;
    if (!enabled) {
      _pending = null;
      _shownVersion = null;
      _notifiedVersion = null;
      _lastCheck = null;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_checksEnabledKey, enabled);
    } catch (error) {
      appLog.warn('update', 'could not save update-check setting: $error');
    }
  }

  Future<String> currentVersion() => _currentVersion();

  /// A user-facing check keeps the current version even when the server says
  /// that there is no update. Automatic checks intentionally keep using
  /// [_fetchInfo], which only returns actionable updates.
  Future<AppUpdateCheckResult> checkStatus() async {
    final current = await _currentVersion();
    try {
      final response = await HttpClient.I.dio.get(
        '/api/version',
        options: Options(
          extra: const {'skipAuth': true},
          responseType: ResponseType.json,
          headers: const {'Cache-Control': 'no-store'},
        ),
      );
      if (response.statusCode != 200 || response.data is! Map) {
        throw const UpdateException('Сервер вернул некорректный ответ');
      }
      final overview = Map<String, dynamic>.from(response.data as Map);
      final latest = '${overview['latest'] ?? ''}'.trim();
      if (overview['available'] == false || latest.isEmpty) {
        _pending = null;
        return AppUpdateCheckResult(
          currentVersion: current,
          latestVersion: current,
        );
      }
      if (latest == current) {
        _pending = null;
        return AppUpdateCheckResult(
          currentVersion: current,
          latestVersion: latest,
        );
      }

      Map<String, dynamic> details = overview;
      try {
        final detailResponse = await HttpClient.I.dio.get(
          '/api/version/${Uri.encodeComponent(latest)}',
          options: Options(
            extra: const {'skipAuth': true},
            responseType: ResponseType.json,
            headers: const {'Cache-Control': 'no-store'},
          ),
        );
        if (detailResponse.statusCode == 200 && detailResponse.data is Map) {
          details = Map<String, dynamic>.from(detailResponse.data as Map);
        }
      } catch (error) {
        appLog.warn('update', 'release notes request failed: $error');
      }
      final info = AppUpdateInfo.fromJson(
        currentVersion: current,
        latestVersion: latest,
        json: details,
      );
      _pending = info;
      _lastCheck = DateTime.now();
      return AppUpdateCheckResult(
        currentVersion: current,
        latestVersion: latest,
        update: info,
      );
    } catch (error) {
      if (error is UpdateException) rethrow;
      throw UpdateException(
        'Не удалось проверить обновления',
        details: '$error',
      );
    }
  }

  Future<void> _checkInternal() async {
    try {
      final info = await _fetchInfo();
      if (!_checksEnabled) {
        _pending = null;
        return;
      }
      if (info == null) {
        _pending = null;
        return;
      }
      _pending = info;
      if (_lifecycle == AppLifecycleState.resumed) {
        if (_openRequested) {
          _present(info, ignoreSuppression: true);
        } else {
          _presentIfAllowed(info);
        }
      } else {
        _notifyInBackground(info);
      }
    } catch (error, stack) {
      appLog.warn('update', 'version check failed: $error');
      appLog.debug('update', '$stack');
    }
  }

  Future<AppUpdateInfo?> _fetchInfo() async {
    final current = await _currentVersion();
    final response = await HttpClient.I.dio.get(
      '/api/version',
      options: Options(
        extra: const {'skipAuth': true},
        responseType: ResponseType.json,
        headers: const {'Cache-Control': 'no-store'},
      ),
    );
    if (response.statusCode != 200 || response.data is! Map) return null;
    final overview = Map<String, dynamic>.from(response.data as Map);
    if (overview['available'] == false) return null;
    final latest = '${overview['latest'] ?? ''}'.trim();
    if (latest.isEmpty || latest == current) return null;

    Map<String, dynamic> details = overview;
    try {
      final detailResponse = await HttpClient.I.dio.get(
        '/api/version/${Uri.encodeComponent(latest)}',
        options: Options(
          extra: const {'skipAuth': true},
          responseType: ResponseType.json,
          headers: const {'Cache-Control': 'no-store'},
        ),
      );
      if (detailResponse.statusCode == 200 && detailResponse.data is Map) {
        details = Map<String, dynamic>.from(detailResponse.data as Map);
      }
    } catch (error) {
      // A version mismatch is still useful when the optional release notes
      // endpoint is temporarily unavailable.
      appLog.warn('update', 'release notes request failed: $error');
    }
    return AppUpdateInfo.fromJson(
      currentVersion: current,
      latestVersion: latest,
      json: details,
    );
  }

  Future<String> _currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim();
      if (version.isNotEmpty) return version;
    } catch (error) {
      appLog.warn('update', 'package version unavailable: $error');
    }
    return K.appVersion;
  }

  bool _suppressed(AppUpdateInfo info) {
    final now = DateTime.now();
    if (_snoozeUntil?.isAfter(now) == true) return true;
    if (!info.critical && _skipUntil?.isAfter(now) == true) return true;
    return false;
  }

  void _presentIfAllowed(AppUpdateInfo info) {
    if (_suppressed(info) || _shownVersion == info.latestVersion) return;
    final navigator = NotificationService.navigatorKey.currentState;
    if (navigator == null) {
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        if (_started && _lifecycle == AppLifecycleState.resumed) {
          _presentIfAllowed(info);
        }
      });
      return;
    }
    _shownVersion = info.latestVersion;
    navigator.push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => UpdateScreen(info: info),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  void _notifyInBackground(AppUpdateInfo info) {
    if (_suppressed(info) || _notifiedVersion == info.latestVersion) return;
    _notifiedVersion = info.latestVersion;
    unawaited(
      NotificationService.instance.showUpdateAvailable(
        version: info.latestVersion,
        critical: info.critical,
      ),
    );
  }

  /// Called by NotificationService when the user taps the update notification.
  Future<void> openPendingUpdate() async {
    // Android may deliver the tap before Flutter has mounted MainShell. Keep
    // the intent until the first version check can push the route safely.
    _openRequested = true;
    var info = _pending;
    if (info == null) {
      try {
        info = await _fetchInfo();
      } catch (error) {
        appLog.warn('update', 'notification update fetch failed: $error');
      }
    }
    if (info == null) return;
    _pending = info;
    _shownVersion = null;
    _present(info, ignoreSuppression: true);
  }

  void _present(AppUpdateInfo info, {required bool ignoreSuppression}) {
    if (!ignoreSuppression && _suppressed(info)) return;
    final navigator = NotificationService.navigatorKey.currentState;
    if (navigator == null) return;
    if (_shownVersion == info.latestVersion && !ignoreSuppression) return;
    _shownVersion = info.latestVersion;
    _openRequested = false;
    navigator.push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, __, ___) => UpdateScreen(info: info),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  Future<void> snooze(AppUpdateInfo info) async {
    final until = DateTime.now().add(const Duration(minutes: 25));
    _snoozeUntil = until;
    _shownVersion = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_snoozeKey, until.millisecondsSinceEpoch);
    } catch (error) {
      appLog.warn('update', 'could not save 25m snooze: $error');
    }
  }

  Future<void> skipForHour(AppUpdateInfo info) async {
    final until = DateTime.now().add(const Duration(hours: 1));
    _skipUntil = until;
    _snoozeUntil = null;
    _shownVersion = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_skipKey, until.millisecondsSinceEpoch);
      await prefs.remove(_snoozeKey);
    } catch (error) {
      appLog.warn('update', 'could not save 1h skip: $error');
    }
  }

  Future<void> downloadAndOpen(
    BuildContext context,
    AppUpdateInfo info, {
    ValueChanged<double>? onProgress,
  }) async {
    final token = await BotCheckService.instance.ensureToken(
      context,
      purpose: 'download',
    );
    final temp = await getTemporaryDirectory();
    final safeVersion = info.latestVersion.replaceAll(
      RegExp(r'[^0-9A-Za-z._-]'),
      '_',
    );
    final file = File('${temp.path}/GhostChat_V${safeVersion}ob.apk');
    try {
      final response = await HttpClient.I.dio.download(
        '/api/download/update',
        file.path,
        data: {'version': info.latestVersion},
        options: Options(
          method: 'POST',
          extra: const {'skipAuth': true},
          headers: {'X-Ghost-Bot-Token': token, 'Cache-Control': 'no-store'},
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(minutes: 5),
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        BotCheckService.instance.clear('download');
        throw UpdateException(
          _responseMessage(response.data, 'Скачивание обновления недоступно'),
        );
      }
      if (!await file.exists() || await file.length() < 1024) {
        throw const UpdateException('Сервер прислал неполный APK');
      }
      final result = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        throw UpdateException(
          'Не удалось открыть установщик Android',
          details: result.message,
        );
      }
      _pending = null;
      await NotificationService.instance.clearUpdateNotifications();
      appLog.info(
        'update',
        'APK opened for installation version=${info.latestVersion}',
      );
    } on UpdateException {
      rethrow;
    } on DioException catch (error) {
      BotCheckService.instance.clear('download');
      throw UpdateException(
        'Не удалось скачать обновление',
        details: error.response?.data?.toString() ?? error.message,
      );
    } catch (error) {
      throw UpdateException(
        'Не удалось установить обновление',
        details: '$error',
      );
    } finally {
      // Keep the APK while the system installer is using it. Temporary files
      // are cleaned by Android; deleting here would break the installer.
    }
  }

  String _responseMessage(dynamic data, String fallback) {
    if (data is Map && data['detail'] != null) {
      final detail = data['detail'];
      if (detail is Map && detail['message'] != null) {
        return detail['message'].toString();
      }
      return detail.toString();
    }
    return fallback;
  }
}

class UpdateScreen extends StatefulWidget {
  final AppUpdateInfo info;

  const UpdateScreen({super.key, required this.info});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  bool _busy = false;
  double _progress = 0;
  String? _error;
  String? _errorDetails;
  int? _errorLogId;

  Color get _accent => widget.info.critical ? GE.red : GE.primary;

  Future<void> _install() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
      _errorDetails = null;
      _errorLogId = null;
    });
    try {
      await UpdateService.instance.downloadAndOpen(
        context,
        widget.info,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value.clamp(0, 1));
        },
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      final entry = appLog.error('update', '$error');
      if (!mounted) return;
      setState(() {
        _error = error is UpdateException
            ? error.message
            : 'Не удалось скачать обновление';
        _errorDetails = error is UpdateException ? error.details : '$error';
        _errorLogId = entry.id;
        _busy = false;
      });
      toast.show('Ошибка обновления', level: ToastLevel.error, logId: entry.id);
    }
  }

  Future<void> _snooze() async {
    await UpdateService.instance.snooze(widget.info);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _skip() async {
    await UpdateService.instance.skipForHour(widget.info);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Color.alphaBlend(
          Colors.black.withValues(alpha: 0.64),
          GE.bgDeep,
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: GlassCard(
                  strong: true,
                  radius: GE.radiusLg,
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _accent.withValues(alpha: 0.16),
                          border: Border.all(
                            color: _accent.withValues(alpha: 0.42),
                          ),
                        ),
                        child: Icon(
                          info.critical
                              ? Icons.warning_amber_rounded
                              : Icons.system_update_alt_rounded,
                          color: _accent,
                          size: 32,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        info.critical
                            ? 'Критическое обновление'
                            : 'Доступно обновление',
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        info.title,
                        style: TextStyle(color: _accent, fontSize: 14),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: _versionChip('Сейчас', info.currentVersion),
                          ),
                          const SizedBox(width: 10),
                          Icon(Icons.arrow_forward_rounded, color: _accent),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _versionChip('Новая', info.latestVersion),
                          ),
                        ],
                      ),
                      if (info.notes.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Text(
                          info.notes,
                          style: TextStyle(color: GE.sub, height: 1.4),
                        ),
                      ],
                      if (info.whatsNew.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Text(
                          'Что нового',
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (final item in info.whatsNew)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 7),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('•  ', style: TextStyle(color: _accent)),
                                Expanded(
                                  child: Text(
                                    item,
                                    style: TextStyle(
                                      color: GE.sub,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        AppErrorPanel(
                          title: 'Ошибка обновления',
                          message: _error!,
                          details: _errorDetails,
                          logId: _errorLogId,
                          compact: true,
                          onRetry: _install,
                        ),
                      ],
                      if (_busy) ...[
                        const SizedBox(height: 18),
                        LinearProgressIndicator(
                          value: _progress > 0 ? _progress : null,
                          color: _accent,
                          backgroundColor: GE.border,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _progress > 0
                              ? 'Скачивание ${(100 * _progress).round()}%'
                              : 'Проверка CAPTCHA и подготовка APK…',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: GE.sub, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 22),
                      GlassButton(
                        label: _busy ? 'Скачивание…' : 'Скачать и установить',
                        icon: Icons.download_rounded,
                        primary: true,
                        fullWidth: true,
                        onTap: _busy ? null : _install,
                      ),
                      const SizedBox(height: 10),
                      GlassButton(
                        label: info.critical
                            ? 'Напомнить через 25 минут'
                            : 'Попозже · 25 минут',
                        fullWidth: true,
                        onTap: _busy ? null : _snooze,
                      ),
                      if (!info.critical) ...[
                        const SizedBox(height: 4),
                        TextButton(
                          onPressed: _busy ? null : _skip,
                          child: Text(
                            'Пропустить на 1 час',
                            style: TextStyle(color: GE.sub),
                          ),
                        ),
                      ],
                      const SizedBox(height: 5),
                      Text(
                        'После скачивания Android сам откроет окно «Обновить?».',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: GE.muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _versionChip(String label, String version) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: GE.surface.withValues(alpha: 0.68),
        borderRadius: BorderRadius.circular(GE.radiusSm),
        border: Border.all(color: GE.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: GE.muted, fontSize: 11)),
          const SizedBox(height: 3),
          Text(
            version,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: GE.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
