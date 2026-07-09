// MainShell — главный экран после логина.
// Mobile: BottomNavigationBar снизу.
// Desktop: NavigationRail слева, контент справа.
// 4 таба: Чат / Лента / Банк / Профиль.
//
// Каждый экран — native, без WebView. Заглушки пока (M5-M7 их наполнят).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../services/auth_service.dart';
import '../services/db_service.dart';
import '../services/crypto_service.dart';
import '../services/ws_client.dart';
import '../services/notification_service.dart';
import '../services/foreground_service.dart';
import '../services/fcm_service.dart';
import '../services/lan_chat_store.dart';
import '../services/bookmark_store.dart';
import '../services/crypto_v2.dart';
import '../widgets/glass.dart';
import '../widgets/skeleton.dart';
import '../widgets/toast_overlay.dart';
import 'settings_screen.dart';
import 'chat_list_screen.dart';
import 'lan_scan_screen.dart';
import '../core/local/local_hub.dart';
import '../core/local/local_transport.dart';
import '../core/local/lan_settings.dart';
import '../core/local/app_logger.dart';
import '../core/local/transports/lan_transport.dart';
import '../core/local/transports/bluetooth_transport.dart';
import '../core/local/transports/wifi_direct_transport.dart';

enum Section {
  chat(
    label: 'Чаты',
    iconOutline: Icons.chat_bubble_outline,
    iconFilled: Icons.chat_bubble,
  ),
  profile(
    label: 'Профиль',
    iconOutline: Icons.person_outline,
    iconFilled: Icons.person,
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
  const MainShell({super.key, required this.onLoggedOut});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  Section _section = Section.chat;
  bool _bootstrapped = false;
  bool _isGuest = false;
  String? _username;
  String? _displayName;
  String? _error;
  StreamSubscription? _lanMsgSub;
  StreamSubscription? _lanCollectingSub;
  StreamSubscription? _lanAcceptSub;

  @override
  void initState() {
    super.initState();
    _bootstrap();
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
        _username = 'Гость';
        _displayName = 'Гость';
        await BookmarkStore.instance.init('guest');
        await _startLan();
        if (mounted) setState(() => _bootstrapped = true);
        return;
      }

      final u = await AuthService.username();
      final dn = await AuthService.displayName();
      if (u == null) throw Exception('Нет username');
      _username = u;
      _displayName = dn ?? u;

      await DbService.instance.init(u);
      await BookmarkStore.instance.init(u);
      await CryptoService.instance.ensureKeys();
      WsClient.instance.connect();
      await _startLan();

      if (mounted) setState(() => _bootstrapped = true);
      // После логина — спросить разрешение на уведомления (если ещё не выдано).
      NotificationService.instance.ensurePermission();
      ForegroundService.instance.start();
      // FCM: зарегистрировать токен на сервере (push, MIUI-устойчиво).
      FcmService.instance.registerToken();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _startLan() async {
    await LanChatStore.instance.init();
    await LanSettings().load();
    await CryptoV2.instance.ensureKeys();

    localHub.registerDefaults([
      LanTransport(),
      WifiDirectTransport(),
      BluetoothTransport(),
    ]);
    _lanMsgSub = localHub.onMessage.listen(_onLanMessage);
    _lanCollectingSub = localHub.onCollecting.listen(_onLanSignalCaught);
    _lanAcceptSub = localHub.onAccept.listen(_onLanAccepted);
    await localHub.startAll();
  }

  /// Кто-то принял наш запрос (или мы приняли его — sendAccept тоже шлёт
  /// себе через localHub) → сохранить чат в LanChatStore СРАЗУ, независимо
  /// от того, открыт ли сейчас экран "Устройства поблизости". Без этого
  /// сторона, которая не смотрела в этот экран в момент прилёта accept-
  /// пакета, никогда не получала запись чата — сообщения приходили, но
  /// showить их было некуда (createOrGetChat ни разу не вызывался).
  Future<void> _onLanAccepted(LocalPeer peer) async {
    final identityOk = await LanChatStore.instance
        .checkAndPinIdentity(peer.deviceId, peer.identityPubB64);
    if (!identityOk) {
      appLog.warn('security', 'Identity ${peer.deviceId} изменилась — отклонено');
      return;
    }
    await LanChatStore.instance.createOrGetChat(
      deviceId: peer.deviceId,
      displayName: peer.label,
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
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const LanScanScreen())),
      ),
    );
  }

  String _shortId(String deviceId) =>
      deviceId.length > 8 ? '${deviceId.substring(0, 8)}…' : deviceId;

  /// Входящее LAN-сообщение → расшифровать (ключ пира взят из БД LAN-чатов,
  /// сохранённый там при подключении) и сохранить в историю. Работает даже
  /// если экран этого чата сейчас не открыт.
  Future<void> _onLanMessage(LocalMessageEvent m) async {
    if (m.encB64.isEmpty) return;
    try {
      final clear = await CryptoV2.instance.decryptForMe(m.encB64);
      if (clear == null) return;
      final text = utf8.decode(clear);
      await LanChatStore.instance.addMessage(
        deviceId: m.fromUsername,
        msgId: m.msgId,
        fromMe: false,
        text: text,
        // sentAt приходит в миллисекундах (см. LocalHub keepalive), а БД
        // хранит секунды — как created_at в DbService.
        createdAtSec: m.sentAt > 0 ? m.sentAt ~/ 1000 : null,
      );
    } catch (_) {}
  }

  Future<void> _logout() async {
    if (!_isGuest) {
      await ForegroundService.instance.stop();
      await WsClient.instance.disconnect();
      await DbService.instance.close();
      await CryptoService.instance.wipe();
    }
    await AuthService.logout();
    widget.onLoggedOut();
  }

  @override
  void dispose() {
    _lanMsgSub?.cancel();
    _lanCollectingSub?.cancel();
    _lanAcceptSub?.cancel();
    localHub.stopAll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold'ы ниже прозрачные и рассчитаны на фон снаружи — как во всех
    // остальных экранах приложения (mesh-сетка), а не плоский градиент.
    return MeshBackground(child: _content(context));
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
                  Icon(Icons.error_outline, size: 48, color: GE.red),
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
      body: isWide ? _wideLayout() : _mobileLayout(),
    );
  }

  // ─── Layout: mobile (≤720) ─────────────────────────────────────────
  Widget _mobileLayout() {
    return Column(
      children: [
        Expanded(child: _sectionBody()),
        _GlassBottomNav(
          current: _section,
          onTap: (s) => setState(() => _section = s),
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
          onTap: (s) => setState(() => _section = s),
          username: _username ?? '?',
          displayName: _displayName ?? _username ?? '?',
          onLogout: _logout,
        ),
        Expanded(child: _sectionBody()),
      ],
    );
  }

  Widget _sectionBody() {
    // Пока заглушки. M5-M7 их наполнят.
    switch (_section) {
      case Section.chat:
        return ChatListScreen(isGuest: _isGuest);
      case Section.profile:
        if (_isGuest) return _GuestPane(onExit: _logout);
        return _ProfilePane(
          username: _username ?? '?',
          displayName: _displayName ?? '?',
          onLogout: _logout,
        );
    }
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

// ── Bottom-nav в glass-стиле (сворачиваемый) ──────────────────────────
class _GlassBottomNav extends StatefulWidget {
  final Section current;
  final ValueChanged<Section> onTap;
  const _GlassBottomNav({required this.current, required this.onTap});

  @override
  State<_GlassBottomNav> createState() => _GlassBottomNavState();
}

class _GlassBottomNavState extends State<_GlassBottomNav> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Стрелка-хэндл: сидит ПРЯМО на верхней границе панели, без чипа-фона.
        // Кликабельная зона широкая (72×22), сам значок — маленький.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _collapsed = !_collapsed),
          child: SizedBox(
            width: 72,
            height: 22,
            child: Center(
              child: AnimatedRotation(
                turns: _collapsed ? 0.5 : 0,
                duration: const Duration(milliseconds: 220),
                child: Icon(
                  Icons.keyboard_arrow_down,
                  size: 20,
                  color: GE.sub.withValues(alpha: 0.65),
                ),
              ),
            ),
          ),
        ),
        // Панель — сворачивается анимацией вниз, остаётся только стрелка.
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _collapsed
              ? SizedBox(width: double.infinity, height: bottomInset)
              : Container(
                  // Чистый лакшери-бар: на всю ширину, тонкий разделитель сверху,
                  // без плавающего стекла.
                  padding: EdgeInsets.only(
                    left: 6,
                    right: 6,
                    top: 6,
                    bottom: 6 + bottomInset,
                  ),
                  decoration: BoxDecoration(
                    // Цвет берём из активной темы (alphaBlend → непрозрачный бар).
                    color: Color.alphaBlend(GE.surface, GE.bg),
                    border: Border(
                      top: BorderSide(color: GE.border, width: 0.6),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [for (final s in Section.values) _navItem(s)],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _navItem(Section s) {
    final active = s == widget.current;
    // Без визуального фона у пункта — только иконка+подпись. Подсветка = акцент.
    return Expanded(
      child: InkWell(
        onTap: () => widget.onTap(s),
        splashColor: GE.primary.withValues(alpha: 0.10),
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active ? s.iconFilled : s.iconOutline,
                size: 24,
                color: active ? GE.primary : GE.sub,
              ),
              const SizedBox(height: 3),
              Text(
                s.label,
                style: TextStyle(
                  color: active ? GE.primary : GE.sub,
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
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
          Divider(color: GE.glassBorder, height: 1),
          // Профиль пользователя — тап ведёт во вкладку «Профиль» (НЕ выход;
          // выход — внутри профиля, с подтверждением). Подсвечивается активным.
          InkWell(
            onTap: () => onTap(Section.profile),
            child: Container(
              color: current == Section.profile
                  ? GE.primary.withValues(alpha: 0.12)
                  : null,
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [GE.primary, GE.primary2],
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      displayName.isNotEmpty
                          ? displayName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
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
                  Icon(Icons.chevron_right, color: GE.sub, size: 18),
                ],
              ),
            ),
          ),
        ],
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
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: active
              ? GE.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(GE.radiusSm),
          border: active
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
  const _GuestPane({required this.onExit});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
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
                    child: Icon(Icons.person_outline, color: Colors.white, size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Гость',
                            style: TextStyle(color: GE.text, fontSize: 18, fontWeight: FontWeight.w700)),
                        Text('Без аккаунта — только LAN-чаты',
                            style: TextStyle(color: GE.sub, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _profileRow(
                Icons.settings_outlined,
                'Настройки',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ),
            const SizedBox(height: 16),
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
            GlassButton(
              label: 'Выйти из гостевого режима',
              icon: Icons.logout,
              danger: true,
              fullWidth: true,
              onTap: onExit,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── Профиль (минимальный — будет наполняться в M5+) ───────────────────
class _ProfilePane extends StatelessWidget {
  final String username, displayName;
  final VoidCallback onLogout;
  const _ProfilePane({
    required this.username,
    required this.displayName,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: SingleChildScrollView(
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
                      gradient: LinearGradient(
                        colors: [GE.primary, GE.primary2],
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      displayName.isNotEmpty
                          ? displayName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '@$username',
                          style: TextStyle(color: GE.sub, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  _profileRow(
                    Icons.settings_outlined,
                    'Настройки',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GlassButton(
              label: 'Выйти из аккаунта',
              icon: Icons.logout,
              danger: true,
              fullWidth: true,
              onTap: () => _confirmLogout(context),
            ),
            const SizedBox(height: 24),
            Center(
              child: Text(
                '${GE.appName} · v1.1.10 · ${Platform.operatingSystem}',
                style: TextStyle(color: GE.muted, fontSize: 11),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Выйти из аккаунта?', style: TextStyle(color: GE.text)),
        content: Text(
          'Сессия на этом устройстве завершится. Войти снова — по логину/паролю или ключу.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Выйти', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (ok == true) onLogout();
  }

}

Widget _profileRow(IconData icon, String label, {VoidCallback? onTap}) {
  return InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 18, color: GE.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: GE.text,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Icon(Icons.chevron_right, color: GE.sub, size: 18),
        ],
      ),
    ),
  );
}
