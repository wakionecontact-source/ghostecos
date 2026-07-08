// Локальные уведомления о новых сообщениях.
//
// ОБЛАСТЬ ДЕЙСТВИЯ: показывает уведомления пока приложение ЖИВО (foreground +
// недавний фон, пока WebSocket-листенер получает входящие). Для УБИТОГО
// приложения нужен FCM (серверный push) или foreground-сервис — это отдельное
// архитектурное решение (см. .session_bus).
//
// Всё обёрнуто в try/catch: сбой плагина уведомлений НЕ должен ронять чат.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../screens/chat_screen.dart';
import '../screens/lan_scan_screen.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  /// Глобальный ключ навигатора — чтобы открыть чат по тапу на уведомление.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// Чат, открытый ПРЯМО СЕЙЧАС — о нём уведомление не шлём.
  /// Выставляется в ChatScreen.initState, сбрасывается в dispose.
  static String? activePeer;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _idSeq = 1;

  static const _channel = AndroidNotificationChannel(
    'messages',
    'Сообщения',
    description: 'Уведомления о новых сообщениях',
    importance: Importance.high,
  );

  Future<void> init() async {
    try {
      // Белая монохромная иконка (не @mipmap — тот даёт «белый квадрат»).
      const android = AndroidInitializationSettings('ic_notification');
      const settings = InitializationSettings(android: android);
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: _onTap,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(_channel);
      _ready = true;
    } catch (e) {
      if (kDebugMode) print('[notif] init: $e');
    }
  }

  /// Запросить POST_NOTIFICATIONS (Android 13+), если ещё не выдано. Зовём
  /// после логина (когда юзер уже в приложении). Идемпотентно.
  Future<void> ensurePermission() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return;
      final enabled = await android.areNotificationsEnabled() ?? false;
      if (!enabled) {
        await android.requestNotificationsPermission();
      }
    } catch (e) {
      if (kDebugMode) print('[notif] perm: $e');
    }
  }

  /// Входящее сообщение → уведомление, если этот чат сейчас НЕ открыт.
  void onIncoming({required String peer, required String preview}) {
    if (!_ready) return;
    if (activePeer == peer) return;
    _show(
      title: peer,
      body: preview.isEmpty ? 'Новое сообщение' : preview,
      payload: jsonEncode({'peer': peer}),
    );
  }

  /// Кто-то поблизости хочет подключиться по LAN/BLE/Wi-Fi Direct.
  void onLanRequest({required String label}) {
    if (!_ready) return;
    _show(
      title: 'Устройство поблизости',
      body: '$label хочет подключиться',
      payload: jsonEncode({'type': 'lan_request'}),
    );
  }

  Future<void> _show({
    required String title,
    required String body,
    required String payload,
  }) async {
    try {
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          ticker: title,
          icon: 'ic_notification', // белый призрак вместо дефолтного квадрата
        ),
      );
      await _plugin.show(_idSeq++, title, body, details, payload: payload);
    } catch (e) {
      if (kDebugMode) print('[notif] show: $e');
    }
  }

  void _onTap(NotificationResponse resp) {
    try {
      final p = resp.payload;
      if (p == null) return;
      final data = jsonDecode(p) as Map<String, dynamic>;
      if (data['type'] == 'lan_request') {
        navigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => const LanScanScreen()),
        );
        return;
      }
      final peer = data['peer'] as String?;
      if (peer == null) return;
      navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(peer: peer, displayName: peer),
        ),
      );
    } catch (e) {
      if (kDebugMode) print('[notif] tap: $e');
    }
  }
}
