// Ghost — единое native приложение. Mesh-фон сквозной + glass-карточки.
//
// Архитектура: welcome → auth → main_shell с табами (Чат / Лента / Банк /
// Профиль). Никаких WebView. Cross-platform: Android, iOS, Windows, Linux,
// macOS из одного кода.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';
import 'mesh_background.dart';
import 'services/auth_service.dart';
import 'services/theme_service.dart';
import 'screens/welcome_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/main_shell.dart';

// Desktop-only imports — на мобиле не подключатся (Platform-guard).
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Инициализация локалей для intl (DateFormat('E', 'ru') и подобное).
  // Без этого упадёт LocaleDataException при показе дня недели в списке чатов.
  await initializeDateFormatting('ru');
  await initializeDateFormatting('en');
  // Загружаем сохранённую тему — должно произойти ДО первого runApp,
  // чтобы статические поля GE сразу имели правильные цвета.
  await ThemeService.instance.load();
  // Прозрачные status/nav bar — mesh должен просвечивать через них (Android 15+
  // и так включает edge-to-edge, но без этого system bars будут с дефолтным
  // тёмным фоном поверх mesh).
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  ));
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
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
    // ValueListenableBuilder перерисует MaterialApp при смене темы → все
    // GE.* сразу подхватят новые значения через rebuild.
    return ValueListenableBuilder<Palette>(
      valueListenable: ThemeService.instance.notifier,
      builder: (_, _, _) => MaterialApp(
        title: GE.appName,
        debugShowCheckedModeBanner: false,
        theme: GE.theme(),
        home: const _Root(),
      ),
    );
  }
}

/// Root-виджет: mesh-фон + Router.
class _Root extends StatelessWidget {
  const _Root();
  @override
  Widget build(BuildContext context) {
    // Mesh-фон растянут на ВЕСЬ экран включая зоны под status/nav bar — он
    // должен красиво просвечивать через прозрачные системные панели.
    // А UI (Router и его экраны) — внутри SafeArea, чтобы не лез под камеру/
    // кнопку «домой» (Android 15+ edge-to-edge по умолчанию).
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: GE.bg)),
        const Positioned.fill(child: MeshBackground()),
        Positioned.fill(
          child: SafeArea(
            // SafeArea сам по себе НЕ закрашивает фон — mesh остаётся виден
            // под status bar (transparent). minimum=EdgeInsets.zero на случай
            // когда системных insets нет (например на десктопе).
            minimum: EdgeInsets.zero,
            child: _Router(),
          ),
        ),
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
        return Scaffold(
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
