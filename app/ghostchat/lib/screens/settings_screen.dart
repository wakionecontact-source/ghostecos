// Настройки — хаб по отделам (как в 1.19.3): список разделов, каждый открывает
// свой экран. Разделы: Внешний вид, Разрешения, Ключи (E2E), Устройства,
// LAN-чаты, Логи, О приложении. «Избранное» сюда специально не входит —
// оно теперь живёт в списке чатов (см. BookmarkStore/chat_list_screen.dart).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../services/chat_repo.dart';
import '../services/theme_service.dart';
import '../services/permissions_service.dart';
import '../widgets/glass.dart';
import '../widgets/skeleton.dart';
import '../widgets/toast_overlay.dart';
import '../widgets/dotted_border_box.dart';
import 'devices_screen.dart';
import 'support_screen.dart';
import 'logs_screen.dart';
import 'lan_settings_screen.dart';
import 'custom_theme_screen.dart';

// ─── Хаб ────────────────────────────────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  final bool isGuest;
  /// true — экран сидит как таб в bottom-nav (MainShell), не запушен через
  /// Navigator: тогда "назад" в шапке не нужен (попадёт в корневой Navigator
  /// и уведёт из MainShell вообще, а не просто закроет вкладку).
  final bool embedded;
  /// Раньше кнопка "Выйти из аккаунта" жила в мини-профиле (_ProfilePane) —
  /// после переезда таба "Профиль" на полноценный ProfileScreen (без логаута,
  /// как у чужих профилей) выход переехал сюда, как в большинстве апп.
  final VoidCallback? onLogout;
  const SettingsScreen({super.key, this.isGuest = false, this.embedded = false, this.onLogout});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    ThemeService.instance.notifier.addListener(_onTheme);
  }

  @override
  void dispose() {
    ThemeService.instance.notifier.removeListener(_onTheme);
    super.dispose();
  }

  void _onTheme() {
    if (mounted) setState(() {});
  }

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: !widget.embedded, titleText: 'Настройки'),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  _row(Icons.palette_outlined, 'Внешний вид', 'Тема оформления',
                      () => _open(const _AppearanceScreen())),
                  _row(Icons.verified_user_outlined, 'Разрешения',
                      'Доступ к камере, микрофону, уведомлениям',
                      () => _open(const _PermissionsManageScreen())),
                  _row(Icons.vpn_key_outlined, 'Ключи шифрования',
                      'Бэкап, seed-фраза, перезалить ключ',
                      () => _open(const _KeysScreen())),
                  _row(Icons.devices_other_outlined, 'Устройства',
                      'Сессии и доверенные устройства',
                      () => _open(const DevicesScreen()),
                      disabled: widget.isGuest),
                  _row(Icons.wifi_tethering_rounded, 'LAN-чаты',
                      'Приём запросов, приоритет, блокировки',
                      () => _open(const LanSettingsScreen())),
                  _row(Icons.terminal_rounded, 'Логи',
                      'Внутренний журнал (LAN/BLE/Wi-Fi Direct)',
                      () => _open(const LogsScreen())),
                  _row(Icons.download_outlined, 'Импортировать чаты',
                      'Скоро',
                      () => toast.show('Импорт чатов — скоро')),
                  _row(Icons.upload_outlined, 'Экспортировать чаты',
                      'Скоро',
                      () => toast.show('Экспорт чатов — скоро')),
                  _row(Icons.info_outline, 'О приложении', 'Версия, помощь',
                      () => _open(const _AboutScreen()), last: true),
                ],
              ),
            ),
            if (widget.onLogout != null) ...[
              const SizedBox(height: 16),
              // Стеклянная карточка вокруг кнопки выхода — раньше кнопка лежала
              // прямо на mesh без подложки, из-за чего низ экрана выглядел
              // "оборванным" (тот же приём, что и в нижнем навбаре MainShell).
              GlassCard(
                padding: const EdgeInsets.all(12),
                child: GlassButton(
                  label: 'Выйти из аккаунта',
                  icon: Icons.logout,
                  danger: true,
                  fullWidth: true,
                  onTap: () => _confirmLogout(context),
                ),
              ),
            ],
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
    if (ok == true) widget.onLogout?.call();
  }

  /// disabled=true — видно, но неактивно (не убираем совсем): для гостя
  /// разделы, требующие сервер (например "Устройства").
  Widget _row(IconData icon, String title, String sub, VoidCallback onTap,
      {bool last = false, bool disabled = false}) {
    final iconColor = disabled ? GE.sub.withValues(alpha: 0.4) : GE.primary;
    final textColor = disabled ? GE.sub.withValues(alpha: 0.5) : GE.text;
    return Column(
      children: [
        InkWell(
          onTap: disabled ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              color: textColor,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(disabled ? 'Недоступно гостю' : sub,
                          style: TextStyle(color: GE.sub.withValues(alpha: disabled ? 0.6 : 1), fontSize: 11)),
                    ],
                  ),
                ),
                if (!disabled) Icon(Icons.chevron_right, color: GE.sub, size: 20),
              ],
            ),
          ),
        ),
        if (!last) Divider(height: 1, color: GE.glassBorder, indent: 48),
      ],
    );
  }
}

