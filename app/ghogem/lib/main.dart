import 'dart:async';
import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'theme.dart';
import 'services/settings_service.dart';
import 'services/auth_service.dart';
import 'screens/home_screen.dart';
import 'screens/welcome_screen.dart';
import 'screens/auth_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService.instance.init();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: const Size(1180, 760),
        minimumSize: const Size(380, 600),
        backgroundColor: GG.bg,
        titleBarStyle: TitleBarStyle.normal,
        title: GG.appName,
      ),
      () async { await windowManager.show(); await windowManager.focus(); },
    );
  }
  if (Platform.isWindows) {
    unawaited(_registerWindowsProtocol());
  }
  runApp(const GhostGemApp());
}

/// Регистрирует схему ghogem:// в HKCU (без прав админа),
/// чтобы браузер мог вернуть пользователя в приложение с данными.
Future<void> _registerWindowsProtocol() async {
  try {
    final exe = Platform.resolvedExecutable;
    const base = r'HKCU\Software\Classes\ghogem';
    await Process.run('reg', ['add', base, '/ve', '/d', 'URL:GhostGem', '/f']);
    await Process.run('reg', ['add', base, '/v', 'URL Protocol', '/d', '', '/f']);
    await Process.run('reg', [
      'add', '$base\\shell\\open\\command', '/ve', '/d', '"$exe" "%1"', '/f',
    ]);
  } catch (_) {}
}

class GhostGemApp extends StatelessWidget {
  const GhostGemApp({super.key});
  @override Widget build(BuildContext context) {
    return MaterialApp(
      title: GG.appName,
      debugShowCheckedModeBanner: false,
      theme: GG.theme(),
      home: const _Root(),
    );
  }
}

enum _Stage { loading, welcome, auth, app }

class _Root extends StatefulWidget {
  const _Root();
  @override State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with WidgetsBindingObserver {
  _Stage _stage = _Stage.loading;
  StreamSubscription<Uri>? _linkSub;
  bool _handlingLink = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resolve();
    _listenLinks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Второй процесс (запущенный браузером по ghogem://) мог сохранить
    // сессию в общие префы — подхватываем её при возврате фокуса.
    if (state == AppLifecycleState.resumed && _stage == _Stage.auth) {
      AuthService.instance.refreshSession().then((ok) {
        if (ok && mounted) setState(() => _stage = _Stage.app);
      });
    }
  }

  Future<void> _resolve() async {
    final prefs = await SharedPreferences.getInstance();
    final welcomeDone = prefs.getBool('gg_welcome_done') ?? false;
    final hasSession = await AuthService.instance.hasSession();
    if (!mounted) return;
    setState(() {
      if (!welcomeDone) {
        _stage = _Stage.welcome;
      } else if (!hasSession) {
        _stage = _Stage.auth;
      } else {
        _stage = _Stage.app;
      }
    });
  }

  void _listenLinks() {
    final links = AppLinks();
    _linkSub = links.uriLinkStream.listen(_handleLink, onError: (_) {});
    links.getInitialLink().then((uri) {
      if (uri != null) _handleLink(uri);
    }).catchError((_) {});
  }

  Future<void> _handleLink(Uri uri) async {
    // ghogem://auth?token=...&username=... — возврат с сайта с данными.
    if (_handlingLink) return;
    if (uri.scheme != 'ghogem' || uri.host != 'auth') return;
    final token = uri.queryParameters['token'] ?? '';
    if (token.isEmpty || token.startsWith('guest_')) return;
    _handlingLink = true;
    try {
      await AuthService.instance.saveSiteSession(token);
      if (mounted) setState(() => _stage = _Stage.app);
    } catch (_) {
      // битый/протухший токен — остаёмся на входе
    } finally {
      _handlingLink = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(child: Container(
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [GG.bg, GG.bgDeep], stops: const [0, 0.6])),
      )),
      Positioned.fill(child: _stageView()),
    ]);
  }

  Widget _stageView() {
    switch (_stage) {
      case _Stage.loading:
        return Center(
          child: CircularProgressIndicator(color: GG.violet, strokeWidth: 2),
        );
      case _Stage.welcome:
        return WelcomeScreen(
          onDone: () => setState(() => _stage = _Stage.auth),
        );
      case _Stage.auth:
        return AuthScreen(
          onLoggedIn: () => setState(() => _stage = _Stage.app),
        );
      case _Stage.app:
        return HomeScreen(
          onLoggedOut: () => setState(() => _stage = _Stage.auth),
        );
    }
  }
}
