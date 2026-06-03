// Ghost — единое native приложение. Mesh-фон сквозной + glass-карточки.
//
// Архитектура: welcome → auth → main_shell с табами (Чат / Лента / Банк /
// Профиль). Никаких WebView. Cross-platform: Android, iOS, Windows, Linux,
// macOS из одного кода.

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';
import 'mesh_background.dart';
import 'services/auth_service.dart';
import 'screens/welcome_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/main_shell.dart';

// Desktop-only imports — на мобиле не подключатся (Platform-guard).
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1200, 780),
        minimumSize: Size(380, 600),
        backgroundColor: GE.bg,
        titleBarStyle: TitleBarStyle.normal,
        title: GE.appName,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  runApp(const GhostApp());
}

class GhostApp extends StatelessWidget {
  const GhostApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: GE.appName,
      debugShowCheckedModeBanner: false,
      theme: GE.theme(),
      home: const _Root(),
    );
  }
}

/// Root-виджет: mesh-фон + Router.
class _Root extends StatelessWidget {
  const _Root();
  @override
  Widget build(BuildContext context) {
    // Mesh-фон под всем приложением — стекло «плавает» поверх.
    return Stack(
      children: const [
        Positioned.fill(child: ColoredBox(color: GE.bg)),
        Positioned.fill(child: MeshBackground()),
        Positioned.fill(child: _Router()),
      ],
    );
  }
}

enum _Stage { loading, welcome, auth, app }

class _Router extends StatefulWidget {
  const _Router();
  @override
  State<_Router> createState() => _RouterState();
}

class _RouterState extends State<_Router> {
  _Stage _stage = _Stage.loading;

  @override
  void initState() {
    super.initState();
    _initStage();
  }

  Future<void> _initStage() async {
    final prefs = await SharedPreferences.getInstance();
    final welcomeDone = prefs.getBool('welcome_done') ?? false;
    final token = await AuthService.token();
    if (!mounted) return;
    setState(() {
      if (!welcomeDone) {
        _stage = _Stage.welcome;
      } else if (token == null || token.isEmpty) {
        _stage = _Stage.auth;
      } else {
        _stage = _Stage.app;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.loading:
        return const Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(child: CircularProgressIndicator(color: GE.primary)),
        );
      case _Stage.welcome:
        return WelcomeScreen(onDone: () => setState(() => _stage = _Stage.auth));
      case _Stage.auth:
        return AuthScreen(onLoggedIn: () => setState(() => _stage = _Stage.app));
      case _Stage.app:
        return MainShell(
          onLoggedOut: () => setState(() => _stage = _Stage.auth),
        );
    }
  }
}
