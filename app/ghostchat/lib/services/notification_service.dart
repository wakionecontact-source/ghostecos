// Локальные уведомления о новых сообщениях.
//
// ОБЛАСТЬ ДЕЙСТВИЯ: показывает уведомления пока приложение ЖИВО (foreground +
// недавний фон, пока WebSocket-листенер получает входящие). Для УБИТОГО
// приложения нужен FCM (серверный push) или foreground-сервис — это отдельное
// архитектурное решение (см. .session_bus).
//
// Всё обёрнуто в try/catch: сбой плагина уведомлений НЕ должен ронять чат.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import '../screens/chat_screen.dart';
import '../screens/lan_scan_screen.dart';
import 'notification_settings.dart';
import 'sound_settings.dart';
import 'network_settings.dart';
import 'permissions_service.dart';
import 'ws_client.dart';
import '../widgets/toast_overlay.dart';

enum NotificationMessageKind { text, photo, video, voice, file }

extension NotificationMessageKindText on NotificationMessageKind {
  String get fallbackText {
    switch (this) {
      case NotificationMessageKind.photo:
        return 'Новое фото';
      case NotificationMessageKind.video:
        return 'Новое видео';
      case NotificationMessageKind.voice:
        return 'Голосовое сообщение';
      case NotificationMessageKind.file:
        return 'Новый файл';
      case NotificationMessageKind.text:
        return 'Новое сообщение';
    }
  }

  bool get isMedia => this != NotificationMessageKind.text;
}

