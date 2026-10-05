// Foreground-сервис: держит процесс приложения ЖИВЫМ в фоне (персистентное
// уведомление «GhostChat — в сети»), чтобы WS-листенер и хук уведомлений
// продолжали работать когда приложение свёрнуто/закрыто. Без этого Android
// убивает процесс → уведомления о входящих не приходят.
//
// Сообщения-уведомления показывает NotificationService из ГЛАВНОГО изолята
// (он жив, пока держит сервис). TaskHandler ниже — минимальный keep-alive.
//
// Сервис не берёт wakelock и не просит исключение из Doze: foreground-service
// уже даёт процессу нужный приоритет, а постоянный wakelock превращал фон в
// фактически неусыпающий режим и был главным источником расхода батареи.
// Defensive: любой сбой не должен ронять приложение.
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'permissions_service.dart';

// Top-level callback сервиса (отдельный изолят). Обязателен vm:entry-point.
@pragma('vm:entry-point')
void ghostForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_GhostTaskHandler());
}

class _GhostTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

class ForegroundService {
  ForegroundService._();
  static final ForegroundService instance = ForegroundService._();
  bool _inited = false;
  Future<void>? _startInFlight;
  int _lifecycleGeneration = 0;
  bool _serviceConfiguredForProcess = false;
  bool get isConfiguredForProcess => _serviceConfiguredForProcess;

  void init() {
    if (_inited || !Platform.isAndroid) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'ghost_online',
          channelName: 'GhostChat в сети',
          channelDescription: 'Поддерживает связь для уведомлений',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction:
              ForegroundTaskEventAction.nothing(), // keep-alive, без таймера
          // The app starts this service once after an authenticated session is
          // ready. BootReceiver + the UI start used to race and could produce
          // startup errors or duplicate-looking app processes.
          autoRunOnBoot: false,
          allowWakeLock: false,
        ),
      );
      _inited = true;
    } catch (e) {
      if (kDebugMode) print('[fg] init: $e');
    }
  }

  /// Запросить только разрешение на уведомления и запустить сервис с
  /// персистентным уведомлением. Игнорирование оптимизации батареи намеренно
  /// не запрашиваем: оно не нужно для idle-соединения и резко увеличивает
  /// расход на некоторых прошивках.
  Future<void> start() {
    if (!Platform.isAndroid) return Future<void>.value();
    final running = _startInFlight;
    if (running != null) return running;
    final future = _startInternal(_lifecycleGeneration);
    _startInFlight = future;
    return future.whenComplete(() {
      if (identical(_startInFlight, future)) _startInFlight = null;
    });
  }

  Future<void> _startInternal(int generation) async {
    try {
      init();
      // POST_NOTIFICATIONS (Android 13+) — без него сервис-уведомление не видно.
      var np = await FlutterForegroundTask.checkNotificationPermission();
      if (np != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
        np = await FlutterForegroundTask.checkNotificationPermission();
      }
      await PermissionUsageAudit.instance.recordStatus(
        Permission.notification,
        context: 'foreground_service',
        result: np == NotificationPermission.granted ? 'granted' : 'denied',
      );
      if (generation != _lifecycleGeneration) return;
      // После обновления уже работающий сервис мог быть запущен старой
      // версией с wakelock=true. Перезапускаем его один раз, чтобы новая
      // энергоэффективная конфигурация реально применилась, а не только
      // изменилась в Dart-коде.
      if (await FlutterForegroundTask.isRunningService) {
        if (_serviceConfiguredForProcess) return;
        await FlutterForegroundTask.stopService();
      }
      await FlutterForegroundTask.startService(
        notificationTitle: 'GhostChat',
        notificationText: 'В сети',
        notificationIcon: const NotificationIcon(
          metaDataName: 'online.ghost_chat.fg_notification_icon',
        ),
        callback: ghostForegroundCallback,
      );
      _serviceConfiguredForProcess = true;
    } catch (e) {
      if (kDebugMode) print('[fg] start: $e');
    }
  }

  Future<void> stop() async {
    _lifecycleGeneration++;
    try {
      final starting = _startInFlight;
      if (starting != null) await starting;
      await FlutterForegroundTask.stopService();
      _serviceConfiguredForProcess = false;
    } catch (e) {
      if (kDebugMode) print('[fg] stop: $e');
    }
  }
}
