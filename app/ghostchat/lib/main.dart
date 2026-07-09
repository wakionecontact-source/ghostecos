// Ghost — единое native приложение. Mesh-фон сквозной + glass-карточки.
//
// Архитектура: welcome → permissions → auth → main_shell с табами (Чат /
// Профиль). Никаких WebView. Cross-platform: Android, iOS, Windows, Linux,
// macOS из одного кода.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';
import 'services/auth_service.dart';
import 'services/theme_service.dart';
import 'services/notification_service.dart';
import 'services/fcm_service.dart';
import 'screens/welcome_screen.dart';
import 'screens/permissions_screen.dart';
import 'screens/key_choice_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/preparing_screen.dart';
import 'screens/main_shell.dart';
import 'screens/logs_screen.dart';
import 'widgets/toast_overlay.dart';
import 'widgets/key_gate.dart';

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
  // Уведомления о новых сообщениях (пока приложение живо). Defensive.
  await NotificationService.instance.init();
  // Кнопка "Логи" на тостах — открывает LogsScreen поверх текущего экрана.
  toast.onNavigateToLogs = () {
    NotificationService.navigatorKey.currentState
        ?.push(MaterialPageRoute(builder: (_) => const LogsScreen()));
  };
  // FCM (надёжный wake через Google Play Services, MIUI не блокирует).
  await FcmService.instance.init();
  // Прозрачные status/nav bar — mesh должен просвечивать через них (Android 15+
  // и так включает edge-to-edge, но без этого system bars будут с дефолтным
  // тёмным фоном поверх mesh).
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarContrastEnforced: false,
    ),
  );
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
        navigatorKey: NotificationService.navigatorKey,
        theme: GE.theme(),
        // Оверлей внутренних уведомлений (тосты) — поверх всех экранов.
        builder: (context, child) =>
            ToastOverlay(child: child ?? const SizedBox.shrink()),
        // НЕ const — иначе при смене темы home-поддерево не перерисовывается
        // и тема меняется только внутри настроек, а не во всём приложении.
        home: _Root(),
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
        // Глубокий фон на весь апп — берёт цвета активной темы (чтобы светлая
        // «Слоновая кость» не оставалась на тёмном фоне).
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [GE.bg, GE.bgDeep],
                stops: const [0.0, 0.55],
              ),
            ),
          ),
        ),
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

enum _Stage { loading, welcome, permissions, keychoice, auth, preparing, app }

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
    final permsDone = prefs.getBool('permissions_done') ?? false;
    final keyChoiceDone = prefs.getBool('keychoice_done') ?? false;
    final token = await AuthService.token();
    final loggedIn = token != null && token.isNotEmpty;
    final isGuest = loggedIn && await AuthService.isGuest();
    if (!mounted) return;
    setState(() {
      if (!welcomeDone) {
        _stage = _Stage.welcome;
      } else if (!permsDone) {
        _stage = _Stage.permissions;
      } else if (!loggedIn) {
        // Выбор ключа — ПОСЛЕ входа/регистрации, а не до: до этого момента
        // ещё нет аккаунта, которому ключ вообще принадлежит.
        _stage = _Stage.auth;
      } else if (!keyChoiceDone && !isGuest) {
        // У гостя нет аккаунта и нет ключа для бэкапа на сервере — этот шаг
        // ему не нужен вообще, не только "потом".
        _stage = _Stage.keychoice;
      } else {
        _stage = _Stage.app;
      }
    });
  }

  /// После экрана "Привет" — на выбор ключа (если ещё не делали на этом
  /// устройстве) или сразу в приложение. Гостю выбор ключа не нужен вообще —
  /// у гостя нет аккаунта и нет ключа для бэкапа на сервере.
  Future<void> _afterPreparing() async {
    final isGuest = await AuthService.isGuest();
    if (isGuest) {
      if (mounted) setState(() => _stage = _Stage.app);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final keyChoiceDone = prefs.getBool('keychoice_done') ?? false;
    if (!mounted) return;
    setState(() => _stage = keyChoiceDone ? _Stage.app : _Stage.keychoice);
  }

  @override
  Widget build(BuildContext context) {
    // Плавный переход между стадиями онбординга (fade + лёгкий сдвиг).
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.035),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: _stageView(),
    );
  }

  Widget _stageView() {
    switch (_stage) {
      case _Stage.loading:
        return KeyedSubtree(
          key: const ValueKey('loading'),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(child: CircularProgressIndicator(color: GE.primary)),
          ),
        );
      case _Stage.welcome:
        return KeyedSubtree(
          key: const ValueKey('welcome'),
          child: WelcomeScreen(
            onDone: () => setState(() => _stage = _Stage.permissions),
          ),
        );
      case _Stage.permissions:
        return KeyedSubtree(
          key: const ValueKey('permissions'),
          child: PermissionsScreen(
            onDone: () => setState(() => _stage = _Stage.auth),
          ),
        );
      case _Stage.keychoice:
        return KeyedSubtree(
          key: const ValueKey('keychoice'),
          child: KeyChoiceScreen(
            onDone: () => setState(() => _stage = _Stage.app),
          ),
        );
      case _Stage.auth:
        return KeyedSubtree(
          key: const ValueKey('auth'),
          child: AuthScreen(
            onLoggedIn: () => setState(() => _stage = _Stage.preparing),
          ),
        );
      case _Stage.preparing:
        return KeyedSubtree(
          key: const ValueKey('preparing'),
          child: PreparingScreen(onDone: _afterPreparing),
        );
      case _Stage.app:
        return KeyedSubtree(
          key: const ValueKey('app'),
          child: KeyGate(
            child: MainShell(
              onLoggedOut: () => setState(() => _stage = _Stage.auth),
            ),
          ),
        );
    }
  }
}
