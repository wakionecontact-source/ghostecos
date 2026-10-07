// MainShell — главный экран после логина.
// Mobile: BottomNavigationBar снизу.
// Desktop: NavigationRail слева, контент справа.
// 4 таба: Чат / Лента / Банк / Профиль.
//
// Каждый экран — native, без WebView. Заглушки пока (M5-M7 их наполнят).

import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../theme.dart';
import '../services/theme_service.dart';
import '../services/performance_service.dart';
import '../services/privacy_settings.dart';
import '../mesh_background.dart';
import '../services/auth_service.dart';
import '../services/db_service.dart';
import '../services/crypto_service.dart';
import '../services/ws_client.dart';
import '../services/notification_service.dart';
import '../services/foreground_service.dart';
import '../services/update_service.dart';
import '../services/lan_chat_store.dart';
import '../services/bookmark_store.dart';
import '../services/crypto_v2.dart';
import '../services/chat_repo.dart';
import '../services/chat_organization_store.dart';
import '../services/call_service.dart';
import '../services/triangle_service.dart';
import '../services/nav_bar_settings.dart';
import '../widgets/glass.dart';
import '../widgets/skeleton.dart';
import '../widgets/avatar.dart';
import '../widgets/call_widget.dart';
import '../services/profile_cache.dart';
import '../widgets/toast_overlay.dart';
import '../widgets/connectivity_badge.dart';
import 'settings_screen.dart';
import 'profile_screen.dart';
import 'chat_list_screen.dart';
import 'lan_scan_screen.dart';
import 'lan_chat_screen.dart';
import 'chat_screen.dart';
import 'contacts_screen.dart';
import 'custom_camera_screen.dart';
import '../core/local/local_hub.dart';
import '../core/local/local_transport.dart';
import '../core/local/lan_settings.dart';
import '../core/local/lan_message_codec.dart';
import '../core/local/app_logger.dart';
import '../core/local/transports/lan_transport.dart';
import '../core/local/transports/bluetooth_transport.dart';
import '../core/local/transports/wifi_direct_transport.dart';

enum Section {
  chat(
    label: 'Чаты',
    iconOutline: CupertinoIcons.chat_bubble,
    iconFilled: CupertinoIcons.chat_bubble_fill,
  ),
  contacts(
    label: 'Контакты',
    iconOutline: CupertinoIcons.person_2,
    iconFilled: CupertinoIcons.person_2_fill,
  ),
  profile(
    label: 'Профиль',
    iconOutline: CupertinoIcons.person,
    iconFilled: CupertinoIcons.person,
  ),
  settings(
    label: 'Настройки',
    iconOutline: CupertinoIcons.settings,
    iconFilled: CupertinoIcons.settings_solid,
  );

  final String label;
  final IconData iconOutline;
  final IconData iconFilled;
  const Section({
    required this.label,
    required this.iconOutline,
    required this.iconFilled,
  });
}

