// GhostEcos Desktop — единое приложение со всеми разделами.
// Welcome (первый запуск) → Auth → MainShell (sidebar + WebView секции).
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:system_tray/system_tray.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'theme.dart';
import 'auth_service.dart';
import 'screens/welcome_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/main_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1200, 780),
      minimumSize: Size(720, 520),
      backgroundColor: GE.bg,
      titleBarStyle: TitleBarStyle.normal,
      title: GE.appName,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(const GhostEcosApp());
}

class GhostEcosApp extends StatelessWidget {
  const GhostEcosApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: GE.appName,
      debugShowCheckedModeBanner: false,
      theme: GE.theme(),
      home: const _Router(),
    );
  }
}

class _Router extends StatefulWidget {
  const _Router();
  @override
  State<_Router> createState() => _RouterState();
}

enum _Stage { loading, welcome, auth, app }

class _RouterState extends State<_Router> with WindowListener {
  _Stage _stage = _Stage.loading;
  final SystemTray _tray = SystemTray();
  bool _trayReady = false;
  bool _minimizeToTray = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initStage();
    _initTray();
    _initAutostart();
  }

  Future<void> _initStage() async {
    final prefs = await SharedPreferences.getInstance();
    final welcomeDone = prefs.getBool('welcome_done') ?? false;
    final token = await AuthService.token();
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

  Future<void> _initTray() async {
    try {
      await _tray.initSystemTray(
        title: GE.appName,
        iconPath: 'assets/icon.ico',
        toolTip: GE.appName,
      );
      final menu = Menu();
      await menu.buildFrom([
        MenuItemLabel(label: 'Открыть', onClicked: (_) async {
          await windowManager.show(); await windowManager.focus();
        }),
        MenuSeparator(),
        MenuItemCheckbox(
          label: 'Сворачивать в трей при закрытии',
          checked: _minimizeToTray,
          onClicked: (item) {
            setState(() => _minimizeToTray = !_minimizeToTray);
            item.setCheck(_minimizeToTray);
          },
        ),
        MenuSeparator(),
        MenuItemLabel(label: 'Выйти', onClicked: (_) async {
          await windowManager.destroy();
        }),
      ]);
      await _tray.setContextMenu(menu);
      _tray.registerSystemTrayEventHandler((ev) async {
        if (ev == kSystemTrayEventClick) {
          await windowManager.show(); await windowManager.focus();
        } else if (ev == kSystemTrayEventRightClick) {
          await _tray.popUpContextMenu();
        }
      });
      _trayReady = true;
    } catch (_) {}
  }

  Future<void> _initAutostart() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      launchAtStartup.setup(
        appName: GE.appName,
        appPath: Platform.resolvedExecutable,
        packageName: pkg.packageName,
      );
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    if (_minimizeToTray && _trayReady) {
      await windowManager.hide();
    } else {
      await windowManager.destroy();
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.loading:
        return const Scaffold(
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