// ─── Helper: каркас раздела ───────────────────────────────────────────────────
class _SectionScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  const _SectionScaffold({
    required this.title,
    required this.children,
    this.actions,
  });
  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: true, titleText: title, actions: actions),
        body: ListView(padding: const EdgeInsets.all(12), children: children),
      ),
    );
  }
}

Widget _sectionTitle(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      child: Text(t.toUpperCase(),
          style: TextStyle(
              color: GE.sub,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5)),
    );

/// onTap=null → чисто информационная строка: без риппла и без шеврона (не
/// обещает взаимодействие, на которое нет реакции). trailingIcon переопределяет
/// шеврон (например на "скопировать" или "внешняя ссылка").
Widget _tile(IconData icon, String label, VoidCallback? onTap,
    {String? sub, bool danger = false, IconData? trailingIcon}) {
  final color = danger ? GE.red : GE.primary;
  final textColor = danger ? GE.red : GE.text;
  final content = Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    child: Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: textColor, fontSize: 14)),
              if (sub != null) ...[
                const SizedBox(height: 2),
                Text(sub, style: TextStyle(color: GE.sub, fontSize: 11)),
              ],
            ],
          ),
        ),
        if (onTap != null) Icon(trailingIcon ?? Icons.chevron_right, color: GE.sub, size: 20),
      ],
    ),
  );
  if (onTap == null) return content;
  return InkWell(onTap: onTap, child: content);
}

// ─── Раздел: Внешний вид ──────────────────────────────────────────────────────
class _AppearanceScreen extends StatefulWidget {
  const _AppearanceScreen();
  @override
  State<_AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends State<_AppearanceScreen> {
  @override
  void initState() {
    super.initState();
    ThemeService.instance.notifier.addListener(_onTheme);
    // Скругление живёт в отдельном notifier (не дублирует palette-рёбилды) —
    // без этой подписки карточки тем на этом экране не подхватывают новый
    // радиус, пока слайдер двигают (только его собственный превью-кружок).
    ThemeService.instance.cornerNotifier.addListener(_onTheme);
    // Свои темы — отдельный список, создание/переименование/удаление не
    // трогает notifier (активная тема может и не меняться), без этой
    // подписки сетка тем не подхватит новый черновик/удаление.
    ThemeService.instance.customPresetsNotifier.addListener(_onTheme);
  }

  @override
  void dispose() {
    ThemeService.instance.notifier.removeListener(_onTheme);
    ThemeService.instance.cornerNotifier.removeListener(_onTheme);
    ThemeService.instance.customPresetsNotifier.removeListener(_onTheme);
    super.dispose();
  }

  void _onTheme() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return _SectionScaffold(
      title: 'Внешний вид',
      children: [
        _sectionTitle('Стиль'),
        // Без const: иначе Dart канонизирует виджет в единственный экземпляр,
        // и при ребилде экрана (напр. смена скругления) Flutter видит
        // identical-виджет и пропускает build() — стиль обновляется только
        // сам по себе (через styleNotifier), а не вместе с остальным экраном.
        _StyleSwitcher(),
        const SizedBox(height: 20),
        _sectionTitle('Тема'),
        _ThemeGrid(),
        const SizedBox(height: 20),
        _sectionTitle('Скругление'),
        _CornerRadiusSlider(), // без const — та же ловушка identical-виджета
        const SizedBox(height: 20),
        _sectionTitle('Mesh-фон'),
        _MeshToggleRow(), // без const — см. комментарий у _StyleSwitcher выше
      ],
    );
  }
}