class MainShell extends StatefulWidget {
  final VoidCallback onLoggedOut;
  final VoidCallback onRegister;
  const MainShell({
    super.key,
    required this.onLoggedOut,
    required this.onRegister,
  });
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Section _section = Section.chat;
  // Ручное "листание" между вкладками — один AnimationController на оба
  // экрана разом (старый едет в -dir, новый въезжает из +dir), вместо
  // AnimatedSwitcher: его transitionBuilder различает entering/exiting по
  // animation.status, а на практике оказалось ненадёжно (оба экрана
  // разъезжались от центра в стороны вместо того, чтобы один сменял
  // другого) — с одним контроллером и явным t никакой неоднозначности нет.
  late final AnimationController _sectionAnimCtrl = AnimationController(
    vsync: this,
    duration: PerformanceService.instance.animationControllerDuration(
      const Duration(milliseconds: 340),
    ),
  )..value = 1;
  Widget? _oldSectionChild;
  bool _bootstrapped = false;
  bool _isGuest = false;
  bool _sessionExitStarted = false;
  String? _username;
  String? _displayName;
  String? _error;
  StreamSubscription? _lanMsgSub;
  StreamSubscription? _lanCollectingSub;
  StreamSubscription? _lanAcceptSub;
  StreamSubscription? _lanStaleSub;
  StreamSubscription? _lanReconnectedSub;
  StreamSubscription? _lanAckSub;
  StreamSubscription? _lanSeenSub;
  StreamSubscription? _triangleMsgSub;
  Timer? _lanRetryTimer;
  // Локальные транспорты нужны для чатов "рядом" только пока приложение
  // действительно используется. В фоне BLE advertising/scan, Wi-Fi Direct,
  // UDP keepalive и широковещательные ретраи дают большой расход батареи,
  // тогда как серверные уведомления продолжают приходить через WS/FGS.
  bool _appBackgrounded = false;
  Future<void> _lifecycleTransition = Future<void>.value();
  // Не спамим — раз в сессию приложения на device_id достаточно.
  final Set<String> _notifiedStale = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appBackgrounded =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    AuthService.sessionInvalidNotifier.addListener(_onSessionInvalid);
    _bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final backgrounded =
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (state == AppLifecycleState.resumed) {
      _setAppBackgrounded(false);
    } else if (backgrounded) {
      _setAppBackgrounded(true);
    }
  }

  void _setAppBackgrounded(bool backgrounded) {
    if (_appBackgrounded == backgrounded) return;
    _appBackgrounded = backgrounded;
    _lifecycleTransition = _lifecycleTransition.then((_) async {
      if (!mounted) return;
      if (backgrounded) {
        _lanRetryTimer?.cancel();
        _lanRetryTimer = null;
        await localHub.stopAll();
        appLog.info(
          'power',
          'Фон: локальные транспорты и LAN-ретраи остановлены',
        );
      } else {
        await localHub.startAll();
        if (!mounted || _appBackgrounded) return;
        _startLanReconnectRetryLoop();
        // Однократная попытка восстановить локальные чаты после возврата;
        // периодический широковещательный цикл в фоне не запускается.
        unawaited(localHub.discoverAll());
        appLog.info(
          'power',
          'Активный режим: локальные транспорты восстановлены',
        );
      }
    });
  }

  void _onSessionInvalid() {
    if (!mounted || _isGuest || !AuthService.sessionInvalidNotifier.value)
      return;
    unawaited(_forceLogout());
  }

  /// Стартовая инициализация после успешного логина:
  /// 1. Загрузить юзера из AuthService.
  /// 2. Открыть БД для этого юзера.
  /// 3. Сгенерить/загрузить E2E ключи.
  /// 4. Подключить WebSocket.
  /// 5. Поднять LAN/BLE/Wi-Fi Direct — на уровне всего приложения (не только
  ///    пока открыт экран "Устройства поблизости"), т.к. LAN-чаты привязаны
  ///    к устройству и должны принимать сообщения независимо от экрана.
  ///
  /// Гость (шаги 2-4 и FCM пропускаются целиком) — гостевой аккаунт НИКАК
  /// не взаимодействует с сервером, доступны только LAN-чаты (шаг 5).
  Future<void> _bootstrap() async {
    try {
      _isGuest = await AuthService.isGuest();

      if (_isGuest) {
        await PrivacySettings.instance.loadForAccount('guest');
        _username = 'Гость';
        _displayName = 'Гость';
        await BookmarkStore.instance.init('guest');
        if (mounted) setState(() => _bootstrapped = true);
        unawaited(_startLanInBackground());
        // Гостевой режим тоже должен видеть совместимые обновления: проверка
        // версии не требует аккаунта и не трогает серверную сессию.
        unawaited(NotificationService.instance.ensurePermission());
        unawaited(UpdateService.instance.start());
        return;
      }

      final u = await AuthService.username();
      final dn = await AuthService.displayName();
      if (u == null) throw Exception('Нет username');
      _username = u;
      _displayName = dn ?? u;

      // Прогреваем тот же in-memory слой, который ProfileScreen читает
      // синхронно в первом build. После этого SettingsScreen не показывает
      // загрузчик на первом кадре, если профиль уже был сохранён на диске;
      // серверная перепроверка всё равно выполняется в фоне самим экраном.
      try {
        final cachedProfile = await ProfileCache.instance.getProfile(u);
        final cachedAvatar = cachedProfile?['avatar_url'];
        if (cachedAvatar is String && cachedAvatar.trim().isNotEmpty) {
          // Подгружаем картинку в память, не задерживая открытие приложения.
          unawaited(AvatarCache.instance.prime(cachedAvatar));
        }
      } catch (_) {
        // A cache read must not block application startup.
      }

      await PrivacySettings.instance.loadForAccount(u);

      await DbService.instance.init(u);
      await BookmarkStore.instance.init(u);
      await CryptoService.instance.ensureKeys(account: u);
      WsClient.instance.connect();
      unawaited(CallService.instance.initialize());
      // Треугольник (NAT-punch P2P апгрейд существующих серверных чатов) —
      // только для реальных аккаунтов, гостю сервер/контакты не доступны.
      _triangleMsgSub = triangleService.onMessage.listen(_onTriangleMessage);
      if (mounted) setState(() => _bootstrapped = true);
      unawaited(_startLanInBackground());
      // После логина — спросить разрешение на уведомления (если ещё не выдано).
      NotificationService.instance.ensurePermission();
      ForegroundService.instance.start();
      // Проверка стартует после построения MainShell: доступное обновление
      // появится кнопкой в сайдбаре и не перекроет рабочий экран.
      unawaited(UpdateService.instance.start());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _startLanInBackground() async {
    try {
      await _startLan();
    } catch (e, stack) {
      // LAN/BLE/Wi-Fi Direct are optional and must not block the main UI.
      appLog.warn('lan', 'background startup skipped: $e\n$stack');
    }
  }

  Future<void> _startLan() async {
    await LanChatStore.instance.init();
    await LanSettings().load();
    await CryptoV2.instance.ensureKeys(account: _username ?? 'guest');

    localHub.registerDefaults([
      LanTransport(),
      WifiDirectTransport(),
      BluetoothTransport(),
    ]);
    _lanMsgSub = localHub.onMessage.listen(_onLanMessage);
    _lanCollectingSub = localHub.onCollecting.listen(_onLanSignalCaught);
    _lanAcceptSub = localHub.onAccept.listen(_onLanAccepted);
    _lanStaleSub = localHub.onStaleContact.listen(_onLanStaleContact);
    // "Снова на связи" — срабатывает когда МЫ автопринимаем чужой сигнал от
    // уже известного устройства (см. _onRawRequest в local_hub.dart). Сторону
    // "мы сами достучались" покрывает _startLanReconnectRetryLoop ниже —
    // обе стороны реконнекта озвучиваются одинаково через _onLanReconnected.
    _lanReconnectedSub = localHub.onReconnected.listen(
      (p) => _onLanReconnected(p.deviceId),
    );
    // Статусы галочек для LAN-чата — работают глобально, а не только пока
    // открыт сам LanChatScreen (тот же принцип, что и _onLanMessage ниже).
    _lanAckSub = localHub.onAck.listen(
      (e) => LanChatStore.instance.markDelivered(e.fromUsername, e.msgId),
    );
    _lanSeenSub = localHub.onSeen.listen(
      (e) => LanChatStore.instance.markMessagesRead(e.fromUsername, e.msgIds),
    );
    localHub.isKnownPeerChecker = (deviceId) async =>
        (await LanChatStore.instance.getDisplayName(deviceId)) != null;
    await localHub.startAll();
    if (!_appBackgrounded) {
      _startLanReconnectRetryLoop();
    } else {
      // Lifecycle мог смениться, пока выполнялся bootstrap.
      await localHub.stopAll();
    }
  }

  /// Идея "фоновый ретрай": пока приложение открыто, раз в 30с тихо
  /// широковещаем discover, если среди уже известных устройств есть хоть
  /// одно офлайн — так чаты сами оживают, не дожидаясь, пока другая сторона
  /// первой пришлёт сигнал (то же самое, что делает кнопка "Попробовать" в
  /// LanChatScreen, только не глядя и не по чуть — сразу для всех разом).
  void _startLanReconnectRetryLoop() {
    _lanRetryTimer?.cancel();
    _lanRetryTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final known = LanChatStore.instance.knownDevicesNotifier.value;
      final offlineBefore = known
          .where((d) => !localHub.hasSession(d.deviceId))
          .map((d) => d.deviceId)
          .toSet();
      if (offlineBefore.isEmpty) return;
      await localHub.discoverAll();
      // Даём окну сбора сигналов на другой стороне (5с) время сработать.
      await Future.delayed(const Duration(seconds: 6));
      if (!mounted) return;
      for (final id in offlineBefore) {
        if (localHub.hasSession(id)) _onLanReconnected(id);
      }
    });
  }

  /// Кто-то принял наш запрос (или мы приняли его — sendAccept тоже шлёт
  /// себе через localHub) → сохранить чат в LanChatStore СРАЗУ, независимо
  /// от того, открыт ли сейчас экран "Устройства поблизости". Без этого
  /// сторона, которая не смотрела в этот экран в момент прилёта accept-
  /// пакета, никогда не получала запись чата — сообщения приходили, но
  /// showить их было некуда (createOrGetChat ни разу не вызывался).
  Future<void> _onLanAccepted(LocalPeer peer) async {
    final identityOk = await LanChatStore.instance.checkAndPinIdentity(
      peer.deviceId,
      peer.identityPubB64,
    );
    if (!identityOk) {
      appLog.warn(
        'security',
        'Identity ${peer.deviceId} изменилась — отклонено',
      );
      return;
    }
    await LanChatStore.instance.createOrGetChat(
      deviceId: peer.deviceId,
      // Полный device_id, не усечённый peer.label ("xxxxxxxx…") — иначе
      // диалог переименования (LanChatScreen._rename) предзаполняется
      // нечитаемым обрубком с многоточием вместо полного значения.
      displayName: peer.deviceId,
      peerPubB64: peer.x25519PubB64,
      identityPubB64: peer.identityPubB64,
      transport: peer.chatType,
    );
  }

  /// Сигнал пойман (не дожидаясь конца 5-сек окна сбора — реагируем сразу):
  /// приложение свёрнуто → системный пуш; приложение открыто, но не на
  /// экране "Устройства поблизости" → тост с переходом туда; если юзер уже
  /// там — карточка на самом экране сбора и так всё покажет, дублировать
  /// не нужно.
  void _onLanSignalCaught(LocalPeer peer) {
    if (LanScanScreen.isVisible) return;
    final backgrounded =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    if (backgrounded) {
      NotificationService.instance.onLanRequest(label: _shortId(peer.deviceId));
      return;
    }
    toast.show(
      'Поймали сигнал от ${_shortId(peer.deviceId)}',
      level: ToastLevel.info,
      action: ToastAction(
        label: 'Открыть',
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const LanScanScreen())),
      ),
    );
  }

  String _shortId(String deviceId) =>
      deviceId.length > 8 ? '${deviceId.substring(0, 8)}…' : deviceId;

  /// Общая точка для "снова на связи" — не важно, кто был инициатором
  /// (мы сами достучались фоновым ретраем/кнопкой, или это они пришли к
  /// нам и мы их тихо автопринятые) — юзер должен узнать одинаково в обоих
  /// случаях. Не пушим системным уведомлением (это не входящее сообщение,
  /// каждый реконнект слать пуш — спам), только тихий тост, и только если
  /// юзер прямо сейчас не смотрит в этот самый чат (там и так видно).
  Future<void> _onLanReconnected(String deviceId) async {
    _flushLanQueue(deviceId);
    if (LanChatScreen.currentOpenDeviceId == deviceId) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed)
      return;
    final name =
        await LanChatStore.instance.getDisplayName(deviceId) ??
        _shortId(deviceId);
    if (!mounted) return;
    toast.show(
      '$name снова на связи',
      level: ToastLevel.info,
      action: ToastAction(
        label: 'Открыть',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                LanChatScreen(deviceId: deviceId, displayName: name),
          ),
        ),
      ),
    );
  }

  /// Устройство снова на связи — досылаем всё, что накопилось в очереди,
  /// пока его не было (см. LanChatScreen._send: офлайн-отправка не блокируется,
  /// сообщение шифруется и кладётся в БД с queued=true сразу).
  Future<void> _flushLanQueue(String deviceId) async {
    final queued = await LanChatStore.instance.getQueuedMessages(deviceId);
    if (queued.isEmpty) return;
    final peerPubB64 = await LanChatStore.instance.getPeerPub(deviceId);
    if (peerPubB64 == null) return;
    for (final m in queued) {
      if (!localHub.hasSession(deviceId)) break; // отвалилось посреди флаша
      try {
        final encB64 = m.isControl
            ? await encodeLanControlEnvelope(
                peerPubB64: peerPubB64,
                action: m.controlAction!,
                targetMsgId: m.controlTargetMsgId!,
                text: m.controlText,
              )
            : await encodeLanEnvelope(
                peerPubB64: peerPubB64,
                text: m.text,
                fileName: m.fileName,
                fileMime: m.fileMime,
                fileBytes: m.fileBytes,
                replyPreview: m.replyPreview,
              );
        await localHub.sendMessage(
          deviceId,
          m.msgId,
          encB64,
          m.createdAt * 1000,
          replyToMsgId: m.isControl ? '' : (m.replyToMsgId ?? ''),
        );
        await LanChatStore.instance.markSent(deviceId, m.msgId);
      } catch (_) {
        // Останется queued — попробуем на следующем реконнекте.
      }
    }
  }

  /// Входящее P2P-сообщение по «Треугольнику» — заводим в тот же чат, что
  /// и обычные серверные сообщения (см. ChatRepo.ingestTriangleMessage).
  Future<void> _onTriangleMessage(TriangleTextMessage m) async {
    await ChatRepo.instance.ingestTriangleMessage(
      fromUsername: m.fromUsername,
      text: m.text,
      sentAtMs: m.sentAtMs,
    );
  }

  /// Пинг от устройства, чат с которым удалён на этом телефоне — понг ему
  /// НЕ уходит (см. LocalHub._handlePingReceived), но юзер должен узнать:
  /// это может быть попытка старого контакта восстановить связь. Открывает
  /// тот же экран "Устройства поблизости" — там можно заблокировать.
  void _onLanStaleContact(String deviceId) {
    if (_notifiedStale.contains(deviceId)) return;
    _notifiedStale.add(deviceId);
    final label = _shortId(deviceId);
    final backgrounded =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    if (backgrounded) {
      NotificationService.instance.onLanStaleContact(label: label);
      return;
    }
    toast.show(
      'Сигнал от старого устройства ($label) — чат был удалён',
      level: ToastLevel.warn,
      action: ToastAction(
        label: 'Открыть',
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const LanScanScreen())),
      ),
    );
  }

  /// Входящее LAN-сообщение → расшифровать (ключ пира взят из БД LAN-чатов,
  /// сохранённый там при подключении) и сохранить в историю. Работает даже
  /// если экран этого чата сейчас не открыт. ЕДИНСТВЕННОЕ место, которое
  /// пишет входящие LAN-сообщения в БД — LanChatScreen (если открыт) только
  /// читает результат, не расшифровывает повторно (иначе гонка за один и
  /// тот же msg_id между двумя параллельными decrypt+insert).
  Future<void> _onLanMessage(LocalMessageEvent m) async {
    try {
      final decoded = await decodeLanMessage(m);
      if (decoded == null) return;
      if (decoded.actionType != null &&
          decoded.actionTargetMsgId != null &&
          decoded.actionTargetMsgId!.isNotEmpty) {
        await LanChatStore.instance.applyRemoteControlAction(
          deviceId: m.fromUsername,
          action: decoded.actionType!,
          targetMsgId: decoded.actionTargetMsgId!,
          text: decoded.actionText,
        );
        return;
      }
      await LanChatStore.instance.addMessage(
        deviceId: m.fromUsername,
        msgId: m.msgId,
        fromMe: false,
        text: decoded.text,
        // sentAt приходит в миллисекундах (см. LocalHub keepalive), а БД
        // хранит секунды — как created_at в DbService.
        createdAtSec: m.sentAt > 0 ? m.sentAt ~/ 1000 : null,
        fileName: decoded.fileName,
        fileMime: decoded.fileMime,
        fileBytes: decoded.fileBytes,
        replyToMsgId: m.replyToMsgId,
        replyPreview: decoded.replyPreview,
      );
    } catch (_) {}
  }

  Future<void> _refreshIdentityFromStorage() async {
    final username = await AuthService.username();
    final displayName = await AuthService.displayName();
    if (!mounted || username == null) return;
    setState(() {
      _username = username;
      _displayName = displayName ?? username;
    });
  }

  Future<void> _logout() async {
    if (_sessionExitStarted) return;
    _sessionExitStarted = true;
    await _closeSession();
    await AuthService.logout();
    if (mounted) widget.onLoggedOut();
  }

  Future<void> _forceLogout() async {
    if (_sessionExitStarted) return;
    _sessionExitStarted = true;
    await _closeSession();
    // Сервер уже отклонил токен. Полный локальный logout нужен, чтобы
    // приложение не продолжало считать этот аккаунт активным.
    await AuthService.logout();
    if (mounted) widget.onLoggedOut();
  }

  Future<void> _closeSession() async {
    appLog.info('auth', 'closing local session state');
    await CallService.instance.end(notify: false);
    await UpdateService.instance.stop();
    // Сначала очищаем account-scoped notifiers. Иначе новый аккаунт успевает
    // увидеть старый список чатов/закладок, пока SQLite ещё закрывается.
    await ChatRepo.instance.dispose();
    await BookmarkStore.instance.dispose();
    PrivacySettings.instance.reset();
    if (!_isGuest) {
      await ForegroundService.instance.stop();
      await WsClient.instance.disconnect();
      await DbService.instance.close();
      await CryptoService.instance.wipe();
    }
  }

  /// Гость жмёт "Зарегистрироваться" — та же зачистка гостевой сессии, что и
  /// при обычном выходе, только ведёт на вкладку регистрации, а не логина.
  Future<void> _goRegister() async {
    await _closeSession();
    await AuthService.logout();
    widget.onRegister();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AuthService.sessionInvalidNotifier.removeListener(_onSessionInvalid);
    _lanMsgSub?.cancel();
    _lanCollectingSub?.cancel();
    _lanAcceptSub?.cancel();
    _lanStaleSub?.cancel();
    _lanReconnectedSub?.cancel();
    _lanAckSub?.cancel();
    _lanSeenSub?.cancel();
    _lanRetryTimer?.cancel();
    _triangleMsgSub?.cancel();
    localHub.stopAll();
    _sectionAnimCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold'ы ниже прозрачные и рассчитаны на фон снаружи — как во всех
    // остальных экранах приложения (mesh-сетка), а не плоский градиент.
    return MeshBackground(
      callWidgetPlacement: CallWidgetPlacement.bottom,
      callWidgetStyle: CallWidgetStyle.card,
      child: Stack(
        children: [
          _content(context),
          ConnectivityBadge(isGuest: _isGuest),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: GlassCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.exclamationmark_circle,
                    size: 48,
                    color: GE.red,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Не удалось запустить:\n$_error',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: GE.text),
                  ),
                  const SizedBox(height: 16),
                  GlassButton(label: 'Выйти', danger: true, onTap: _logout),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (!_bootstrapped) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(child: SkeletonDialogList()),
      );
    }
    final isWide = MediaQuery.of(context).size.width >= 720;
    return Scaffold(
      backgroundColor: Colors.transparent,
      // Сайдбар — фиксированная колонка (лого + пункты + футер аккаунта) без
      // скролла: если Scaffold сжимает body под клавиатуру, она не влезает и
      // оверфлоится. На wide-раскладке клавиатура просто перекрывает контент
      // снизу, как на десктопе, сайдбар не должен сжиматься.
      resizeToAvoidBottomInset: !isWide,
      body: isWide ? _wideLayout() : _mobileLayout(),
    );
  }

  // Направление "листания" — куда уехал таб в баре относительно текущего:
  // +1 = новая вкладка правее (контент въезжает справа), -1 = левее.
  int _slideDir = 1;

  void _switchSection(Section s) {
    if (s == _section) return;
    HapticFeedback.selectionClick();
    final order = NavBarSettings.instance.orderNotifier.value;
    final oldIdx = order.indexOf(_section);
    final newIdx = order.indexOf(s);
    _slideDir = (newIdx >= oldIdx) ? 1 : -1;
    _oldSectionChild = RepaintBoundary(
      child: KeyedSubtree(key: ValueKey(_section), child: _sectionBody()),
    );
    setState(() => _section = s);
    _sectionAnimCtrl
      ..value = 0
      ..forward().whenCompleteOrCancel(() {
        if (mounted) setState(() => _oldSectionChild = null);
      });
  }

  // ─── Layout: mobile (≤720) ─────────────────────────────────────────
  // Нижний бар — ПЛАВАЮЩАЯ плашка НАД контентом (Positioned), а не отдельный
  // блок в Column: контент занимает весь экран и при скролле проезжает под
  // баром, а не упирается в его границу (раньше Column+Expanded резервировал
  // под бар реальное место, из-за чего контент грубо обрывался на голом
  // mesh-фоне вместо продолжения под плашкой). Каждый таб-экран сам добавляет
  // себе нижний padding под высоту бара для конечного состояния скролла.
  Widget _mobileLayout() {
    return Stack(
      children: [
        // Без Positioned.fill Stack брал высоту гостевого ScrollView по его
        // содержимому. Тогда bottom:0 у навигации означал конец контента, а
        // не низ экрана — панель визуально уезжала вверх.
        Positioned.fill(child: _animatedSectionBody()),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _GlassBottomNav(
            current: _section,
            onTap: _switchSection,
            username: _username,
            displayName: _displayName,
          ),
        ),
        // Плавающие кружки "новый чат"/"камера" — только на вкладке Чатов
        // (в других вкладках нет смысла: некуда открывать чат/слать фото).
        if (_section == Section.chat)
          ValueListenableBuilder<AppUpdateUiState>(
            valueListenable: UpdateService.instance.uiState,
            builder: (context, updateState, _) => Positioned(
              right: 16,
              bottom:
                  88 +
                  MediaQuery.of(context).padding.bottom +
                  (updateState.isVisible ? 90 : 0),
              child: _QuickActionButtons(isGuest: _isGuest),
            ),
          ),
        ValueListenableBuilder<AppUpdateUiState>(
          valueListenable: UpdateService.instance.uiState,
          builder: (context, state, _) {
            if (!state.isVisible || state.info == null) {
              return const SizedBox.shrink();
            }
            return Positioned(
              left: 16,
              right: 16,
              bottom: 88 + MediaQuery.of(context).padding.bottom,
              child: _UpdateRailAction(
                state: state,
                onTap: state.isBusy
                    ? null
                    : () {
                        unawaited(
                          UpdateService.instance
                              .downloadAndOpen(context, state.info!)
                              .catchError((Object _) {}),
                        );
                      },
              ),
            );
          },
        ),
      ],
    );
  }

  // ─── Layout: desktop/tablet (>720) ─────────────────────────────────
  Widget _wideLayout() {
    return Row(
      children: [
        _SideRail(
          current: _section,
          onTap: _switchSection,
          username: _username ?? '?',
          displayName: _displayName ?? _username ?? '?',
          onLogout: _logout,
        ),
        Expanded(child: _animatedSectionBody()),
      ],
    );
  }

  Widget _sectionBody() {
    // Пока заглушки. M5-M7 их наполнят.
    switch (_section) {
      case Section.chat:
        return ChatListScreen(
          isGuest: _isGuest,
          username: _username,
          displayName: _displayName,
        );
      case Section.contacts:
        return ContactsScreen(
          isGuest: _isGuest,
          onRegister: () => unawaited(_goRegister()),
        );
      case Section.profile:
        if (_isGuest)
          return _GuestPane(onExit: _logout, onRegister: _goRegister);
        return ProfileScreen(
          username: _username ?? '?',
          isOwn: true,
          embedded: true,
        );
      case Section.settings:
        return SettingsScreen(
          isGuest: _isGuest,
          username: _username,
          embedded: true,
          onLogout: _logout,
          onProfileChanged: () => unawaited(_refreshIdentityFromStorage()),
        );
    }
  }

  /// Переключение вкладок нижнего бара — горизонтальный слайд + fade, один
  /// общий AnimationController на оба экрана (см.
  /// _sectionAnimCtrl/_oldSectionChild/_slideDir).
  Widget _animatedSectionBody() {
    final newChild = RepaintBoundary(
      child: KeyedSubtree(key: ValueKey(_section), child: _sectionBody()),
    );
    final oldChild = _oldSectionChild;
    if (oldChild == null) return newChild;
    return AnimatedBuilder(
      animation: _sectionAnimCtrl,
      builder: (context, _) {
        final raw = Curves.easeInOutCubic.transform(_sectionAnimCtrl.value);
        final dir = _slideDir.toDouble();
        return Stack(
          children: [
            FractionalTranslation(
              translation: Offset(-dir * raw, 0),
              child: Opacity(
                opacity: (1 - raw).clamp(0.0, 1.0),
                child: oldChild,
              ),
            ),
            FractionalTranslation(
              translation: Offset(dir * (1 - raw), 0),
              child: Opacity(opacity: raw.clamp(0.0, 1.0), child: newChild),
            ),
          ],
        );
      },
    );
  }

  Widget _placeholder(IconData icon, String title, String body) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: GlassCard(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: GE.primary.withValues(alpha: 0.7)),
              const SizedBox(height: 14),
              Text(
                title,
                style: TextStyle(
                  color: GE.text,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  body,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GE.sub, fontSize: 13, height: 1.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Кружки "камера"/"новый чат" снизу справа (плавают над нижним баром) ────
class _QuickActionButtons extends StatelessWidget {
  final bool isGuest;
  const _QuickActionButtons({required this.isGuest});

  Future<void> _onCamera(BuildContext context) async {
    if (isGuest) {
      toast.show('Недоступно гостю');
      return;
    }
    final File? x;
    try {
      x = await Navigator.of(context).push<File>(
        MaterialPageRoute(builder: (_) => const GhostCameraScreen()),
      );
    } catch (e) {
      toast.show('Камера недоступна: $e');
      return;
    }
    if (x == null || !context.mounted) return;
    await _pickRecipientAndSendPhoto(
      context,
      sourcePath: x.path,
      fileName: x.path.split(Platform.pathSeparator).last,
      localPath: x.path,
    );
  }

  Future<void> _pickRecipientAndSendPhoto(
    BuildContext context, {
    required String sourcePath,
    required String fileName,
    required String localPath,
  }) async {
    final dialogs = ChatRepo.instance.dialogsNotifier.value
        .where(
          (d) =>
              !d.username.startsWith('g:') &&
              !d.username.startsWith(lanDialogPrefix) &&
              !d.username.startsWith(bookmarkDialogPrefix) &&
              ChatOrganizationStore.instance.canSeeChatInActiveScenario(
                d.username,
              ),
        )
        .toList();
    final peer = await showGlassSheet<String>(
      context,
      child: SafeArea(child: _RecipientPicker(dialogs: dialogs)),
    );
    if (peer == null || peer.isEmpty || !context.mounted) return;
    await ChatRepo.instance.sendDmFileFromPath(
      toUsername: peer,
      sourcePath: sourcePath,
      mime: 'image/jpeg',
      fileName: fileName,
      localPath: localPath,
    );
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(peer: peer, displayName: peer),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _circle(
          icon: CupertinoIcons.camera_fill,
          color: GE.blue,
          onTap: () => _onCamera(context),
        ),
        const SizedBox(height: 12),
        _circle(
          icon: CupertinoIcons.square_pencil_fill,
          color: GE.primary,
          onTap: () => showNewChatMenu(context, isGuest: isGuest),
        ),
      ],
    );
  }

  Widget _circle({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.listPlatesNotifier,
      builder: (_, showPlate, _) {
        final traditional =
            ThemeService.instance.styleNotifier.value == ThemeStyle.traditional;
        // Традиционный стиль убирает glow, но не саму поверхность кнопки:
        // заливку отключает только общий переключатель фона карточек.
        final filled = showPlate;
        return PressScale(
          onTap: onTap,
          child: Container(
            width: 48,
            height: 48,
            decoration: filled
                ? BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    boxShadow: traditional
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.22),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : [
                            BoxShadow(
                              color: color.withValues(alpha: 0.4),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                  )
                : null,
            child: Icon(icon, color: filled ? Colors.white : color, size: 22),
          ),
        );
      },
    );
  }
}

