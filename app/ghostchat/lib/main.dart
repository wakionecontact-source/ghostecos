// Ghost — единое native приложение. Mesh-фон сквозной + glass-карточки.
//
// Архитектура: welcome → permissions → auth → main_shell с табами (Чат /
// Профиль). Никаких WebView. Cross-platform: Android, iOS, Windows, Linux,
// macOS из одного кода.

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme.dart';
import 'mesh_background.dart';
import 'services/auth_service.dart';
import 'services/theme_service.dart';
import 'services/nav_bar_settings.dart';
import 'services/network_settings.dart';
import 'services/remote_settings_service.dart';
import 'services/ghost_asset_ota.dart';
import 'services/settings_order.dart';
import 'services/app_security_store.dart';
import 'services/notification_settings.dart';
import 'services/notification_service.dart';
import 'services/sound_settings.dart';
import 'services/ghost_sound_effects.dart';
import 'services/fcm_service.dart';
import 'services/update_service.dart';
import 'services/performance_service.dart';
import 'services/global_audio_player.dart';
import 'services/incoming_call_notification_service.dart';
import 'services/profile_appearance_settings.dart';
import 'services/app_avatar_settings.dart';
import 'services/room_deep_link.dart';
import 'screens/welcome_screen.dart';
import 'screens/permissions_screen.dart';
import 'screens/key_setup_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/preparing_screen.dart';
import 'screens/main_shell.dart';
import 'screens/logs_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/room_link_preview_screen.dart';
import 'screens/security_screen.dart';
import 'widgets/toast_overlay.dart';
import 'widgets/key_gate.dart';
import 'widgets/liquid_glass.dart';
import 'core/local/app_logger.dart';

// Desktop-only imports — на мобиле не подключатся (Platform-guard).
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    appLog.error(
      'flutter',
      '${details.exceptionAsString()}\n${details.stack ?? ''}',
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    appLog.error('runtime', '$error\n$stack');
    return false;
  };
  appLog.info('app', 'GhostChat запускается');
  NotificationService.onUpdateNotificationTap =
      UpdateService.instance.openPendingUpdate;
  // Notification channels and Firebase may touch Android services/network.
  // They must not delay the first Flutter frame or make a cold start look
  // frozen when the network is slow.
  // Кнопка "Логи" на тостах — открывает LogsScreen поверх текущего экрана.
  toast.onNavigateToLogs = (logId) {
    if (AppSecurityStore.instance.isInSafeMode) return;
    NotificationService.navigatorKey.currentState?.push(
      MaterialPageRoute(builder: (_) => LogsScreen(focusLogId: logId)),
    );
  };
  // Generic FCM-пуш отключён: он дублировал настроенное локальное уведомление.
  // Generic FCM is disabled from the post-frame bootstrap below.
  // Прозрачные status/nav bar — mesh должен просвечивать через них (Android 15+
  // и так включает edge-to-edge, но без этого system bars будут с дефолтным
  // тёмным фоном поверх mesh). Яркость иконок пересчитывается на каждую смену
  // темы в GhostApp.build() (см. _applySystemBarStyle) — на светлой "Слоновой
  // кости" светлые иконки на светлом фоне были бы невидимы.
  _applySystemBarStyle();
  unawaited(RoomDeepLinkService.instance.start());
  runApp(const GhostApp());
  // Nothing in this bootstrap is required to paint or interact with the first
  // screen. Keep plugin/storage work off the cold-start critical path.
  unawaited(_bootstrapAfterFirstFrame());
}

