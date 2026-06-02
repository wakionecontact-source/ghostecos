// GhostEcos Desktop — Flutter wrapper для ghostecos.duckdns.org
// v1: WebView + system tray + native notifications + autostart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:window_manager/window_manager.dart';
import 'package:system_tray/system_tray.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';

const String _kBaseUrl = 'https://ghostecos.duckdns.org';
const String _kAppName = 'GhostEcos';
const String _kIconPath = 'assets/icon.ico';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1100, 740),
      minimumSize: Size(640, 480),
      backgroundColor: Color(0xFF020617),
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
      title: _kAppName,
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
      title: _kAppName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFA855F7),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF020617),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with WindowListener, WidgetsBindingObserver {
  final WebviewController _webview = WebviewController();
  final SystemTray _tray = SystemTray();
  final FlutterLocalNotificationsPlugin _notif =
      FlutterLocalNotificationsPlugin();
  String _currentUrl = '$_kBaseUrl/chat/';
  bool _isWebViewReady = false;
  bool _minimizeToTray = true;
  String? _initError;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    _initAll();
  }

  Future<void> _initAll() async {
    try {
      await _initWebView();
      await _initNotifications();
      await _initTray();
      await _initAutostart();
    } catch (e) {
      setState(() => _initError = e.toString());
    }
  }

  Future<void> _initWebView() async {
    await _webview.initialize();
    await _webview.setBackgroundColor(const Color(0xFF020617));
    await _webview.loadUrl(_currentUrl);
    // JS-bridge для native-уведомлений из веба:
    //   window.chrome.webview.postMessage(JSON.stringify({type:'notify', title:'...', body:'...'}))
    _webview.webMessage.listen((msg) async {
      try {
        final s = msg.toString();
        if (s.contains('"type":"notify"')) {
          final titleMatch = RegExp(r'"title":"([^"]*)"').firstMatch(s);
          final bodyMatch = RegExp(r'"body":"([^"]*)"').firstMatch(s);
          await _showNotification(
            titleMatch?.group(1) ?? _kAppName,
            bodyMatch?.group(1) ?? '',
          );
        }
      } catch (_) {}
    });
    setState(() => _isWebViewReady = true);
  }

  Future<void> _initNotifications() async {
    // На Linux — native libnotify. На Windows — нужен отдельный пакет (win_toast / winrt).
    // Для wrapper v1 оставляем Linux-init; для Windows используем in-app banner.
    if (Platform.isLinux) {
      const initSettings = InitializationSettings(
        linux: LinuxInitializationSettings(defaultActionName: 'Открыть'),
      );
      await _notif.initialize(initSettings);
    }
  }

  Future<void> _showNotification(String title, String body) async {
    if (Platform.isLinux) {
      const details = NotificationDetails(linux: LinuxNotificationDetails());
      await _notif.show(
        DateTime.now().millisecondsSinceEpoch.remainder(100000),
        title,
        body,
        details,
      );
    } else {
      // Windows: TODO — добавить win_toast или WinRT toast notification API.
      // Пока: фокусим окно если оно скрыто.
      if (await windowManager.isMinimized() || !await windowManager.isVisible()) {
        await windowManager.show();
        await windowManager.focus();
      }
    }
  }

  Future<void> _initTray() async {
    await _tray.initSystemTray(
      title: _kAppName,
      iconPath: _kIconPath,
      toolTip: _kAppName,
    );
    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(label: 'Открыть GhostChat', onClicked: (_) => _openSection('/chat/')),
      MenuItemLabel(label: 'GhostSocial', onClicked: (_) => _openSection('/social/')),
      MenuItemLabel(label: 'GhostBank', onClicked: (_) => _openSection('/bank/')),
      MenuItemLabel(label: 'GhostNation', onClicked: (_) => _openSection('/nation/')),
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
    _tray.registerSystemTrayEventHandler((eventName) async {
      if (eventName == kSystemTrayEventClick) {
        await windowManager.show();
        await windowManager.focus();
      } else if (eventName == kSystemTrayEventRightClick) {
        await _tray.popUpContextMenu();
      }
    });
  }

  Future<void> _initAutostart() async {
    final pkg = await PackageInfo.fromPlatform();
    launchAtStartup.setup(
      appName: _kAppName,
      appPath: Platform.resolvedExecutable,
      packageName: pkg.packageName,
    );
  }

  Future<void> _openSection(String path) async {
    final url = '$_kBaseUrl$path';
    setState(() => _currentUrl = url);
    if (_isWebViewReady) await _webview.loadUrl(url);
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() async {
    if (_minimizeToTray) {
      await windowManager.hide();
    } else {
      await windowManager.destroy();
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    _webview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline,
                    size: 64, color: Color(0xFFF87171)),
                const SizedBox(height: 16),
                const Text('Ошибка инициализации',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(_initError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF94A3B8))),
                const SizedBox(height: 16),
                const Text(
                  'Для WebView2 нужен Microsoft Edge WebView2 Runtime\n(обычно установлен в Windows 11)',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (!_isWebViewReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: Webview(_webview, permissionRequested: _onPermissionRequested),
    );
  }

  Future<WebviewPermissionDecision> _onPermissionRequested(
      String url, WebviewPermissionKind kind, bool isUserInitiated) async {
    if (kind == WebviewPermissionKind.microphone ||
        kind == WebviewPermissionKind.camera) {
      final allow = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(kind == WebviewPermissionKind.microphone
              ? 'Разрешить микрофон?'
              : 'Разрешить камеру?'),
          content: Text(url),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Нет')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Да')),
          ],
        ),
      );
      return allow == true
          ? WebviewPermissionDecision.allow
          : WebviewPermissionDecision.deny;
    }
    return WebviewPermissionDecision.allow;
  }
}
