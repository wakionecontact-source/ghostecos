// LanScanScreen — «Устройства поблизости» (LAN + Wi-Fi Direct + Bluetooth).
//
// Реальный поиск устройств в локальной сети / рядом (BLE) / Wi-Fi Direct,
// перенесённый из старого GhostChat (ghostchat_mobile). Принятые устройства
// открывают LanChatScreen — чат привязан к устройству, не к аккаунту.
// Транспорты стартуют/останавливаются в MainShell (app-wide), этот экран
// только подписывается на уже бегущий localHub.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';
import '../services/permissions_service.dart';
import '../services/lan_chat_store.dart';
import '../core/local/app_logger.dart';
import '../core/local/lan_settings.dart';
import '../core/local/local_hub.dart';
import '../core/local/local_transport.dart';
import 'lan_chat_screen.dart';

class LanScanScreen extends StatefulWidget {
  const LanScanScreen({super.key});

  /// true пока этот экран смонтирован — MainShell смотрит сюда, чтобы не
  /// дублировать уведомление о пойманном сигнале карточкой на этом же экране.
  static bool isVisible = false;

  @override
  State<LanScanScreen> createState() => _LanScanScreenState();
}

class _LanScanScreenState extends State<LanScanScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  bool _starting = true;
  bool _scanning = false;
  String _status = 'Нажмите, чтобы начать поиск';

  bool _showIp = false;
  String _myIp = '';
  bool _wifiConnected = false;
  bool _btOn = false;

  final List<LocalPeer> _acceptedPeers = [];
  final Set<String> _seenDeviceIds = {};
  final Set<String> _respondedDeviceIds = {};
  // Способы связи, замеченные при обнаружении/принятии устройства — вместе
  // с живыми данными из пинга (localHub.availableTransportsFor) даёт полный
  // список, а не только тот транспорт, что "победил" по приоритету.
  final Map<String, Set<TransportType>> _peerTransports = {};
  LocalGroupedRequest? _incomingRequest;
  LocalPeer? _collectingPeer; // сигнал ловится, окно 5 сек ещё не закрылось
  // Пингует нас устройство, чат с которым удалён локально (см.
  // LocalHub.onStaleContact) — не обычный запрос на подключение, отдельная
  // карточка с блокировкой/восстановлением вместо принять/отклонить.
  final Set<String> _staleContactIds = {};

  StreamSubscription? _acceptSub;
  StreamSubscription? _groupedSub;
  StreamSubscription? _collectingSub;
  StreamSubscription? _staleSub;
  Timer? _scanTimer;
  Timer? _ipTimer;

  @override
  void initState() {
    super.initState();
    LanScanScreen.isVisible = true;
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await LanSettings().load();

    // Транспорты регистрируются и стартуют на уровне MainShell (живут пока
    // юзер залогинен, не только пока открыт этот экран) — здесь только
    // подписываемся на уже бегущий localHub.
    _acceptSub = localHub.onAccept.listen(_onAccepted);
    _collectingSub = localHub.onCollecting.listen((peer) {
      if (!mounted) return;
      if (_respondedDeviceIds.contains(peer.deviceId)) return;
      setState(() => _collectingPeer = peer);
    });
    _groupedSub = localHub.onGroupedRequest.listen((req) {
      if (!mounted) return;
      // Устройство продолжает слать discover-волны, пока сканирует — не
      // показываем повторно то, на что уже ответили в этой сессии.
      if (_respondedDeviceIds.contains(req.deviceId)) return;
      setState(() {
        _collectingPeer = null; // окно сбора закрылось — теперь можно решать
        _incomingRequest = req;
      });
      // Уведомление (пуш/тост) шлёт MainShell глобально — этот экран открыт,
      // карточки достаточно, дублировать не нужно.
    });
    _staleSub = localHub.onStaleContact.listen((deviceId) {
      if (!mounted) return;
      setState(() => _staleContactIds.add(deviceId));
    });

    await _requestPermissions();
    await _refreshConnectivity();

    _ipTimer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshConnectivity());

    if (mounted) setState(() => _starting = false);
  }

  @override
  void dispose() {
    LanScanScreen.isVisible = false;
    _ctrl.dispose();
    _acceptSub?.cancel();
    _groupedSub?.cancel();
    _collectingSub?.cancel();
    _staleSub?.cancel();
    _scanTimer?.cancel();
    _ipTimer?.cancel();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    await ensurePermission(Permission.bluetoothScan);
    await ensurePermission(Permission.bluetoothConnect);
    await ensurePermission(Permission.bluetoothAdvertise);
    await ensurePermission(Permission.nearbyWifiDevices);
    await ensurePermission(Permission.locationWhenInUse);
  }

  Future<void> _refreshConnectivity() async {
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      String ip = '';
      bool hasWlan = false;
      for (final iface in ifaces) {
        if (iface.name.toLowerCase().startsWith('wlan')) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback) { ip = addr.address; hasWlan = true; break; }
          }
        }
      }
      if (!hasWlan) {
        for (final iface in ifaces) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback && addr.address.startsWith('192.168.')) {
              ip = addr.address; hasWlan = true; break;
            }
          }
          if (hasWlan) break;
        }
      }
      if (!mounted) return;
      setState(() { _myIp = ip; _wifiConnected = hasWlan; });
    } catch (_) {}

    try {
      final on = await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
      if (mounted) setState(() => _btOn = on);
    } catch (_) {
      if (mounted) setState(() => _btOn = false);
    }
  }

  Future<void> _onAccepted(LocalPeer peer) async {
    if (_seenDeviceIds.contains(peer.deviceId)) return;
    // TOFU: если identity этого device_id уже закреплена и НЕ совпадает —
    // это подмена (или переустановка чужого устройства с тем же UUID),
    // отклоняем молча, не показываем как подключённое.
    final identityOk = await LanChatStore.instance
        .checkAndPinIdentity(peer.deviceId, peer.identityPubB64);
    if (!identityOk) {
      appLog.warn('security', 'Identity ${peer.deviceId} изменилась — отклонено');
      return;
    }
    _seenDeviceIds.add(peer.deviceId);
    setState(() {
      _acceptedPeers.add(peer);
      _peerTransports.putIfAbsent(peer.deviceId, () => {}).add(peer.transport);
      _status = '${peer.label} принял(а) запрос';
    });
    LanChatStore.instance.createOrGetChat(
      deviceId: peer.deviceId,
      // Полный device_id — см. комментарий в main_shell.dart._onLanAccepted.
      displayName: peer.deviceId,
      peerPubB64: peer.x25519PubB64,
      identityPubB64: peer.identityPubB64,
      transport: peer.chatType,
    );
  }

  Future<void> _startScan() async {
    setState(() {
      _scanning = true;
      _acceptedPeers.clear();
      _seenDeviceIds.clear();
      _status = 'Ищем устройства поблизости…';
    });
    _ctrl.repeat();
    await localHub.discoverAll();

    var ticks = 0;
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(const Duration(seconds: 3), (t) async {
      ticks++;
      if (ticks >= 5) {
        t.cancel();
        if (mounted) {
          setState(() {
            _scanning = false;
            _status = _acceptedPeers.isEmpty
                ? 'Пока никого не нашли'
                : '${_acceptedPeers.length} устройств рядом';
          });
        }
        return;
      }
      await localHub.discoverAll();
    });
  }

  Future<void> _respondToRequest(bool accept) async {
    final req = _incomingRequest;
    if (req == null) return;
    _respondedDeviceIds.add(req.deviceId);
    setState(() => _incomingRequest = null);
    if (accept) {
      _peerTransports.putIfAbsent(req.deviceId, () => {}).addAll(req.transports);
      await localHub.sendAccept(req.bestPeer);
      // sendAccept шлёт наш публичный ключ инициатору, но сами мы видим этот
      // peer только со стороны "кто-то постучался" — покажем его в своём же
      // списке сразу, не дожидаясь ответного onAccept (которого и не будет:
      // инициатор — не мы).
      _onAccepted(req.bestPeer);
    } else {
      appLog.info('lan', 'Запрос от ${req.deviceId} отклонён');
    }
  }

  Future<void> _blockStale(String deviceId) async {
    setState(() => _staleContactIds.remove(deviceId));
    localHub.blockDeviceId(deviceId);
    await LanSettings().addLanBlockedDevice(deviceId);
    appLog.info('lan', 'Старый контакт $deviceId заблокирован');
  }

  /// Восстанавливает ЗАПИСЬ чата (используя ключ, который транспорт ещё
  /// держит в памяти с прошлого раза) — НЕ переносит историю сообщений и НЕ
  /// перепроверяет identity заново (для этого нужен полноценный новый
  /// discover/accept-хендшейк). Если транспорт уже не помнит ключ (например,
  /// приложение перезапускалось) — просит подождать новый запрос от пира.
  Future<void> _restoreStale(String deviceId) async {
    final key = localHub.getKey(deviceId);
    if (key == null) {
      setState(() => _staleContactIds.remove(deviceId));
      toast.show('Нет активной сессии с этим устройством — дождитесь нового запроса от него');
      return;
    }
    await LanChatStore.instance.createOrGetChat(
      deviceId: deviceId,
      displayName: deviceId.length > 8 ? '${deviceId.substring(0, 8)}…' : deviceId,
      peerPubB64: base64Encode(key),
    );
    setState(() => _staleContactIds.remove(deviceId));
  }

  Widget _staleContactCard(String deviceId) {
    final label = deviceId.length > 8 ? '${deviceId.substring(0, 8)}…' : deviceId;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(Icons.history_toggle_off_rounded, color: GE.yellow, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Сигнал от $label',
                    style: TextStyle(color: GE.text, fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('Чат с этим устройством был удалён, но оно всё ещё на связи',
                    style: TextStyle(color: GE.sub, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.block, color: GE.red, size: 18),
            tooltip: 'Заблокировать',
            onPressed: () => _blockStale(deviceId),
          ),
          IconButton(
            icon: Icon(Icons.restore, color: GE.green, size: 20),
            tooltip: 'Восстановить подключение',
            onPressed: () => _restoreStale(deviceId),
          ),
        ],
      ),
    );
  }

  Future<void> _blockRequest() async {
    final req = _incomingRequest;
    if (req == null) return;
    _respondedDeviceIds.add(req.deviceId);
    setState(() => _incomingRequest = null);
    localHub.blockDeviceId(req.deviceId);
    await LanSettings().addLanBlockedDevice(req.deviceId);
    appLog.info('lan', 'Устройство ${req.deviceId} заблокировано');
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(child: _scaffold(context));
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(
        showBack: true,
        titleText: 'Устройства поблизости',
        actions: [
          IconButton(
            icon: Icon(Icons.settings_outlined, color: GE.sub),
            tooltip: 'Настройки приложения',
            onPressed: openAppSettings,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          if (!_wifiConnected || !_btOn) _warnings(),
          const SizedBox(height: 8),
          _ipRow(),
          const SizedBox(height: 8),
          _radar(),
          const SizedBox(height: 14),
          Text(
            _status,
            textAlign: TextAlign.center,
            style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 14),
          _legend(),
          const SizedBox(height: 18),
          if (_collectingPeer != null) ...[
            _collectingCard(_collectingPeer!),
            const SizedBox(height: 14),
          ] else if (_incomingRequest != null) ...[
            _incomingRequestCard(_incomingRequest!),
            const SizedBox(height: 14),
          ],
          for (final id in _staleContactIds) ...[
            _staleContactCard(id),
            const SizedBox(height: 14),
          ],
          _peersList(),
        ],
      ),
    );
  }

  Widget _warnings() {
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_wifiConnected)
            Row(children: [
              Icon(Icons.wifi_off, size: 15, color: GE.yellow),
              const SizedBox(width: 8),
              Expanded(child: Text('Wi-Fi не подключён — LAN-поиск недоступен',
                  style: TextStyle(color: GE.yellow, fontSize: 12))),
            ]),
          if (!_wifiConnected && !_btOn) const SizedBox(height: 4),
          if (!_btOn)
            Row(children: [
              Icon(Icons.bluetooth_disabled, size: 15, color: GE.yellow),
              const SizedBox(width: 8),
              Expanded(child: Text('Bluetooth выключен — BLE-поиск недоступен',
                  style: TextStyle(color: GE.yellow, fontSize: 12))),
            ]),
        ],
      ),
    );
  }

  Widget _ipRow() {
    final standard = LanSettings().standardIp;
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.lan_outlined, size: 15, color: GE.sub),
          const SizedBox(width: 8),
          Text('Мой IP: ', style: TextStyle(color: GE.sub, fontSize: 12)),
          Expanded(
            child: Text(
              _showIp ? (_myIp.isNotEmpty ? _myIp : 'нет Wi-Fi') : '••••••••••',
              style: TextStyle(
                color: _myIp.isEmpty ? GE.red : GE.text,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              standard.isNotEmpty ? Icons.check_circle : Icons.check_circle_outline,
              size: 18,
              color: standard.isNotEmpty ? GE.green : GE.sub,
            ),
            tooltip: 'Стандартный IP',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: _toggleStandardIp,
          ),
          IconButton(
            icon: Icon(_showIp ? Icons.visibility : Icons.visibility_off, size: 18, color: GE.sub),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => setState(() => _showIp = !_showIp),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleStandardIp() async {
    if (_myIp.isEmpty) return;
    if (LanSettings().standardIp.isNotEmpty) {
      await LanSettings().clearStandardIp();
    } else {
      await LanSettings().setStandardIp(_myIp);
    }
    if (mounted) setState(() {});
  }

  Widget _radar() {
    return Center(
      child: SizedBox(
        width: 260,
        height: 260,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Мягкое стеклянное пятно под радаром — размытие фона с
            // растворяющимися краями, чтобы кольца не сливались с mesh-фоном.
            IgnorePointer(
              child: ShaderMask(
                shaderCallback: (rect) => const RadialGradient(
                  colors: [Colors.white, Colors.white, Colors.transparent],
                  stops: [0.0, 0.5, 1.0],
                ).createShader(rect),
                blendMode: BlendMode.dstIn,
                child: ClipOval(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: Container(color: GE.bg.withValues(alpha: 0.4)),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 200,
              height: 200,
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (_, _) {
                  return CustomPaint(
                    painter: _RadarPainter(
                      progress: _ctrl.value,
                      color: GE.primary,
                      scanning: _scanning,
                    ),
                    child: Center(
                      child: GestureDetector(
                        onTap: (_starting || _scanning) ? null : _startScan,
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: GE.primary.withValues(alpha: _scanning ? 0.24 : 0.55),
                            border: Border.all(color: GE.primary, width: 1.4),
                          ),
                          child: Icon(
                            _starting
                                ? Icons.hourglass_top
                                : (_scanning ? Icons.wifi_tethering : Icons.search_rounded),
                            color: Colors.white,
                            size: 26,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend() {
    return Row(
      children: [
        _legendChip(Icons.wifi, 'LAN',
            active: localHub.startedTransports.contains(TransportType.lan) && _wifiConnected),
        const SizedBox(width: 8),
        _legendChip(Icons.wifi_tethering, 'Wi-Fi Direct',
            active: localHub.startedTransports.contains(TransportType.wifiDirect)),
        const SizedBox(width: 8),
        _legendChip(Icons.bluetooth, 'Bluetooth',
            active: localHub.startedTransports.contains(TransportType.bluetooth) && _btOn),
      ],
    );
  }

  Widget _legendChip(IconData icon, String label, {required bool active}) {
    final c = active ? GE.primary : GE.sub;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: active ? 0.14 : 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withValues(alpha: active ? 0.4 : 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: c, fontSize: 11)),
          if (!active) ...[
            const SizedBox(width: 3),
            Icon(Icons.close, size: 10, color: c),
          ],
        ],
      ),
    );
  }

  /// Сигнал(ы) от нового устройства ещё собираются (окно 5 сек, продлевается
  /// каждым новым сигналом) — узнаём ВСЕ способы связи, прежде чем
  /// предлагать принять/отклонить.
  Widget _collectingCard(LocalPeer peer) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          SizedBox(
            width: 22, height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: GE.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Подождите…',
                    style: TextStyle(color: GE.text, fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('Собираем способы связи с ${peer.label}',
                    style: TextStyle(color: GE.sub, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _incomingRequestCard(LocalGroupedRequest req) {
    return GlassCard(
      glow: true,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(shape: BoxShape.circle, color: GE.primary.withValues(alpha: 0.18)),
            child: Icon(Icons.person_add_alt_1, color: GE.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${req.label} хочет подключиться',
                    style: TextStyle(color: GE.text, fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(req.transports.map(transportLabel).join(', '),
                    style: TextStyle(color: GE.sub, fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(Icons.block, color: GE.red, size: 18),
            tooltip: 'Заблокировать',
            onPressed: _blockRequest,
          ),
          IconButton(
            icon: Icon(Icons.close, color: GE.sub, size: 20),
            onPressed: () => _respondToRequest(false),
          ),
          IconButton(
            icon: Icon(Icons.check_circle, color: GE.green, size: 24),
            onPressed: () => _respondToRequest(true),
          ),
        ],
      ),
    );
  }

  Widget _peersList() {
    // Список берём из БД (LanChatStore), а не из сессионного _acceptedPeers —
    // все устройства, с кем когда-либо обменялись рукопожатием, должны
    // оставаться здесь, а не пропадать при закрытии экрана.
    return ValueListenableBuilder<List<LanKnownDevice>>(
      valueListenable: LanChatStore.instance.knownDevicesNotifier,
      builder: (_, known, _) {
        if (known.isEmpty) {
          // Уже показана карточка "Подождите..." или "хочет подключиться"
          // выше — не дублируем "устройства не найдены" одновременно с ней.
          if (_collectingPeer != null || _incomingRequest != null || _staleContactIds.isNotEmpty) {
            return const SizedBox.shrink();
          }
          return GlassCard(
            lite: true,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
            child: Column(
              children: [
                Icon(Icons.devices_other, color: GE.sub, size: 30),
                const SizedBox(height: 10),
                Text('Устройства не найдены',
                    style: TextStyle(color: GE.text, fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  'Нажмите на радар, чтобы начать поиск.\nНайденные устройства появятся здесь.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GE.sub, fontSize: 11, height: 1.4),
                ),
              ],
            ),
          );
        }
        return Column(
          children: known.map((d) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _peerTile(d),
          )).toList(),
        );
      },
    );
  }

  TransportType _parseTransport(String s) {
    switch (s) {
      case 'wifi_direct': return TransportType.wifiDirect;
      case 'bluetooth':   return TransportType.bluetooth;
      default:            return TransportType.lan;
    }
  }

  /// Только что / Xм / Xч / Xд / дата — насколько давно было принято.
  String _relativeAcceptedTime(int? acceptedAtSec) {
    if (acceptedAtSec == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(acceptedAtSec * 1000);
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Только что';
    if (diff.inMinutes < 60) return '${diff.inMinutes} м';
    if (diff.inHours < 24) return '${diff.inHours} ч';
    if (diff.inDays < 7) return '${diff.inDays} д';
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year.toString().substring(2)}';
  }

  Widget _peerTile(LanKnownDevice device) {
    final baseTransport = _parseTransport(device.transport);
    IconData icon;
    switch (baseTransport) {
      case TransportType.lan:        icon = Icons.wifi; break;
      case TransportType.wifiDirect: icon = Icons.wifi_tethering; break;
      case TransportType.bluetooth:  icon = Icons.bluetooth; break;
    }
    final name = device.displayName;
    // Живые данные из пинга (если уже были) поверх того, что видели при
    // обнаружении/принятии — полный список способов связи, а не один.
    final methods = {
      ...(_peerTransports[device.deviceId] ?? const {}),
      ...(localHub.availableTransportsFor(device.deviceId) ?? const {}),
    };
    if (methods.isEmpty) methods.add(baseTransport);
    final pingMs = localHub.getPingMs(device.deviceId);
    final online = localHub.isOnline(device.deviceId);
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LanChatScreen(deviceId: device.deviceId, displayName: name),
      )),
      child: Row(
        children: [
          Stack(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: GE.green.withValues(alpha: 0.16),
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: TextStyle(color: GE.green, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              Positioned(
                right: -2, bottom: -2,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(color: GE.bg, shape: BoxShape.circle),
                  child: Icon(icon, size: 12, color: GE.primary),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: TextStyle(color: GE.text, fontWeight: FontWeight.w600, fontSize: 14)),
                Text(
                  online && pingMs != null
                      ? '${methods.map(transportLabel).join(' · ')} · $pingMs мс'
                      : methods.map(transportLabel).join(' · '),
                  style: TextStyle(color: GE.sub, fontSize: 11),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: GE.green.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('Принято ${_relativeAcceptedTime(device.acceptedAt)}',
                style: TextStyle(color: GE.green, fontSize: 10, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ── Художник радара ───────────────────────────────────────────────────
class _RadarPainter extends CustomPainter {
  final double progress; // 0..1
  final Color color;
  final bool scanning;

  _RadarPainter({
    required this.progress,
    required this.color,
    required this.scanning,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.18);
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(center, maxR * i / 3, ring);
    }

    const waves = 3;
    for (var i = 0; i < waves; i++) {
      final t = (progress + i / waves) % 1.0;
      final r = maxR * t;
      final alpha = (1 - t) * (scanning ? 0.45 : 0.22);
      if (alpha <= 0) continue;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color.withValues(alpha: alpha),
      );
    }

    if (scanning) {
      final sweepStart = progress * 2 * math.pi;
      const sweepWidth = math.pi / 3; // 60°
      final rect = Rect.fromCircle(center: center, radius: maxR);
      final sweep = Paint()
        ..shader = SweepGradient(
          startAngle: sweepStart,
          endAngle: sweepStart + sweepWidth,
          colors: [
            color.withValues(alpha: 0.0),
            color.withValues(alpha: 0.35),
          ],
          stops: const [0.0, 1.0],
          transform: const GradientRotation(0),
        ).createShader(rect);
      canvas.drawArc(rect, sweepStart, sweepWidth, true, sweep);
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.progress != progress ||
      old.scanning != scanning ||
      old.color != color;
}