Future<void> _bootstrapAfterFirstFrame() async {
  // Optional plugins must never delay runApp(). On some MIUI builds
  // AudioService.init() can wait for the native media service long enough to
  // leave the first Flutter screen looking frozen. The player still gets its
  // system controls, but only after the UI has painted and accepted input.
  await WidgetsBinding.instance.endOfFrame;

  try {
    // Restore the previously verified asset overlay before preloading sounds.
    await GhostAssetOta.instance.loadLocal();
    unawaited(GhostAssetOta.instance.refresh());
  } catch (e, stack) {
    appLog.warn('asset-ota', 'asset OTA startup was skipped: $e\n$stack');
  }

  // Initialize the native WebRTC audio device after the first frame. This
  // keeps cold start responsive while making the first call use the same
  // echo/noise processing path on Android as subsequent calls.
  if (Platform.isAndroid) {
    try {
      await WebRTC.initialize(
        options: const {
          'bypassVoiceProcessing': false,
          'androidUseHardwareAudioProcessing': true,
        },
      );
    } catch (e, stack) {
      appLog.warn('call', 'WebRTC initialization deferred: $e\n$stack');
    }
  }
  try {
    await IncomingCallNotificationService.instance.initialize();
  } catch (e, stack) {
    appLog.warn('call', 'Incoming-call notifications unavailable: $e\n$stack');
  }

  // Preload short UI tones after first paint; they use sonification audio
  // attributes and never take focus from the music player.
  unawaited(GhostSoundEffects.instance.initialize());

  try {
    await AudioNotificationService.instance.init();
    AudioNotificationService.instance.bind(GlobalAudioPlayer.instance);
  } catch (e, stack) {
    appLog.error('audio_notification', '$e\n$stack');
  }

  try {
    // На критическом заряде Android может жёстко ограничивать CPU/GPU.
    await PerformanceService.instance.initialize();
    // Инициализация локалей для intl (DateFormat('E', 'ru') и подобное).
    await initializeDateFormatting('ru');
    await initializeDateFormatting('en');
    // Тема и остальные настройки имеют безопасные значения по умолчанию;
    // сохранённые значения подхватятся сразу после первого кадра.
    await ThemeService.instance.load();
    await LiquidGlassEngine.initialize();
    await NavBarSettings.instance.load();
    await NetworkSettings.instance.load();
    await RemoteSettingsService.instance.loadLocal();
    unawaited(RemoteSettingsService.instance.refresh());
    await SettingsOrder.instance.load();
    await NotificationSettings.instance.load();
    await SoundSettings.instance.load();
    await ProfileAppearanceSettings.instance.load();
    await AppAvatarSettings.instance.load();

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

    await NotificationService.instance.init();
    await FcmService.instance.disableGenericPush();
  } catch (e, stack) {
    // Optional startup services must never leave the app on a blank/frozen
    // screen. Their individual defaults keep the UI usable.
    appLog.error('bootstrap', '$e\n$stack');
  }
}

/// Иконки статус-бара/навигации подстраиваются под яркость активной темы —
/// на тёмных темах светлые (видны на тёмном фоне), на светлой "Слоновой
/// кости" тёмные (иначе светлые иконки пропадают на светлом фоне и верхняя
/// строка выглядит "не дизайненной", будто чужеродной системной полосой).
Future<void> _openAudioSource(
  BuildContext context,
  GlobalAudioPlayer player,
) async {
  final track = player.currentTrack;
  final source = track?['_audio_source']?.toString();
  final username = track?['_audio_profile_username']?.toString().trim();
  if (source != 'profile_music' || username == null || username.isEmpty) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ProfileScreen(username: username, openMusicLibrary: true),
    ),
  );
}

void _applySystemBarStyle() {
  final light = GE.currentBrightness == Brightness.light;
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: light ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: light
          ? Brightness.dark
          : Brightness.light,
      systemNavigationBarContrastEnforced: false,
    ),
  );
}

