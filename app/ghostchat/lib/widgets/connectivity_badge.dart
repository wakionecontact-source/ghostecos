// Глобальный индикатор связи — висит слева по центру экрана поверх любого
// таба. Жёлтый = нет интернета вообще (актуально и гостю — LAN тоже может
// требовать сеть для некоторых транспортов, да и просто полезно знать).
// Красный = интернет есть, но нет соединения с сервером — гостю никогда,
// у него сервер вообще не используется (см. isGuest). Тап — короткая
// подсказка тостом. Если всё ок — виджет пустой, не мозолит глаза зря.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../theme.dart';
import '../services/ws_client.dart';
import '../services/room_service.dart';
import '../services/notification_service.dart';
import '../services/network_settings.dart';
import '../services/foreground_service.dart';
import 'toast_overlay.dart';

class ConnectivityBadge extends StatefulWidget {
  final bool isGuest;
  const ConnectivityBadge({super.key, required this.isGuest});

  @override
  State<ConnectivityBadge> createState() => _ConnectivityBadgeState();
}

class _ConnectivityBadgeState extends State<ConnectivityBadge>
    with WidgetsBindingObserver {
  bool _hasInternet = true;
  bool _serverConnected = true;
  Timer? _pingTimer;
  StreamSubscription<bool>? _wsSub;
  bool? _lastConnectionState;
  bool _backgrounded = false;
  bool _checkConnection = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backgrounded =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
    _checkConnection = NetworkSettings.instance.checkConnectionNotifier.value;
    NetworkSettings.instance.checkConnectionNotifier.addListener(
      _onConnectionSettingChanged,
    );
    _serverConnected = WsClient.instance.isConnected;
    _wsSub = WsClient.instance.onConnectionChange.listen((v) {
      if (!mounted) return;
      setState(() => _serverConnected = v);
      _reportConnectionState();
    });
    if (!_backgrounded && _checkConnection) {
      _checkInternet();
      _startTimer();
    }
  }

  void _startTimer() {
    if (!_checkConnection || _pingTimer != null) return;
    if (_backgrounded && !ForegroundService.instance.isConfiguredForProcess) {
      return;
    }
    _pingTimer = Timer.periodic(
      Duration(seconds: _backgrounded ? 30 : 8),
      (_) => _checkInternet(),
    );
  }

  void _onConnectionSettingChanged() {
    if (!mounted) return;
    final enabled = NetworkSettings.instance.checkConnectionNotifier.value;
    setState(() => _checkConnection = enabled);
    if (!enabled) {
      _pingTimer?.cancel();
      _pingTimer = null;
      unawaited(NotificationService.instance.clearConnectionCheck());
    } else {
      _startTimer();
      unawaited(_checkInternet());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgrounded = false;
      _pingTimer?.cancel();
      _pingTimer = null;
      if (_checkConnection) {
        _startTimer();
        _checkInternet();
      }
      if (!widget.isGuest) unawaited(RoomService.instance.syncAllRooms());
      return;
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _backgrounded = true;
      _pingTimer?.cancel();
      _pingTimer = null;
      if (state != AppLifecycleState.detached &&
          ForegroundService.instance.isConfiguredForProcess) {
        _startTimer();
      }
    }
  }

  void _reportConnectionState({bool force = false}) {
    final connected = _hasInternet && (widget.isGuest || _serverConnected);
    final previous = _lastConnectionState;
    _lastConnectionState = connected;
    // Первое измерение — только baseline, иначе запуск приложения сам себе
    // отправляет ложное «связь восстановлена».
    if (!_checkConnection ||
        previous == null ||
        (!force && previous == connected)) {
      return;
    }
    unawaited(
      NotificationService.instance.showConnectionCheck(
        connected: connected,
        hasInternet: _hasInternet,
        serverConnected: _serverConnected,
      ),
    );
  }

  Future<void> _checkInternet({bool manual = false}) async {
    if (!_checkConnection && !manual) return;
    bool ok;
    try {
      // Прямой TCP-коннект по IP, а не DNS-резолв имени — резолв мог
      // отвечать из кэша ОС/роутера даже когда реального интернета уже нет
      // (юзер репортил "жёлтого никогда не бывает", хотя реально был офлайн).
      // 1.1.1.1:443 — сам порт неважен, важно только TCP SYN/ACK по факту.
      final socket = await Socket.connect(
        '1.1.1.1',
        443,
        timeout: const Duration(seconds: 4),
      );
      socket.destroy();
      ok = true;
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (_backgrounded && !ForegroundService.instance.isConfiguredForProcess) {
      return;
    }
    final regainedInternet = !_hasInternet && ok;
    if (ok != _hasInternet) {
      if (_backgrounded) {
        _hasInternet = ok;
      } else {
        setState(() => _hasInternet = ok);
      }
    }
    if (regainedInternet && !widget.isGuest) {
      unawaited(RoomService.instance.syncAllRooms());
    }
    _reportConnectionState(force: manual);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NetworkSettings.instance.checkConnectionNotifier.removeListener(
      _onConnectionSettingChanged,
    );
    _pingTimer?.cancel();
    _wsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Жёлтый приоритетнее: если нет интернета, до сервера всё равно не
    // достучаться — показывать оба смысла разом только путать.
    final noInternet = !_hasInternet;
    final noServer = !widget.isGuest && _hasInternet && !_serverConnected;
    if (!noInternet && !noServer) return const SizedBox.shrink();
    final color = noInternet ? GE.yellow : GE.red;
    final icon = noInternet
        ? CupertinoIcons.wifi_slash
        : Icons.cloud_off_outlined;
    return Positioned(
      left: 10,
      top: 0,
      bottom: 0,
      child: Center(
        child: GestureDetector(
          // Мгновенно перепроверяем интернет по тапу (не ждём периодический
          // 8-секундный таймер) — иначе статус на экране мог на пару секунд
          // отставать от реальности прямо в момент, когда юзер его проверяет.
          onTap: () async {
            await _checkInternet(manual: true);
            if (!mounted) return;
            final stillNoInternet = !_hasInternet;
            final t = stillNoInternet
                ? 'Нет интернета — сообщения не отправятся'
                : (widget.isGuest || _serverConnected)
                ? null
                : 'Нет связи с сервером — переподключаемся';
            if (t == null) return;
            toast.show(
              t,
              level: stillNoInternet ? ToastLevel.warn : ToastLevel.error,
            );
          },
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.18),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}