/// Переключатель «Сияющий / Минимализм» — независимая от палитры ось стиля
/// отрисовки (см. ThemeStyle в theme_service.dart). Смена стиля сама
/// подбирает подходящего «близнеца» текущей палитры (ThemeService.setStyle),
/// поэтому здесь только два сегмента, без привязки к конкретной теме.
class _StyleSwitcher extends StatelessWidget {
  const _StyleSwitcher();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeStyle>(
      valueListenable: ThemeService.instance.styleNotifier,
      builder: (context, style, _) {
        final flat = ThemeService.isMinimal;
        Widget segment(String label, ThemeStyle value) {
          final active = style == value;
          return Expanded(
            child: GestureDetector(
              onTap: () => ThemeService.instance.setStyle(value),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active
                      ? GE.primary.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(GE.radiusSm),
                  // Контур — только в "Классическом": минимализм отличает
                  // активный сегмент одной лишь заливкой, без обводки.
                  border: flat
                      ? null
                      : (active
                            ? Border.all(color: GE.primary, width: 1.5)
                            : Border.all(color: Colors.transparent, width: 1.5)),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: active ? GE.primary : GE.sub,
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        }

        return GlassCard(
          padding: const EdgeInsets.all(6),
          child: Row(
            children: [
              segment('Классический', ThemeStyle.vivid),
              const SizedBox(width: 6),
              segment('Минимализм', ThemeStyle.minimal),
            ],
          ),
        );
      },
    );
  }
}

/// Вкл/выкл анимированный mesh-фон (точки+линии+свечение). Меш остаётся
/// фирменным дефолтом — тумблер только даёт возможность отключить его
/// ради минимализма, не меняя остальную палитру/тему.
class _MeshToggleRow extends StatelessWidget {
  const _MeshToggleRow();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeService.instance.meshNotifier,
      builder: (context, enabled, _) {
        return GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Анимированный фон',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Точки, линии и свечение позади экранов',
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                  ],
                ),
              ),
              GhostSwitch(
                value: enabled,
                activeColor: GE.primary,
                onChanged: (v) => ThemeService.instance.setMeshEnabled(v),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Раздел: Разрешения ───────────────────────────────────────────────────────
class _PermissionsManageScreen extends StatefulWidget {
  const _PermissionsManageScreen();
  @override
  State<_PermissionsManageScreen> createState() =>
      _PermissionsManageScreenState();
}

class _PermissionsManageScreenState extends State<_PermissionsManageScreen>
    with WidgetsBindingObserver {
  Map<Permission, PermissionStatus> _st = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final s = await checkAllPermissions();
    if (!mounted) return;
    setState(() {
      _st = s;
      _loading = false;
    });
  }

  Future<void> _toggle(Permission p, bool granted) async {
    if (granted) {
      await openAppSettings(); // отозвать можно только в системных настройках
    } else {
      final st = await p.status;
      if (st.isPermanentlyDenied) {
        await openAppSettings();
      } else {
        await p.request();
      }
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return _SectionScaffold(
      title: 'Разрешения',
      actions: [
        IconButton(
          icon: Icon(Icons.settings_outlined, color: GE.sub),
          tooltip: 'Настройки приложения',
          onPressed: openAppSettings,
        ),
      ],
      children: _loading
          ? [
              const SizedBox(height: 8),
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: const SkeletonRowList(count: 4, avatarSize: 28),
              ),
            ]
          : [
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (final p in appPermissions)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        child: Row(
                          children: [
                            Icon(permIcon(p), size: 20, color: GE.primary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(permLabel(p),
                                      style: TextStyle(
                                          color: GE.text, fontSize: 14)),
                                  Text(
                                    (_st[p]?.isGranted ?? false)
                                        ? 'Разрешено'
                                        : 'Нет доступа',
                                    style: TextStyle(
                                        color: (_st[p]?.isGranted ?? false)
                                            ? GE.green
                                            : GE.sub,
                                        fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            GhostSwitch(
                              value: _st[p]?.isGranted ?? false,
                              activeColor: GE.primary,
                              onChanged: (v) =>
                                  _toggle(p, _st[p]?.isGranted ?? false),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Отозвать выданное разрешение можно только в системных '
                  'настройках — переключатель откроет их.',
                  style: TextStyle(color: GE.sub, fontSize: 11, height: 1.4),
                ),
              ),
            ],
    );
  }
}

// ─── Раздел: Ключи шифрования ─────────────────────────────────────────────────
class _KeysScreen extends StatelessWidget {
  const _KeysScreen();

  void _toast(String m) => toast.show(m);

  Future<void> _cloudBackup(BuildContext context) async {
    final pwd = await _askPassword(context);
    if (pwd == null || pwd.isEmpty) return;
    _toast('Включаю облачный бэкап…');
    final r = await ChatRepo.instance
        .retryKeySync(chosenMode: 'server', password: pwd);
    _toast(r == KeySyncOutcome.ok
        ? 'Облачный бэкап включён — ключ переживёт переустановку'
        : 'Не вышло (проверь пароль)');
  }

  Future<String?> _askPassword(BuildContext context) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Пароль аккаунта', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          style: TextStyle(color: GE.text),
          decoration: InputDecoration(
            hintText: 'Пароль',
            hintStyle: TextStyle(color: GE.sub),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d),
              child: Text('Отмена', style: TextStyle(color: GE.sub))),
          TextButton(
              onPressed: () => Navigator.pop(d, ctrl.text),
              child: const Text('Включить')),
        ],
      ),
    );
  }

  Future<void> _forcePublish() async {
    _toast('Заливаю ключ на сервер…');
    _toast(await ChatRepo.instance.forcePublishMyPubKey());
  }

  Future<void> _showSeed(BuildContext context) async {
    final m = await ChatRepo.instance.v2Mnemonic();
    if (!context.mounted) return;
    if (m == null || m.trim().isEmpty) {
      _toast('Seed ещё не создан (v2 не инициализирован)');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Seed-фраза v2', style: TextStyle(color: GE.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '12 слов — бэкап v2-личности и привязка других устройств. Никому '
              'не показывай.',
              style: TextStyle(color: GE.sub, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: GE.bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: GE.glassBorder),
              ),
              child: SelectableText(m,
                  style: TextStyle(
                      color: GE.text,
                      fontSize: 15,
                      height: 1.6,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: m));
              _toast('Скопировано');
            },
            child: const Text('Копировать'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('Закрыть')),
        ],
      ),
    );
  }

  Future<void> _confirmRegenerate(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title:
            Text('Перегенерировать ключ?', style: TextStyle(color: GE.text)),
        content: Text(
          'Будет создан новый приватный ключ. Все ранее присланные сообщения, '
          'зашифрованные старым ключом, СТАНУТ нечитаемыми. Только если ничего '
          'не помогает.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text('Перегенерировать', style: TextStyle(color: GE.red))),
        ],
      ),
    );
    if (ok != true) return;
    _toast('Генерирую новый ключ…');
    _toast(await ChatRepo.instance.regenerateKeys());
  }

  @override
  Widget build(BuildContext context) {
    return _SectionScaffold(
      title: 'Ключи шифрования',
      children: [
        _sectionTitle('Резервная копия'),
        GlassCard(
          child: Column(
            children: [
              _tile(Icons.cloud_upload_outlined, 'Включить облачный бэкап ключа',
                  () => _cloudBackup(context),
                  sub:
                      'Ключ под твоим паролем — на сервере. Переживёт переустановку'),
              _tile(Icons.vpn_key_outlined, 'Seed-фраза v2 (12 слов)',
                  () => _showSeed(context),
                  sub: 'Бэкап v2-личности + привязка веба/других устройств'),
            ],
          ),
        ),
        _sectionTitle('Обслуживание'),
        GlassCard(
          child: Column(
            children: [
              _tile(Icons.upload_outlined, 'Перезалить мой ключ на сервер',
                  _forcePublish,
                  sub: 'Если пиры пишут «не удалось расшифровать»'),
              _tile(Icons.refresh, 'Перегенерировать E2E-пару',
                  () => _confirmRegenerate(context),
                  sub: 'NUCLEAR: новый приват, старую переписку не расшифровать',
                  danger: true),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Раздел: О приложении ─────────────────────────────────────────────────────
class _AboutScreen extends StatefulWidget {
  const _AboutScreen();
  @override
  State<_AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<_AboutScreen> {
  String _version = '…';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = '${info.version}+${info.buildNumber}');
    } catch (_) {
      if (mounted) setState(() => _version = '?');
    }
  }

  Future<void> _openChannel() async {
    final uri = Uri.parse('https://t.me/waki_one');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      toast.show('Не удалось открыть ссылку');
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionScaffold(
      title: 'О приложении',
      children: [
        GlassCard(
          child: Column(
            children: [
              _tile(
                Icons.info_outline,
                'GhostChat · v$_version',
                () {
                  Clipboard.setData(ClipboardData(text: _version));
                  toast.show('Версия скопирована');
                },
                trailingIcon: Icons.copy_outlined,
              ),
              _tile(Icons.emoji_emotions_outlined,
                  'Эмодзи — Twemoji (CC BY 4.0)', null,
                  sub: 'Графика эмодзи © Twitter/jdecked, CC BY 4.0'),
              _tile(
                Icons.telegram,
                'Канал в Telegram',
                _openChannel,
                sub: '@waki_one',
                trailingIcon: Icons.open_in_new,
              ),
              _tile(
                Icons.help_outline,
                'Помощь',
                () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SupportScreen())),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─── Сетка тем ────────────────────────────────────────────────────────────────
class _ThemeGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Только «близнецы» текущего стиля (сияющий/минимализм) — остальные 6
    // скрыты, чтобы не путать плоскую тему с glass-темой одного цвета.
    final presets = ThemeService.instance.presetsForCurrentStyle;
    final current = ThemeService.instance.notifier.value;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.5,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: presets.length + 1,
      itemBuilder: (_, i) {
        // Без const — та же ловушка identical-виджета, что у _StyleSwitcher/
        // _MeshToggleRow: иначе "Новая тема" не подхватывает новый радиус.
        if (i == presets.length) return _CreateThemeCard();
        final p = presets[i];
        final active = p.id == current.id;
        final flat = p.style == ThemeStyle.minimal;
        return InkWell(
          borderRadius: BorderRadius.circular(GE.radiusMd),
          onTap: () => ThemeService.instance.setPreset(p.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [p.bg, p.bgDeep],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(GE.radiusMd),
              // Минимализм: без контура и без свечения — выбранную тему
              // отличает только галочка (см. ниже), не рамка/glow.
              border: flat
                  ? null
                  // p.borderStrong (не хардкод white) — у каждого пресета свой
                  // адаптивный тон, иначе на светлой "Слоновой кости" рамка
                  // неактивной плитки была не видна на её же светлом фоне.
                  : Border.all(
                      color: active ? p.primary : p.borderStrong,
                      width: active ? 2 : 1,
                    ),
              // Тише, чем раньше (0.4/18) — плотное лёгкое свечение вместо
              // неонового ореола.
              boxShadow: (!flat && active)
                  ? [
                      BoxShadow(
                        color: p.primary.withValues(alpha: 0.22),
                        blurRadius: 10,
                      ),
                    ]
                  : null,
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient:
                            LinearGradient(colors: [p.primary, p.primary2]),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 12,
                      height: 12,
                      decoration:
                          BoxDecoration(shape: BoxShape.circle, color: p.green),
                    ),
                    const Spacer(),
                    if (active)
                      Icon(Icons.check_circle, color: p.primary, size: 18),
                  ],
                ),
                const Spacer(),
                Text(p.name.isEmpty ? 'Без названия' : p.name,
                    style: TextStyle(
                        color: p.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
                Text(p.isCustom ? 'Своя тема' : p.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: p.text.withValues(alpha: 0.65), fontSize: 11)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Слайдер глобального скругления углов — от острых (90°) до максимально
/// круглых (45°), метка-градус сидит у самого угла превью-квадрата. Двигает
/// живьём: ThemeService.setCornerFactor триггерит cornerNotifier, все
/// GE.radiusSm/Md/Lg пересчитываются геттерами — эффект виден по всему
/// приложению сразу, не только в этом превью.
class _CornerRadiusSlider extends StatefulWidget {
  const _CornerRadiusSlider();
  @override
  State<_CornerRadiusSlider> createState() => _CornerRadiusSliderState();
}

class _CornerRadiusSliderState extends State<_CornerRadiusSlider> {
  late double _factor = GE.cornerFactor;

  void _onChanged(double v) {
    setState(() => _factor = v);
    ThemeService.instance.setCornerFactor(v);
  }

  @override
  Widget build(BuildContext context) {
    final degrees = (90 - 45 * _factor).round();
    final previewRadius = (10 + 38 * _factor).clamp(0.0, 48.0);
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          SizedBox(
            height: 100,
            child: Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
                      borderRadius: BorderRadius.circular(previewRadius),
                    ),
                  ),
                  Positioned(
                    left: -8,
                    top: -8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: GE.bgDeep,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$degrees°',
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Row(
            children: [
              Text('Острые', style: TextStyle(color: GE.sub, fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _factor,
                  onChanged: _onChanged,
                  activeColor: GE.primary,
                  // Явный inactiveColor — иначе Slider берёт цвет трека из
                  // ColorScheme темы, который на части палитр почти совпадает
                  // с фоном карточки (трек "сливается" при смене темы).
                  inactiveColor: GE.sub.withValues(alpha: 0.35),
                ),
              ),
              Text('Круглые', style: TextStyle(color: GE.sub, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Заглушка "своя тема" — пока не функциональна (только визуальный стаб),
/// нажатие даёт понять, что фича готовится, а не молчит без реакции.
class _CreateThemeCard extends StatelessWidget {
  const _CreateThemeCard();

  Future<void> _create(BuildContext context) async {
    final draft = await ThemeService.instance.createDraftCustomTheme();
    if (draft == null) {
      toast.show('Своих тем уже 100 — сначала удалите ненужные');
      return;
    }
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CustomThemeScreen(themeId: draft.id),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(GE.radiusMd),
      onTap: () => _create(context),
      child: DottedBorderBox(
        radius: GE.radiusMd,
        color: GE.sub.withValues(alpha: 0.4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, color: GE.sub, size: 26),
            const SizedBox(height: 6),
            Text('Новая тема',
                style: TextStyle(
                    color: GE.sub, fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