class GhostApp extends StatelessWidget {
  const GhostApp({super.key});
  @override
  Widget build(BuildContext context) {
    // Only theme changes rebuild MaterialApp. A battery/profile change is
    // handled by the small builder inside MaterialApp below, so the root
    // Navigator and current route remain stable on MIUI.
    return ListenableBuilder(
      listenable: Listenable.merge([
        ThemeService.instance.notifier,
        ThemeService.instance.cornerNotifier,
      ]),
      builder: (_, _) {
        _applySystemBarStyle();
        return MaterialApp(
          title: GE.appName,
          debugShowCheckedModeBanner: false,
          navigatorKey: NotificationService.navigatorKey,
          // Наблюдатель, через который MeshBackground узнаёт о перекрытии
          // сверху и ставит анимацию частиц на паузу (экономия кадров).
          navigatorObservers: [meshRouteObserver],
          theme: GE.theme(),
          // Оверлей внутренних уведомлений (тосты) — поверх всех экранов.
          builder: (context, child) {
            // Keep performance-profile rebuilds below MaterialApp. Recreating
            // the root Navigator while MIUI changes power policy can leave the
            // active route looking frozen and can drop its input state.
            return ListenableBuilder(
              listenable: Listenable.merge([
                PerformanceService.instance.animationQualityNotifier,
                PerformanceService.instance.guiQualityNotifier,
                PerformanceService.instance.energySavingActiveNotifier,
                PerformanceService.instance.reducedEffectsNotifier,
              ]),
              builder: (context, _) {
                // Energy mode may reduce visual animations, but it must never
                // disable the root ticker: that freezes scrolling and gestures
                // on some Android devices. Keep the shell interactive in energy mode.
                final disableGlobalAnimations =
                    PerformanceService.instance.animationsDisabled &&
                    !PerformanceService.instance.energySavingActive;
                final content = TickerMode(
                  enabled: !disableGlobalAnimations,
                  child: GlobalAudioPlayerHost(
                    onOpenSource: _openAudioSource,
                    child: ToastOverlay(
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                );
                final media = MediaQuery.maybeOf(context);
                final appContent = media == null
                    ? content
                    : MediaQuery(
                        data: media.copyWith(
                          disableAnimations:
                              media.disableAnimations ||
                              disableGlobalAnimations,
                        ),
                        child: content,
                      );
                return ListenableBuilder(
                  listenable: GhostAssetOta.instance.revisionNotifier,
                  builder: (context, _) => DefaultAssetBundle(
                    bundle: GhostOtaAssetBundle(),
                    child: appContent,
                  ),
                );
              },
            );
          },
          // НЕ const — иначе при смене темы home-поддерево не перерисовывается
          // и тема меняется только внутри настроек, а не во всём приложении.
          home: _Root(),
        );
      },
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
        // AnimatedContainer вместо DecoratedBox — при смене темы фон плавно
        // перетекает старыми цветами в новые (BoxDecoration/LinearGradient
        // анимируется "из коробки" через DecorationTween), а не щёлкает
        // мгновенно. _Root/_Router своё состояние не теряют — это тот же
        // виджет на том же месте дерева, просто с новым decoration.
        Positioned.fill(
          child: AnimatedContainer(
            duration: PerformanceService.instance.animationDuration(
              const Duration(milliseconds: 420),
            ),
            curve: Curves.easeInOut,
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

enum _Stage { loading, welcome, permissions, keysetup, auth, preparing, app }

class _Router extends StatefulWidget {
  const _Router();
  @override
  State<_Router> createState() => _RouterState();
}

class _RouterState extends State<_Router> {
  _Stage _stage = _Stage.loading;
  bool _deepLinkOpenScheduled = false;
  // Гость нажал "Зарегистрироваться" в MainShell — следующий показ AuthScreen
  // должен открыться сразу на вкладке регистрации, а не логина.
  bool _authStartInRegister = false;

  @override
  void initState() {
    super.initState();
    AuthService.sessionInvalidNotifier.addListener(_onSessionInvalid);
    RoomDeepLinkService.instance.pending.addListener(_onPendingDeepLink);
    unawaited(RoomDeepLinkService.instance.start());
    _initStage();
  }

  void _onPendingDeepLink() {
    if (_stage == _Stage.app) _schedulePendingDeepLink();
  }

  void _schedulePendingDeepLink() {
    if (!mounted || _deepLinkOpenScheduled) return;
    if (RoomDeepLinkService.instance.pending.value == null) return;
    _deepLinkOpenScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final raw = RoomDeepLinkService.instance.take();
        if (raw == null || !mounted) return;
        final target = RoomLinkTarget.parse(raw);
        if (target == null) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => RoomLinkPreviewScreen(target: target),
          ),
        );
      } finally {
        _deepLinkOpenScheduled = false;
      }
    });
  }

  void _onSessionInvalid() {
    // MainShell выполняет полный cleanup текущего приложения сам. До него
    // (key choice/preparing) нужно не пропустить пользователя дальше в app.
    if (!mounted || _stage == _Stage.app || _stage == _Stage.auth) return;
    setState(() => _stage = _Stage.auth);
  }

  Future<void> _initStage() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 4),
      );
      final welcomeDone = prefs.getBool('welcome_done') ?? false;
      final permsDone = prefs.getBool('permissions_done') ?? false;
      final token = await AuthService.token();
      final loggedIn = token != null && token.isNotEmpty;
      final isGuest = loggedIn && await AuthService.isGuest();
      final sessionInvalid = AuthService.sessionInvalidNotifier.value;
      if (!mounted) return;
      setState(() {
        if (!welcomeDone) {
          _stage = _Stage.welcome;
        } else if (!permsDone) {
          _stage = _Stage.permissions;
        } else if (!loggedIn || sessionInvalid) {
          // Выбор ключа — ПОСЛЕ входа/регистрации, а не до: до этого момента
          // ещё нет аккаунта, которому ключ вообще принадлежит.
          _stage = _Stage.auth;
        } else if (!isGuest) {
          // Реальный аккаунт каждый раз проходит безопасную проверку ключа.
          // Local-режим с существующим локальным ключом завершается без вопроса.
          _stage = _Stage.keysetup;
        } else {
          _stage = _Stage.app;
        }
      });
    } catch (e, stack) {
      appLog.error('startup', 'initial state load failed: $e\n$stack');
      if (!mounted) return;
      // The loading view has no controls. Fall back to an interactive auth
      // screen if the platform preferences bridge remains unavailable.
      setState(() => _stage = _Stage.auth);
    }
  }

  /// После экрана "Привет" — на выбор ключа (если ещё не делали на этом
  /// устройстве И сервер ещё не знает режим для аккаунта) или сразу в
  /// приложение. Гостю выбор ключа не нужен вообще — у гостя нет аккаунта и
  /// нет ключа для серверной копии.
  Future<void> _afterPreparing() async {
    final isGuest = await AuthService.isGuest();
    if (isGuest) {
      if (mounted) setState(() => _stage = _Stage.app);
      return;
    }
    if (!mounted) return;
    if (AuthService.sessionInvalidNotifier.value) {
      setState(() => _stage = _Stage.auth);
      return;
    }
    setState(() => _stage = _Stage.keysetup);
  }

  @override
  void dispose() {
    AuthService.sessionInvalidNotifier.removeListener(_onSessionInvalid);
    RoomDeepLinkService.instance.pending.removeListener(_onPendingDeepLink);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Плавный переход между стадиями онбординга (fade + лёгкий сдвиг).
    return AnimatedSwitcher(
      duration: PerformanceService.instance.animationDuration(
        const Duration(milliseconds: 420),
      ),
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
    if (_stage == _Stage.app) _schedulePendingDeepLink();
    switch (_stage) {
      case _Stage.loading:
        return KeyedSubtree(
          key: const ValueKey('loading'),
          child: MeshBackground(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable:
                          AppAvatarSettings.instance.selectedVariantNotifier,
                      builder: (_, variant, _) => ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: Image.asset(
                          AppAvatarSettings.instance.assetPathFor(variant),
                          width: 84,
                          height: 84,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      GE.appName,
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: GE.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
      case _Stage.keysetup:
        return KeyedSubtree(
          key: const ValueKey('keysetup'),
          child: KeySetupScreen(
            onDone: () => setState(() => _stage = _Stage.app),
          ),
        );
      case _Stage.auth:
        return KeyedSubtree(
          key: const ValueKey('auth'),
          child: AuthScreen(
            startInRegister: _authStartInRegister,
            onLoggedIn: () => setState(() {
              _authStartInRegister = false;
              _stage = _Stage.preparing;
            }),
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
            child: SecurityGate(
              child: MainShell(
                onLoggedOut: () => setState(() => _stage = _Stage.auth),
                onRegister: () => setState(() {
                  _authStartInRegister = true;
                  _stage = _Stage.auth;
                }),
              ),
            ),
          ),
        );
    }
  }
}