NotificationMessageKind classifyNotificationKind({
  String? mime,
  bool voice = false,
}) {
  if (voice) return NotificationMessageKind.voice;
  final normalized = mime?.trim().toLowerCase() ?? '';
  if (normalized.startsWith('image/')) return NotificationMessageKind.photo;
  if (normalized.startsWith('video/')) return NotificationMessageKind.video;
  if (normalized.isNotEmpty) return NotificationMessageKind.file;
  return NotificationMessageKind.text;
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  /// Глобальный ключ навигатора — чтобы открыть чат по тапу на уведомление.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// Set by main.dart to avoid coupling notification plumbing to the update
  /// screen. The callback is also used when Android recreates the app after a
  /// tap on a local update notification.
  static Future<void> Function()? onUpdateNotificationTap;

  /// Чат, открытый ПРЯМО СЕЙЧАС — о нём уведомление не шлём.
  /// Выставляется в ChatScreen.initState, сбрасывается в dispose.
  static String? activePeer;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _systemNotificationListenerBound = false;
  final Set<int> _shownSystemNotificationIds = <int>{};
  int _idSeq = 1;
  static const _notificationAvatar = DrawableResourceAndroidBitmap(
    'ic_notification',
  );

  // Группировка по чату: несколько сообщений от ОДНОГО собеседника не
  // плодят отдельные уведомления, а копятся в ОДНОМ (Inbox-style, как в
  // Telegram/WhatsApp) — новое перезаписывает существующее по стабильному id.
  final Map<String, List<String>> _peerMessages = {};
  final Map<String, NotificationMessageKind> _peerKinds = {};
  final Map<String, String> _peerThumbnails = {};
  static const _peerHistoryCap = 8;
  int _peerNotifId(String peer) => peer.hashCode & 0x7FFFFFFF;

  static const _channel = AndroidNotificationChannel(
    'messages_ghost_v2',
    'GhostChat — сообщения',
    description: 'Уведомления о новых сообщениях',
    importance: Importance.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('ghostchat_notification'),
  );

  static const _updateChannel = AndroidNotificationChannel(
    'app_updates_ghost_v2',
    'Обновления GhostChat',
    description: 'Уведомления о новых версиях приложения',
    importance: Importance.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('ghostchat_notification'),
  );

  static const _criticalUpdateChannel = AndroidNotificationChannel(
    'app_updates_critical_ghost_v2',
    'Критические обновления GhostChat',
    description: 'Важные уведомления о безопасности и совместимости',
    importance: Importance.max,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('ghostchat_notification'),
  );

  static const _connectionChannel = AndroidNotificationChannel(
    'connection_status_ghost_v3',
    'Проверка связи',
    description: 'Уведомления о состоянии соединения GhostChat',
    importance: Importance.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('ghostchat_notification'),
  );

  static const _mediaChannel = AndroidNotificationChannel(
    'media_messages_ghost_v2',
    'Фото и медиа',
    description: 'Уведомления о фото, видео, голосовых и файлах',
    importance: Importance.high,
    playSound: true,
    sound: RawResourceAndroidNotificationSound('ghostchat_notification'),
  );

  static const _silentChannel = AndroidNotificationChannel(
    'ghostchat_silent_v1',
    'GhostChat — без звука',
    description: 'Уведомления GhostChat без звукового сигнала',
    importance: Importance.high,
    playSound: false,
    enableVibration: true,
  );

  RawResourceAndroidNotificationSound _notificationSoundForVariant() {
    final variant = SoundSettings.instance.notificationVariantNotifier.value;
    final soundName = variant == 0
        ? 'ghostchat_notification'
        : 'ghostchat_notification_${variant + 1}';
    return RawResourceAndroidNotificationSound(soundName);
  }

  Future<AndroidNotificationChannel> _channelForSound(
    AndroidNotificationChannel withSound,
  ) async {
    if (!SoundSettings.instance.notificationSoundsEnabledNotifier.value) {
      return _silentChannel;
    }
    final variant = SoundSettings.instance.notificationVariantNotifier.value;
    final channel = AndroidNotificationChannel(
      '${withSound.id}_tone_${variant + 1}',
      '${withSound.name} · тон ${variant + 1}',
      description: withSound.description,
      groupId: withSound.groupId,
      importance: withSound.importance,
      playSound: true,
      sound: _notificationSoundForVariant(),
      enableVibration: withSound.enableVibration,
      vibrationPattern: withSound.vibrationPattern,
      showBadge: withSound.showBadge,
      enableLights: withSound.enableLights,
      ledColor: withSound.ledColor,
      audioAttributesUsage: withSound.audioAttributesUsage,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(channel);
    return channel;
  }

  Future<void> init() async {
    if (_ready) return;
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
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.createNotificationChannel(_updateChannel);
      await androidPlugin?.createNotificationChannel(_criticalUpdateChannel);
      await androidPlugin?.createNotificationChannel(_connectionChannel);
      await androidPlugin?.createNotificationChannel(_mediaChannel);
      await androidPlugin?.createNotificationChannel(_silentChannel);
      _ready = true;
      if (!_systemNotificationListenerBound) {
        WsClient.instance.on('system.notification', _onServerNotification);
        _systemNotificationListenerBound = true;
      }
    } catch (e) {
      if (kDebugMode) print('[notif] init: $e');
    }
  }

  /// Posts one user-requested test notification through the same Android
  /// channel and bundled sound used for incoming GhostChat messages.
  Future<void> showSoundTestNotification() async {
    if (!_ready) await init();
    if (!_ready) return;
    try {
      await ensurePermission();
      final channel = await _channelForSound(_channel);
      final soundEnabled = channel.playSound;
      await _plugin.show(
        7814,
        'GhostChat',
        'Проверка звука уведомления',
        NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            importance: Importance.high,
            priority: Priority.high,
            playSound: soundEnabled,
            sound: soundEnabled ? _notificationSoundForVariant() : null,
            icon: 'ic_notification',
            largeIcon: _notificationAvatar,
            autoCancel: true,
          ),
        ),
        payload: jsonEncode({'type': 'sound_test'}),
      );
    } catch (error) {
      if (kDebugMode) debugPrint('[notif] sound test failed: $error');
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
  /// Несколько подряд — схлопываются в ОДНО уведомление (группа по чату).
  void onIncoming({
    required String peer,
    required String preview,
    String? senderName,
    NotificationMessageKind kind = NotificationMessageKind.text,
    String? thumbnailBase64,
  }) {
    if (!_ready) return;
    if (activePeer == peer) return;
    // Настройки → Уведомления (перенесено из 1.19.3) — общий выключатель +
    // "исключения" (замьюченные чаты).
    final ns = NotificationSettings.instance;
    if (!ns.enabledNotifier.value) return;
    if (ns.isMuted(peer)) return;
    unawaited(
      PermissionUsageAudit.instance.recordStatus(
        Permission.notification,
        context: 'notification_message',
        result: 'granted',
      ),
    );
    final list = _peerMessages.putIfAbsent(peer, () => []);
    list.add(
      ns.showContentNotifier.value && preview.isNotEmpty
          ? preview
          : 'Новое сообщение',
    );
    while (list.length > _peerHistoryCap) {
      list.removeAt(0);
    }
    _peerKinds[peer] = kind;
    if (kind == NotificationMessageKind.photo &&
        thumbnailBase64 != null &&
        thumbnailBase64.length <= 320000) {
      _peerThumbnails[peer] = thumbnailBase64;
    } else {
      _peerThumbnails.remove(peer);
    }
    _showGrouped(
      peer,
      list,
      senderName: senderName,
      kind: kind,
      thumbnailBase64: _peerThumbnails[peer],
    );
  }

  /// Чат открыли — снимаем уведомление по нему и забываем накопленную историю
  /// (следующие сообщения снова начнут копиться с чистого листа).
  void clearPeer(String peer) {
    _peerMessages.remove(peer);
    _peerKinds.remove(peer);
    _peerThumbnails.remove(peer);
    try {
      _plugin.cancel(_peerNotifId(peer));
    } catch (_) {}
  }

  Future<void> _showGrouped(
    String peer,
    List<String> messages, {
    String? senderName,
    NotificationMessageKind kind = NotificationMessageKind.text,
    String? thumbnailBase64,
  }) async {
    try {
      final ns = NotificationSettings.instance;
      final title = ns.showSenderNotifier.value
          ? (senderName?.trim().isNotEmpty == true ? senderName! : peer)
          : 'Новое сообщение';
      final groupKey = 'chat_$peer';
      final showContent = ns.showContentNotifier.value;
      final showPhoto =
          kind == NotificationMessageKind.photo &&
          showContent &&
          ns.showMediaPreviewNotifier.value &&
          thumbnailBase64 != null &&
          thumbnailBase64.isNotEmpty;
      final channel = await _channelForSound(
        kind.isMedia ? _mediaChannel : _channel,
      );
      final soundEnabled = channel.playSound;
      final body = showContent && messages.isNotEmpty
          ? messages.last
          : kind.fallbackText;
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: Importance.high,
          priority: Priority.high,
          playSound: soundEnabled,
          sound: soundEnabled ? _notificationSoundForVariant() : null,
          ticker: peer,
          icon: 'ic_notification',
          largeIcon: _notificationAvatar,
          groupKey: groupKey,
          category: AndroidNotificationCategory.message,
          styleInformation: showPhoto
              ? _photoStyle(
                  thumbnailBase64,
                  title: title,
                  summary: messages.length > 1
                      ? '${messages.length} сообщений'
                      : kind.fallbackText,
                )
              : messages.length > 1
              ? InboxStyleInformation(
                  messages,
                  contentTitle: title,
                  summaryText: '${messages.length} сообщений',
                )
              : null,
        ),
      );
      await _plugin.show(
        _peerNotifId(peer),
        title,
        body,
        details,
        payload: jsonEncode({'peer': peer, 'kind': kind.name}),
      );
    } catch (e) {
      if (kDebugMode) print('[notif] showGrouped: $e');
    }
  }

  BigPictureStyleInformation? _photoStyle(
    String thumbnailBase64, {
    required String title,
    required String summary,
  }) {
    try {
      final bitmap = ByteArrayAndroidBitmap.fromBase64String(thumbnailBase64);
      return BigPictureStyleInformation(
        bitmap,
        largeIcon: bitmap,
        contentTitle: title,
        summaryText: summary,
        hideExpandedLargeIcon: true,
      );
    } catch (e) {
      if (kDebugMode) print('[notif] photo preview: $e');
      return null;
    }
  }

  /// Кто-то поблизости хочет подключиться по LAN/BLE/Wi-Fi Direct.
  void onLanRequest({required String label}) {
    if (!_ready) return;
    if (!NotificationSettings.instance.enabledNotifier.value) return;
    _show(
      title: 'Устройство поблизости',
      body: '$label хочет подключиться',
      payload: jsonEncode({'type': 'lan_request'}),
    );
  }

  /// Пингует устройство, с которым чат был удалён на этом телефоне — мы ему
  /// не отвечаем понгом молча, но даём знать юзеру (тот же экран, что и для
  /// обычного запроса — там же можно заблокировать/восстановить).
  void onLanStaleContact({required String label}) {
    if (!_ready) return;
    if (!NotificationSettings.instance.enabledNotifier.value) return;
    _show(
      title: 'Сигнал от старого устройства',
      body: 'Чат с $label был удалён, но оно всё ещё на связи',
      payload: jsonEncode({'type': 'lan_request'}),
    );
  }

  /// Версия найдена в фоне. Стабильный id обновляет одно уведомление, а
  /// critical получает отдельный канал с максимальной заметностью.
  Future<void> showUpdateAvailable({
    required String version,
    required bool critical,
  }) async {
    if (!_ready) return;
    try {
      final channel = await _channelForSound(
        critical ? _criticalUpdateChannel : _updateChannel,
      );
      final soundEnabled = channel.playSound;
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: critical ? Importance.max : Importance.high,
          priority: critical ? Priority.max : Priority.high,
          playSound: soundEnabled,
          sound: soundEnabled ? _notificationSoundForVariant() : null,
          ticker: 'Доступно обновление GhostChat',
          icon: 'ic_notification',
          largeIcon: _notificationAvatar,
          category: AndroidNotificationCategory.status,
          autoCancel: true,
        ),
      );
      await _plugin.show(
        critical ? 7812 : 7811,
        critical
            ? 'Критическое обновление GhostChat'
            : 'Доступно обновление GhostChat',
        'Версия $version уже доступна. Нажмите, чтобы открыть обновление.',
        details,
        payload: jsonEncode({
          'type': 'app_update',
          'version': version,
          'critical': critical,
        }),
      );
    } catch (e) {
      if (kDebugMode) print('[notif] update: $e');
    }
  }

  Future<void> clearUpdateNotifications() async {
    try {
      await _plugin.cancel(7811);
      await _plugin.cancel(7812);
    } catch (e) {
      if (kDebugMode) print('[notif] clear update: $e');
    }
  }

  /// Результат проверки связи или смена состояния соединения.
  /// Один и тот же id намеренно переиспользуется: повторные проверки не
  /// размножают уведомления в шторке.
  Future<void> showConnectionCheck({
    required bool connected,
    required bool hasInternet,
    required bool serverConnected,
  }) async {
    if (!_ready) return;
    if (!NotificationSettings.instance.enabledNotifier.value) return;
    if (!NetworkSettings.instance.checkConnectionNotifier.value) return;
    try {
      final title = connected ? 'Связь восстановлена' : 'Связь потеряна';
      final body = connected
          ? 'Соединение с GhostChat активно'
          : !hasInternet
          ? 'Нет интернет-соединения'
          : !serverConnected
          ? 'Нет связи с сервером — переподключаемся'
          : 'Соединение недоступно';
      final channel = await _channelForSound(_connectionChannel);
      final soundEnabled = channel.playSound;
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: Importance.high,
          priority: Priority.high,
          playSound: soundEnabled,
          sound: soundEnabled ? _notificationSoundForVariant() : null,
          ticker: title,
          icon: 'ic_notification',
          largeIcon: _notificationAvatar,
          category: AndroidNotificationCategory.status,
          onlyAlertOnce: false,
          autoCancel: true,
        ),
      );
      await _plugin.show(
        7813,
        title,
        body,
        details,
        payload: jsonEncode({'type': 'connection_check'}),
      );
    } catch (e) {
      if (kDebugMode) print('[notif] connection: $e');
    }
  }

  Future<void> clearConnectionCheck() async {
    try {
      await _plugin.cancel(7813);
    } catch (e) {
      if (kDebugMode) print('[notif] clear connection: $e');
    }
  }

  void _onServerNotification(Map<String, dynamic> data) {
    final id = int.tryParse(data['id']?.toString() ?? '');
    if (id == null || id <= 0 || !_ready) return;
    if (!_shownSystemNotificationIds.add(id)) return;
    if (_shownSystemNotificationIds.length > 300) {
      _shownSystemNotificationIds.remove(_shownSystemNotificationIds.first);
    }
    unawaited(_displayServerNotification(id, data));
  }

  Future<void> _displayServerNotification(
    int id,
    Map<String, dynamic> data,
  ) async {
    final title = (data['title']?.toString() ?? '').trim();
    final body = (data['body']?.toString() ?? '').trim();
    if (title.isEmpty || body.isEmpty) return;
    try {
      if (NotificationSettings.instance.enabledNotifier.value) {
        if (WidgetsBinding.instance.lifecycleState ==
            AppLifecycleState.resumed) {
          toast.show('$title\n$body');
        } else {
          final channel = await _channelForSound(_channel);
          final soundEnabled = channel.playSound;
          final details = NotificationDetails(
            android: AndroidNotificationDetails(
              channel.id,
              channel.name,
              channelDescription: channel.description,
              importance: Importance.high,
              priority: Priority.high,
              playSound: soundEnabled,
              sound: soundEnabled ? _notificationSoundForVariant() : null,
              ticker: title,
              icon: 'ic_notification',
              largeIcon: _notificationAvatar,
              category: AndroidNotificationCategory.status,
              autoCancel: true,
            ),
          );
          final rawPayload = data['payload'];
          await _plugin.show(
            780000000 + (id % 100000000),
            title,
            body,
            details,
            payload: jsonEncode({
              'type': 'server_notification',
              'notification_id': id,
              'payload': rawPayload is Map ? rawPayload : const {},
            }),
          );
        }
      }
      // ACK only after the local presentation path completes. If it throws,
      // the server keeps the item pending and replays it on the next WS.
      WsClient.instance.send('system.notification.ack', {'id': id});
    } catch (e) {
      _shownSystemNotificationIds.remove(id);
      if (kDebugMode) print('[notif] server notification $id: $e');
    }
  }

  Future<void> _show({
    required String title,
    required String body,
    required String payload,
  }) async {
    try {
      final channel = await _channelForSound(_channel);
      final soundEnabled = channel.playSound;
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: Importance.high,
          priority: Priority.high,
          playSound: soundEnabled,
          sound: soundEnabled ? _notificationSoundForVariant() : null,
          ticker: title,
          icon: 'ic_notification', // белый призрак вместо дефолтного квадрата
          largeIcon: _notificationAvatar,
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
      if (data['type'] == 'app_update') {
        final handler = onUpdateNotificationTap;
        if (handler != null) unawaited(handler());
        return;
      }
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
