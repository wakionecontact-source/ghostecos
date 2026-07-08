// Экран разрешений — показывается ОДИН раз, сразу после велкома.
//
// Запрос идёт ТОЛЬКО по кнопке «Запросить разрешения». «Пропустить» → идём
// дальше без запроса; нужные разрешения попросятся лениво при действии
// (см. ensurePermission в services/permissions_service.dart).
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../services/permissions_service.dart';

class PermissionsScreen extends StatefulWidget {
  final VoidCallback onDone;
  const PermissionsScreen({super.key, required this.onDone});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  bool _requesting = false;
  bool _requested = false;
  Map<Permission, PermissionStatus> _statuses = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Вернулись из системных настроек — перепроверим.
    if (state == AppLifecycleState.resumed && _requested) _check();
  }

  Future<void> _check() async {
    final st = await checkAllPermissions();
    if (!mounted) return;
    setState(() => _statuses = st);
    if (_requested && _allGranted) _proceed();
  }

  Future<void> _doRequest() async {
    setState(() => _requesting = true);
    final st = await requestAllPermissions();
    if (!mounted) return;
    setState(() {
      _statuses = st;
      _requesting = false;
      _requested = true;
    });
    if (_allGranted) _proceed();
  }

  Future<void> _retryDenied() async {
    setState(() => _requesting = true);
    for (final p in _denied) {
      if ((await p.status).isPermanentlyDenied) {
        await openAppSettings();
        break;
      }
      await p.request();
    }
    final st = await checkAllPermissions();
    if (!mounted) return;
    setState(() {
      _statuses = st;
      _requesting = false;
    });
    if (_allGranted) _proceed();
  }

  bool get _allGranted =>
      _statuses.isNotEmpty &&
      _statuses.values.every((s) => s.isGranted || s.isLimited);

  List<Permission> get _denied => _statuses.entries
      .where((e) => !e.value.isGranted && !e.value.isLimited)
      .map((e) => e.key)
      .toList();

  Future<void> _proceed() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('permissions_done', true);
    if (!mounted) return;
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: _requesting
              ? _loadingView()
              : (_requested && !_allGranted ? _resultView() : _introView()),
        ),
      ),
    );
  }

  Widget _introView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 24),
          Icon(Icons.verified_user_outlined, size: 56, color: GE.primary),
          const SizedBox(height: 16),
          Text(
            'Разрешения',
            style: TextStyle(
              color: GE.text,
              fontSize: 26,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Чтобы всё работало как надо, приложению нужен доступ. Можно дать '
            'сейчас или пропустить — тогда спросим, когда понадобится.',
            textAlign: TextAlign.center,
            style: TextStyle(color: GE.sub, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: appPermissions.length,
                separatorBuilder: (_, __) =>
                    Divider(height: 1, color: GE.glassBorder, indent: 60),
                itemBuilder: (_, i) {
                  final p = appPermissions[i];
                  return ListTile(
                    leading: Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: GE.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(permIcon(p), color: GE.primary, size: 20),
                    ),
                    title: Text(
                      permLabel(p),
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      permDesc(p),
                      style: TextStyle(
                        color: GE.sub,
                        fontSize: 11.5,
                        height: 1.3,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          GlassButton(
            label: 'Запросить разрешения',
            icon: Icons.check_circle_outline,
            primary: true,
            fullWidth: true,
            onTap: _doRequest,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _proceed,
            child: Text(
              'Пропустить',
              style: TextStyle(color: GE.sub, fontSize: 14),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _loadingView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.verified_user_outlined, size: 56, color: GE.primary),
          const SizedBox(height: 20),
          Text(
            'Запрашиваю разрешения…',
            style: TextStyle(
              color: GE.text,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2, color: GE.primary),
          ),
        ],
      ),
    );
  }

  Widget _resultView() {
    final denied = _denied;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          const SizedBox(height: 28),
          Icon(Icons.warning_amber_rounded, size: 56, color: GE.yellow),
          const SizedBox(height: 16),
          Text(
            'Выданы не все',
            style: TextStyle(
              color: GE.text,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Без них часть функций не сработает. Можно выдать позже — приложение '
            'само попросит, когда понадобится.',
            textAlign: TextAlign.center,
            style: TextStyle(color: GE.sub, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: denied.length,
                separatorBuilder: (_, __) =>
                    Divider(height: 1, color: GE.glassBorder, indent: 52),
                itemBuilder: (_, i) {
                  final p = denied[i];
                  return ListTile(
                    dense: true,
                    leading: Icon(permIcon(p), color: GE.red, size: 20),
                    title: Text(
                      permLabel(p),
                      style: TextStyle(color: GE.text, fontSize: 14),
                    ),
                    trailing: Text(
                      'нет',
                      style: TextStyle(color: GE.red, fontSize: 12),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          GlassButton(
            label: 'Дать разрешения',
            icon: Icons.check_circle_outline,
            primary: true,
            fullWidth: true,
            onTap: _retryDenied,
          ),
          const SizedBox(height: 10),
          GlassButton(
            label: 'Продолжить',
            fullWidth: true,
            onTap: _proceed,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