/// Мини-пикер получателя для быстрого фото с камеры: недавние диалоги +
/// ручной ввод @username. Не полноценный поиск (SearchService) — MVP.
class _RecipientPicker extends StatefulWidget {
  final List<StoredDialog> dialogs;
  const _RecipientPicker({required this.dialogs});
  @override
  State<_RecipientPicker> createState() => _RecipientPickerState();
}

class _RecipientPickerState extends State<_RecipientPicker> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Отправить фото кому?',
            style: TextStyle(
              color: GE.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: widget.dialogs.isEmpty,
            style: TextStyle(color: GE.text),
            decoration: InputDecoration(
              hintText: '@username',
              hintStyle: TextStyle(color: GE.sub),
            ),
            onSubmitted: (v) =>
                Navigator.pop(context, v.trim().replaceFirst('@', '')),
          ),
          if (widget.dialogs.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.dialogs.length,
                itemBuilder: (_, i) {
                  final d = widget.dialogs[i];
                  return PressScale(
                    onTap: () => Navigator.pop(context, d.username),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        d.displayName,
                        style: TextStyle(color: GE.text, fontSize: 14),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Bottom-nav в glass-стиле (сворачиваемый) ──────────────────────────
class _GlassBottomNav extends StatefulWidget {
  final Section current;
  final ValueChanged<Section> onTap;
  final String? username;
  final String? displayName;
  const _GlassBottomNav({
    required this.current,
    required this.onTap,
    this.username,
    this.displayName,
  });

  @override
  State<_GlassBottomNav> createState() => _GlassBottomNavState();
}

class _GlassBottomNavState extends State<_GlassBottomNav> {
  bool _collapsed = false;
  // Режим перестановки табов — включается долгим нажатием на любой таб: над
  // иконками появляются ручки для драга ПРЯМО в баре (без шторки/меню).
  // Выход — тап на "Готово", который заменяет шеврон на время режима.
  bool _reorderMode = false;

  void _enterReorderMode() {
    if (_reorderMode) return;
    HapticFeedback.mediumImpact();
    setState(() => _reorderMode = true);
  }

  void _exitReorderMode() {
    HapticFeedback.selectionClick();
    setState(() => _reorderMode = false);
  }

  Future<void> _renameSection(Section s) async {
    final ctrl = TextEditingController(
      text: NavBarSettings.instance.labelFor(s),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Переименовать вкладку', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: GE.text),
          decoration: InputDecoration(
            hintText: s.label,
            hintStyle: TextStyle(color: GE.sub),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: Text('Сохранить', style: TextStyle(color: GE.primary)),
          ),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final labels = Map.of(NavBarSettings.instance.labelOverridesNotifier.value);
    if (result.isEmpty || result == s.label) {
      labels.remove(s.name);
    } else {
      labels[s.name] = result;
    }
    NavBarSettings.instance.save(
      order: NavBarSettings.instance.orderNotifier.value,
      labelOverrides: labels,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // Шеврон — АБСОЛЮТНО прозрачный, без своего blur/фона (раньше сидел под
    // тем же BackdropFilter, что и панель, и потому выглядел размытым/на
    // подложке — по факту не отличить от обычного бара). Плавает сам по
    // себе над таблеткой. В режиме перестановки на его месте — "Готово".
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _reorderMode
              ? _exitReorderMode
              : () => setState(() => _collapsed = !_collapsed),
          child: SizedBox(
            width: 72,
            height: 22,
            child: Center(
              child: _reorderMode
                  ? Text(
                      'Готово',
                      style: TextStyle(
                        color: GE.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        shadows: const [
                          Shadow(color: Colors.black87, blurRadius: 10),
                          Shadow(color: Colors.black54, blurRadius: 3),
                        ],
                      ),
                    )
                  : AnimatedRotation(
                      turns: _collapsed ? 0.5 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: Icon(
                        CupertinoIcons.chevron_down,
                        size: 20,
                        color: GE.sub.withValues(alpha: 0.65),
                        shadows: const [
                          Shadow(color: Colors.black87, blurRadius: 10),
                          Shadow(color: Colors.black54, blurRadius: 3),
                        ],
                      ),
                    ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _collapsed
              ? SizedBox(width: double.infinity, height: bottomInset)
              : Padding(
                  padding: EdgeInsets.only(
                    left: 14,
                    right: 14,
                    bottom: 8 + bottomInset,
                  ),
                  // Таблетка: фон/блюр/бордер — только если включена настройка
                  // "Фон карточек-списков" (тот же общий тумблер, что и везде).
                  child: AnimatedBuilder(
                    animation: Listenable.merge([
                      ThemeService.instance.navBarPlateNotifier,
                      PerformanceService.instance.reducedEffectsNotifier,
                      NavBarSettings.instance.backgroundNotifier,
                      NavBarSettings.instance.labelsVisibleNotifier,
                      NavBarSettings.instance.selectedBackgroundNotifier,
                      NavBarSettings.instance.selectedScaleNotifier,
                      NavBarSettings.instance.selectedFlyoutNotifier,
                    ]),
                    builder: (_, _) {
                      final showBg =
                          NavBarSettings.instance.backgroundNotifier.value;
                      final reducedEffects =
                          PerformanceService.instance.reducedEffects;
                      final radius = BorderRadius.circular(
                        GE.radiusLg.clamp(0, 32),
                      );
                      final row = ValueListenableBuilder<List<Section>>(
                        valueListenable: NavBarSettings.instance.orderNotifier,
                        builder: (_, order, _) =>
                            ValueListenableBuilder<Map<String, String>>(
                              valueListenable: NavBarSettings
                                  .instance
                                  .labelOverridesNotifier,
                              builder: (_, _, _) => _reorderMode
                                  ? SizedBox(
                                      height: 64,
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final itemWidth =
                                              constraints.maxWidth /
                                              order.length;
                                          return ReorderableListView(
                                            scrollDirection: Axis.horizontal,
                                            buildDefaultDragHandles: false,
                                            onReorder: (oldIdx, newIdx) {
                                              final list = List.of(order);
                                              if (newIdx > oldIdx) newIdx -= 1;
                                              final s = list.removeAt(oldIdx);
                                              list.insert(newIdx, s);
                                              NavBarSettings.instance.save(
                                                order: list,
                                                labelOverrides: NavBarSettings
                                                    .instance
                                                    .labelOverridesNotifier
                                                    .value,
                                              );
                                            },
                                            children: [
                                              for (
                                                int i = 0;
                                                i < order.length;
                                                i++
                                              )
                                                _navItemReorder(
                                                  order[i],
                                                  i,
                                                  itemWidth,
                                                ),
                                            ],
                                          );
                                        },
                                      ),
                                    )
                                  : LayoutBuilder(
                                      builder: (context, constraints) {
                                        final emphasis =
                                            NavBarSettings
                                                .instance
                                                .selectedScaleNotifier
                                                .value ||
                                            NavBarSettings
                                                .instance
                                                .selectedFlyoutNotifier
                                                .value;
                                        final activeWeight = emphasis
                                            ? 1.5
                                            : 1.0;
                                        final totalWeight = order.fold<double>(
                                          0,
                                          (total, section) =>
                                              total +
                                              (section == widget.current
                                                  ? activeWeight
                                                  : 1.0),
                                        );
                                        final unitWidth = totalWeight == 0
                                            ? 0.0
                                            : constraints.maxWidth /
                                                  totalWeight;
                                        return Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            for (final s in order)
                                              _navItem(
                                                s,
                                                width:
                                                    unitWidth *
                                                    (s == widget.current
                                                        ? activeWeight
                                                        : 1.0),
                                              ),
                                          ],
                                        );
                                      },
                                    ),
                            ),
                      );
                      final content = Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: row,
                      );
                      if (!showBg || reducedEffects) return content;
                      return ClipRRect(
                        borderRadius: radius,
                        child: BackdropFilter(
                          filter: ImageFilter.blur(
                            sigmaX: GE.glassBlur,
                            sigmaY: GE.glassBlur,
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color.alphaBlend(
                                GE.surface.withValues(alpha: 0.75),
                                GE.bg,
                              ),
                              borderRadius: radius,
                              border: Border.all(color: GE.border, width: 0.6),
                            ),
                            child: content,
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  /// Вариант таба в режиме перестановки: ручка сверху (fade-in), тап по
  /// подписи — переименование, сам таб не переключает секцию (нет смысла,
  /// пока идёт драг-режим).
  Widget _navItemReorder(Section s, int index, double width) {
    return SizedBox(
      key: ValueKey(s.name),
      width: width,
      child: ReorderableDragStartListener(
        index: index,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              builder: (context, t, _) => Opacity(
                opacity: t,
                child: Padding(
                  padding: EdgeInsets.only(bottom: 4 * t),
                  child: Icon(Icons.drag_indicator, size: 18, color: GE.sub),
                ),
              ),
            ),
            _navIcon(s, active: false, size: 22),
            const SizedBox(height: 3),
            GestureDetector(
              onTap: () => _renameSection(s),
              child: Text(
                NavBarSettings.instance.labelFor(s),
                style: TextStyle(
                  color: GE.sub,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navItem(Section s, {required double width}) {
    final active = s == widget.current;
    // Общий фон таблетки настраивается отдельно. У пунктов не должно быть
    // чёрной подложки: она ломала светлые темы и не соответствовала палитре.
    // Активный пункт получает лёгкий чип из цвета темы, неактивный прозрачен.
    final settings = NavBarSettings.instance;
    final showLabels = settings.labelsVisibleNotifier.value;
    // Вылет активной подписи — отдельная настройка: он должен работать и
    // при выключенных постоянных подписях под иконками.
    final flyoutEnabled = settings.selectedFlyoutNotifier.value;
    final flyout = active && flyoutEnabled;
    return AnimatedContainer(
      width: width,
      duration: PerformanceService.instance.animationDuration(
        const Duration(milliseconds: 260),
      ),
      curve: Curves.easeInOutCubic,
      child: PressScale(
        onTap: () => widget.onTap(s),
        onLongPress: _enterReorderMode,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: AnimatedScale(
            scale: active && settings.selectedScaleNotifier.value ? 1.1 : 1,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: active && settings.selectedBackgroundNotifier.value
                    ? GE.primary.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(GE.radiusSm),
                border: active && settings.selectedBackgroundNotifier.value
                    ? Border.all(
                        color: GE.primary.withValues(alpha: 0.28),
                        width: 0.6,
                      )
                    : null,
              ),
              child: SizedBox(
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  child: flyout
                      ? LayoutBuilder(
                          builder: (context, constraints) {
                            final labelWidth = (constraints.maxWidth - 28)
                                .clamp(0.0, 70.0)
                                .toDouble();
                            return Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                ClipRect(
                                  child: TweenAnimationBuilder<double>(
                                    key: ValueKey('flyout:${s.name}'),
                                    tween: Tween(begin: 0, end: 1),
                                    duration: const Duration(milliseconds: 260),
                                    curve: Curves.easeOutCubic,
                                    builder: (_, t, _) => SizedBox(
                                      width: labelWidth * t,
                                      child: Opacity(
                                        opacity: t,
                                        child: Text(
                                          NavBarSettings.instance.labelFor(s),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: GE.primary,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (labelWidth > 0) const SizedBox(width: 2),
                                _navIcon(s, active: active),
                              ],
                            );
                          },
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _navIcon(s, active: active),
                            if (showLabels && !flyoutEnabled) ...[
                              const SizedBox(height: 2),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  NavBarSettings.instance.labelFor(s),
                                  maxLines: 1,
                                  softWrap: false,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: active ? GE.primary : GE.sub,
                                    fontSize: 10.5,
                                    fontWeight: active
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
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

  Widget _navIcon(Section section, {required bool active, double size = 24}) {
    Widget fallback() => Icon(
      active ? section.iconFilled : section.iconOutline,
      size: size,
      color: active ? GE.primary : GE.sub,
    );

    if (section != Section.profile || widget.username == null) {
      return fallback();
    }

    return ValueListenableBuilder<int>(
      valueListenable: ProfileCache.instance.revision,
      builder: (_, _, _) {
        final profile = ProfileCache.instance.getProfileSync(widget.username!);
        final rawUrl = profile?['avatar_url'];
        final avatarUrl = rawUrl is String && rawUrl.trim().isNotEmpty
            ? rawUrl
            : null;
        if (avatarUrl == null) return fallback();
        return GhostAvatar(
          avatarUrl: avatarUrl,
          fallbackText: widget.displayName ?? widget.username!,
          size: size,
          fallbackColors: [GE.primary, GE.primary2],
        );
      },
    );
  }
}

// ── Боковой Rail для десктопа ──────────────────────────────────────────
class _SideRail extends StatelessWidget {
  final Section current;
  final ValueChanged<Section> onTap;
  final String username, displayName;
  final VoidCallback onLogout;
  const _SideRail({
    required this.current,
    required this.onTap,
    required this.username,
    required this.displayName,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: GE.glassFill,
        border: Border(right: BorderSide(color: GE.glassBorder, width: 1)),
      ),
      child: Column(
        children: [
          // Brand-header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: ShaderMask(
              shaderCallback: (b) => LinearGradient(
                colors: [Colors.white, GE.primary],
              ).createShader(b),
              child: const Text(
                'Ghost',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          Divider(color: GE.glassBorder, height: 1),
          const SizedBox(height: 8),
          // Прокручиваемый список пунктов — в ландшафте высота мала (~393 lp),
          // фикс-колонка не влезала (overflow 11px). Теперь пункты скроллятся,
          // лого-аут остаётся прижат снизу.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  // «Профиль» из навигации убран — его роль выполняет строка
                  // пользователя внизу сайдбара.
                  for (final s in Section.values.where(
                    (s) => s != Section.profile,
                  ))
                    _RailItem(s, s == current, () => onTap(s)),
                ],
              ),
            ),
          ),
          ValueListenableBuilder<AppUpdateUiState>(
            valueListenable: UpdateService.instance.uiState,
            builder: (context, state, _) {
              if (!state.isVisible || state.info == null) {
                return const SizedBox.shrink();
              }
              return _UpdateRailAction(
                state: state,
                onTap: state.isBusy
                    ? null
                    : () {
                        unawaited(
                          UpdateService.instance
                              .downloadAndOpen(context, state.info!)
                              .catchError((Object _) {}),
                        );
                      },
              );
            },
          ),
          Divider(color: GE.glassBorder, height: 1),
          // Профиль пользователя — тап ведёт во вкладку «Профиль» (НЕ выход;
          // выход — внутри профиля, с подтверждением). Подсвечивается активным.
          PressScale(
            onTap: () => onTap(Section.profile),
            child: Container(
              color: current == Section.profile
                  ? GE.primary.withValues(alpha: 0.12)
                  : null,
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  GhostAvatar(
                    avatarUrl:
                        ProfileCache.instance.getProfileSync(
                              username,
                            )?['avatar_url']
                            as String?,
                    fallbackText: displayName,
                    size: 36,
                    fallbackColors: [GE.primary, GE.primary2],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '@$username',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: GE.sub, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Icon(CupertinoIcons.chevron_right, color: GE.sub, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UpdateRailAction extends StatelessWidget {
  final AppUpdateUiState state;
  final VoidCallback? onTap;

  const _UpdateRailAction({required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final percent = state.progress == null
        ? null
        : (state.progress! * 100).round();
    final label = switch (state.phase) {
      AppUpdatePhase.available => 'Обновить GhostChat',
      AppUpdatePhase.syncing => 'Подготавливаем обновление…',
      AppUpdatePhase.downloading =>
        percent == null
            ? 'Скачиваем обновление…'
            : 'Скачиваем обновление · $percent%',
      AppUpdatePhase.installing => state.message ?? 'Открываем установщик…',
      AppUpdatePhase.readyToInstall => 'Установить GhostChat',
      AppUpdatePhase.failed => 'Повторить обновление',
      AppUpdatePhase.hidden => '',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF10C947), Color(0xFF00B9B5)],
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00B9B5).withValues(alpha: 0.18),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      state.isBusy
                          ? CupertinoIcons.arrow_down_circle_fill
                          : CupertinoIcons.arrow_down_circle,
                      color: Colors.white,
                      size: 19,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (!state.isBusy)
                      const Icon(
                        CupertinoIcons.chevron_right,
                        color: Colors.white70,
                        size: 15,
                      ),
                  ],
                ),
                if (state.isBusy) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: state.progress,
                      minHeight: 4,
                      color: Colors.white,
                      backgroundColor: Colors.white.withValues(alpha: 0.28),
                    ),
                  ),
                ],
                if ((state.phase == AppUpdatePhase.failed ||
                        state.phase == AppUpdatePhase.readyToInstall) &&
                    state.message != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    state.message!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  final Section section;
  final bool active;
  final VoidCallback onTap;
  const _RailItem(this.section, this.active, this.onTap);
  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: active
              ? GE.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(GE.radiusSm),
          // Контур активной вкладки — только в "Классическом", минимализм
          // отличает её одной заливкой.
          border: (active && !ThemeService.isMinimal)
              ? Border.all(color: GE.primary.withValues(alpha: 0.30))
              : null,
        ),
        child: Row(
          children: [
            Icon(
              active ? section.iconFilled : section.iconOutline,
              size: 18,
              color: active ? GE.primary : GE.sub,
            ),
            const SizedBox(width: 12),
            Text(
              section.label,
              style: TextStyle(
                color: active ? GE.text : GE.sub,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Гостевой режим: нет аккаунта — только выход/регистрация ────────────
class _GuestPane extends StatelessWidget {
  final VoidCallback onExit;
  final VoidCallback onRegister;
  const _GuestPane({required this.onExit, required this.onRegister});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: SingleChildScrollView(
        // Bottom-nav лежит поверх контента в Stack. Запас снизу оставляет
        // последнюю кнопку полностью доступной и не создаёт впечатления,
        // будто сама панель «уехала» вверх из-за конца высоты экрана.
        padding: EdgeInsets.only(
          bottom: 132 + MediaQuery.of(context).padding.bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlassCard(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: [GE.sub, GE.muted]),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      CupertinoIcons.person,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Гость',
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Без аккаунта — только LAN-чаты',
                          style: TextStyle(color: GE.sub, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // «Настройки» — теперь отдельный таб в bottom-nav, не строка тут.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Сервер вообще не используется — сообщения ходят напрямую между '
                'устройствами поблизости (LAN/BLE/Wi-Fi Direct).',
                textAlign: TextAlign.center,
                style: TextStyle(color: GE.sub, fontSize: 12, height: 1.4),
              ),
            ),
            const SizedBox(height: 16),
            // Та же стеклянная подложка, что теперь и под "Выйти из аккаунта"
            // в Настройках — иначе кнопки просто висят голыми на mesh.
            GlassCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  GlassButton(
                    label: 'Зарегистрироваться',
                    icon: CupertinoIcons.person_add,
                    primary: true,
                    fullWidth: true,
                    onTap: onRegister,
                  ),
                  const SizedBox(height: 10),
                  GlassButton(
                    label: 'Выйти из гостевого режима',
                    icon: CupertinoIcons.square_arrow_right,
                    danger: true,
                    fullWidth: true,
                    onTap: onExit,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
