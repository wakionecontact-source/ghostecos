// Глобальный индикатор связи — висит слева по центру экрана поверх любого
// таба. Жёлтый = нет интернета вообще (актуально и гостю — LAN тоже может
// требовать сеть для некоторых транспортов, да и просто полезно знать).
// Красный = интернет есть, но нет соединения с сервером — гостю никогда,
// у него сервер вообще не используется (см. isGuest). Тап — короткая
// подсказка тостом. Если всё ок — виджет пустой, не мозолит глаза зря.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/ws_client.dart';

class ConnectivityBadge extends StatefulWidget {
  final bool isGuest;
  const ConnectivityBadge({super.key, required this.isGuest});

  @override
  State<ConnectivityBadge> createState() => _ConnectivityBadgeState();
}

class _ConnectivityBadgeState extends State<ConnectivityBadge> {
  bool _hasInternet = true;
  bool _serverConnected = true;
  Timer? _pingTimer;
  StreamSubscription<bool>? _wsSub;

  @override
  void initState() {
    super.initState();
    _serverConnected = WsClient.instance.isConnected;
    _wsSub = WsClient.instance.onConnectionChange.listen((v) {
      if (mounted) setState(() => _serverConnected = v);
    });
    _checkInternet();
    _pingTimer = Timer.periodic(const Duration(seconds: 8), (_) => _checkInternet());
  }

  Future<void> _checkInternet() async {
    bool ok;
    try {
      final result = await InternetAddress.lookup('one.one.one.one')
          .timeout(const Duration(seconds: 4));
      ok = result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      ok = false;
    }
    if (mounted && ok != _hasInternet) setState(() => _hasInternet = ok);
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _wsSub?.cancel();
    super.dispose();
  }

  void _showInfo(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Жёлтый приоритетнее: если нет интернета, до сервера всё равно не
    // достучаться — показывать оба смысла разом только путать.
    final noInternet = !_hasInternet;
    final noServer = !widget.isGuest && _hasInternet && !_serverConnected;
    if (!noInternet && !noServer) return const SizedBox.shrink();
    final color = noInternet ? GE.yellow : GE.red;
    final icon = noInternet ? Icons.wifi_off_rounded : Icons.cloud_off_outlined;
    final text = noInternet
        ? 'Нет интернета — сообщения не отправятся'
        : 'Нет связи с сервером — переподключаемся';
    return Positioned(
      left: 10,
      top: 0,
      bottom: 0,
      child: Center(
        child: GestureDetector(
          onTap: () => _showInfo(text),
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
