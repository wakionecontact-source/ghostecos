// MainShell — главный экран после логина.
// Mobile: BottomNavigationBar снизу.
// Desktop: NavigationRail слева, контент справа.
// 4 таба: Чат / Лента / Банк / Профиль.
//
// Каждый экран — native, без WebView. Заглушки пока (M5-M7 их наполнят).

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../services/auth_service.dart';
import '../services/db_service.dart';
import '../services/crypto_service.dart';
import '../services/ws_client.dart';
import '../widgets/glass.dart';
import 'settings_screen.dart';
import 'chat_list_screen.dart';
import 'devices_screen.dart';
import 'feed_screen.dart';
import 'profile_screen.dart';
import 'social_pane.dart';
import 'wallet_screen.dart';
import 'wrapped_screen.dart';

enum Section {
  chat(
    label: 'Чаты',
    iconOutline: Icons.chat_bubble_outline,
    iconFilled: Icons.chat_bubble,
  ),
  feed(
    label: 'Лента',
    iconOutline: Icons.dynamic_feed_outlined,
    iconFilled: Icons.dynamic_feed,
  ),
  bank(
    label: 'Банк',
    iconOutline: Icons.account_balance_wallet_outlined,
    iconFilled: Icons.account_balance_wallet,
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
  String? _username;
  String? _displayName;
  String? _error;

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
  Future<void> _bootstrap() async {
    try {
      final u = await AuthService.username();
      final dn = await AuthService.displayName();
      if (u == null) throw Exception('Нет username');
      _username = u;
      _displayName = dn ?? u;

      await DbService.instance.init(u);
      await CryptoService.instance.ensureKeys();
      WsClient.instance.connect();

      if (mounted) setState(() => _bootstrapped = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _logout() async {
    await WsClient.instance.disconnect();
    await DbService.instance.close();
    await CryptoService.instance.wipe();
    await AuthService.logout();
    widget.onLoggedOut();
  }

  @override
  Widget build(BuildContext context) {
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
        body: Center(child: CircularProgressIndicator(color: GE.primary)),
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
        return const ChatListScreen();
      case Section.feed:
        return const SocialPane();
      case Section.bank:
        return const WalletScreen();
      case Section.profile:
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
        // Стрелка-хэндл: сворачивает/разворачивает панель.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _collapsed = !_collapsed),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            alignment: Alignment.center,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
              decoration: BoxDecoration(
                color: GE.glassFill,
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: GE.glassBorder),
              ),
              child: AnimatedRotation(
                turns: _collapsed ? 0.5 : 0,
                duration: const Duration(milliseconds: 220),
                child: Icon(Icons.keyboard_arrow_down, size: 18, color: GE.sub),
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
              : GlassCard(
                  padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + bottomInset),
                  radius: 0,
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
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(GE.radiusSm),
        onTap: () => widget.onTap(s),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active ? s.iconFilled : s.iconOutline,
                size: 22,
                color: active ? GE.primary : GE.sub,
              ),
              const SizedBox(height: 4),
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
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ProfileScreen(username: username),
                ),
              ),
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
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.person_outline,
                              size: 12,
                              color: GE.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Открыть полный профиль',
                              style: TextStyle(
                                color: GE.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: GE.sub),
                ],
              ),
            ),
            const SizedBox(height: 16),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  // Доступные разделы.
                  _profileRow(
                    Icons.devices_outlined,
                    'Мои устройства',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DevicesScreen()),
                    ),
                  ),
                  _profileRow(
                    Icons.auto_awesome_outlined,
                    'Wrapped — мой год',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => WrappedScreen(username: username),
                      ),
                    ),
                  ),
                  // Настройки / темы / безопасность временно отключены —
                  // экран SettingsScreen сохранён в коде, см. settings_screen.dart.
                  _profileRow(
                    Icons.settings_outlined,
                    'Настройки',
                    onTap: () => _todo(context, 'Настройки в разработке'),
                  ),
                  _profileRow(
                    Icons.palette_outlined,
                    'Темы интерфейса',
                    onTap: () => _todo(context, 'Темы в разработке'),
                  ),
                  _profileRow(
                    Icons.shield_outlined,
                    'Безопасность',
                    onTap: () => _todo(context, 'Безопасность в разработке'),
                  ),
                  _profileRow(
                    Icons.terminal_outlined,
                    'Логи',
                    onTap: () => _todo(context, 'Просмотрщик логов в M8'),
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
                '${GE.appName} · v0.2.0 · ${Platform.operatingSystem}',
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

  void _todo(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }
}
