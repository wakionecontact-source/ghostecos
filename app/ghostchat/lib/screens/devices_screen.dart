// DevicesScreen — список всех устройств, через которые входили в аккаунт.
// Показывает: имя, платформу, last_seen, owner-флаг, кнопку Revoke.
// «Это устройство» помечено отдельно.
//
// ПИЛОТ WS-RPC: весь экран говорит с сервером через WsClient.call(...)
// (devices.list/rename/revoke, tda.get/set, tda.pending.list/approve/deny),
// без единого HTTP-запроса. Сокет подключается лениво — первый .call()
// сам его откроет, если ещё не открыт.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../services/auth_service.dart';
import '../services/theme_service.dart';
import '../services/ws_client.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';
import '../services/optimistic_action.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final _ws = WsClient.instance;
  List<Map<String, dynamic>> _devices = [];
  List<Map<String, dynamic>> _pending = [];
  String? _myDeviceId;
  bool _loading = true;
  String? _error;
  bool _tdaEnabled = false;
  bool _tdaBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _myDeviceId = await AuthService.deviceId();
      final results = await Future.wait([
        _ws.call('devices.list'),
        _ws.call('tda.pending.list'),
        _ws.call('tda.get'),
      ]);
      if (!mounted) return;
      final r = results[0];
      final rp = results[1];
      final rt = results[2];
      List<Map<String, dynamic>> list = [];
      if (r['devices'] is List) {
        list = (r['devices'] as List)
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      }
      List<Map<String, dynamic>> pending = [];
      if (rp['pending'] is List) {
        pending = (rp['pending'] as List)
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      }
      setState(() {
        _devices = list;
        _pending = pending;
        _tdaEnabled = rt['enabled'] == true;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _toggleTda(bool v) async {
    setState(() => _tdaBusy = true);
    try {
      await _ws.call('tda.set', {'enabled': v});
      if (!mounted) return;
      setState(() => _tdaEnabled = v);
      _snack(v
          ? 'Теперь новые устройства нужно подтверждать'
          : 'Подтверждение новых устройств выключено');
    } catch (e) {
      _snack('Не удалось изменить: $e');
    } finally {
      if (mounted) setState(() => _tdaBusy = false);
    }
  }

  Future<void> _approvePending(Map<String, dynamic> p) async {
    final code = await _promptCode(p['device_name'] as String? ?? 'устройство');
    if (code == null || code.length != 6) return;
    try {
      await _ws.call('tda.approve', {
        'login_request_id': p['request_id'],
        'code': code,
      });
      _snack('Устройство подтверждено');
      _load();
    } catch (e) {
      _snack('Не подошло: $e');
    }
  }

  Future<void> _denyPending(Map<String, dynamic> p) async {
    try {
      await _ws.call('tda.deny', {'login_request_id': p['request_id']});
      _snack('Вход отклонён');
      _load();
    } catch (e) {
      _snack('Ошибка: $e');
    }
  }

  Future<String?> _promptCode(String deviceName) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Код с «$deviceName»', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: TextStyle(color: GE.text, fontSize: 22, letterSpacing: 6),
          decoration: const InputDecoration(counterText: '', hintText: '••••••'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text('Подтвердить', style: TextStyle(color: GE.primary))),
        ],
      ),
    );
  }

  Future<void> _revoke(Map<String, dynamic> d) async {
    final isThis = d['device_id'] == _myDeviceId;
    if (isThis) {
      _snack('Это устройство — выйди через "Выйти из аккаунта"');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Отозвать устройство?',
            style: TextStyle(color: GE.text)),
        content: Text(
          'Устройство "${d['device_name']}" больше не сможет работать с аккаунтом. '
          'Если потребуется — нужно будет заново войти.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('Отозвать', style: TextStyle(color: GE.red))),
        ],
      ),
    );
    if (ok != true) return;
    final i = _devices.indexOf(d);
    try {
      await optimisticAction(
        apply: () => setState(() => _devices.removeAt(i)),
        request: () async => _ws.call('devices.revoke', {'device_pk': d['id']}),
        undo: () => setState(() => _devices.insert(i.clamp(0, _devices.length), d)),
        failureMessage: 'Не удалось отозвать устройство',
      );
      _snack('Устройство отозвано');
    } catch (_) {
      // no-op — уже отработано в optimisticAction
    }
  }

  void _snack(String msg) => toast.show(msg);

  @override
  Widget build(BuildContext context) {
    return MeshBackground(child: _scaffold(context));
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(showBack: true, titleText: 'Устройства'),
      body: RefreshIndicator(
        color: GE.primary,
        onRefresh: _load,
        child: _loading
            ? Center(child: CircularProgressIndicator(color: GE.primary))
            : _error != null
                ? ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      const SizedBox(height: 60),
                      Center(
                        child: GlassCard(
                          lite: true,
                          padding: const EdgeInsets.all(20),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.error_outline, color: GE.red, size: 32),
                            const SizedBox(height: 8),
                            Text('Не загрузилось',
                                style: TextStyle(color: GE.text, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            Text(_error!,
                                textAlign: TextAlign.center,
                                style: TextStyle(color: GE.sub, fontSize: 11)),
                          ]),
                        ),
                      ),
                    ],
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(10, 12, 10, 80),
                    children: [
                      _tdaCard(),
                      const SizedBox(height: 10),
                      if (_pending.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                          child: Text('ОЖИДАЮТ ПОДТВЕРЖДЕНИЯ',
                              style: TextStyle(
                                  color: GE.yellow,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5)),
                        ),
                        for (final p in _pending) ...[
                          _PendingTile(
                            p: p,
                            onApprove: () => _approvePending(p),
                            onDeny: () => _denyPending(p),
                          ),
                          const SizedBox(height: 6),
                        ],
                        const SizedBox(height: 8),
                      ],
                      _info(),
                      for (final d in _devices) ...[
                        _DeviceTile(
                          d: d,
                          isMe: d['device_id'] == _myDeviceId,
                          onRevoke: () => _revoke(d),
                        ),
                        const SizedBox(height: 6),
                      ],
                    ],
                  ),
      ),
    );
  }

  Widget _tdaCard() {
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.verified_user_outlined, color: GE.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Подтверждать новые устройства',
                    style: TextStyle(
                        color: GE.text, fontSize: 13, fontWeight: FontWeight.w600)),
                Text('Вход с незнакомого устройства потребует код с доверенного',
                    style: TextStyle(color: GE.sub, fontSize: 10.5, height: 1.3)),
              ],
            ),
          ),
          _tdaBusy
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: GE.primary))
              : GhostSwitch(
                  value: _tdaEnabled,
                  activeColor: GE.primary,
                  onChanged: _toggleTda,
                ),
        ],
      ),
    );
  }

  Widget _info() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        'Каждое устройство получает свой токен. Создатель аккаунта не может '
        'быть отозван и помечен сверху списка.',
        style: TextStyle(color: GE.sub, fontSize: 11, height: 1.4),
      ),
    );
  }
}

class _PendingTile extends StatelessWidget {
  final Map<String, dynamic> p;
  final VoidCallback onApprove;
  final VoidCallback onDeny;
  const _PendingTile({required this.p, required this.onApprove, required this.onDeny});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.devices_other, color: GE.yellow, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text((p['device_name'] as String?) ?? 'Устройство',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: GE.text, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            icon: Icon(Icons.close, color: GE.red, size: 20),
            tooltip: 'Отклонить',
            onPressed: onDeny,
          ),
          IconButton(
            icon: Icon(Icons.check, color: GE.green, size: 20),
            tooltip: 'Подтвердить',
            onPressed: onApprove,
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final Map<String, dynamic> d;
  final bool isMe;
  final VoidCallback onRevoke;
  const _DeviceTile({required this.d, required this.isMe, required this.onRevoke});

  IconData _platformIcon(String? p) {
    switch (p) {
      case 'android': return Icons.android;
      case 'ios': return Icons.phone_iphone;
      case 'windows': return Icons.laptop_windows;
      case 'macos': return Icons.laptop_mac;
      case 'linux': return Icons.laptop_chromebook;
      case 'web': return Icons.public;
      default: return Icons.devices_other;
    }
  }

  String _fmtLastSeen(dynamic ts) {
    if (ts == null) return '';
    try {
      final dt = DateTime.fromMillisecondsSinceEpoch(
          ((ts as num).toInt()) * 1000, isUtc: true);
      final s = DateTime.now().toUtc().difference(dt).inSeconds;
      if (s < 60) return 'только что';
      if (s < 3600) return '${s ~/ 60} мин назад';
      if (s < 86400) return '${s ~/ 3600} ч назад';
      if (s < 7 * 86400) return '${s ~/ 86400} д назад';
      return DateFormat('dd.MM.yyyy').format(dt.toLocal());
    } catch (_) { return ''; }
  }

  @override
  Widget build(BuildContext context) {
    final isOwner = d['is_owner'] == 1 || d['is_owner'] == true;
    final isActive = d['is_active'] == 1 || d['is_active'] == true;
    final vpn = d['vpn_detected'] == 1 || d['vpn_detected'] == true;
    final level = (d['level'] as num?)?.toInt() ?? 1;
    return GlassCard(
      lite: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isOwner ? GE.primary.withValues(alpha: 0.22) : GE.glassFill,
              border: ThemeService.isMinimal
                  ? null
                  : Border.all(
                      color: isOwner ? GE.primary : GE.glassBorder, width: 1),
            ),
            child: Icon(_platformIcon(d['platform'] as String?),
                color: isOwner ? GE.primary : GE.sub, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text((d['device_name'] as String?) ?? '?',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: GE.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: GE.green.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text('Это устройство',
                          style: TextStyle(color: GE.green, fontSize: 9, fontWeight: FontWeight.w700)),
                    ),
                  ],
                  if (isOwner) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: GE.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text('Создатель',
                          style: TextStyle(color: GE.primary, fontSize: 9, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ]),
                const SizedBox(height: 2),
                Text(
                  // Создателю не показываем «Уровень 999999» — сервер хранит
                  // для него sentinel-значение, но бейдж «Создатель» и так
                  // говорит о максимальных правах (см. 1.19.3: trust_type==
                  // 'creator' ? 999 : trust_level — там тоже был спец-кейс).
                  '${isOwner ? '' : 'Уровень $level · '}${_fmtLastSeen(d['last_seen'])}'
                  '${vpn ? ' · VPN' : ''}'
                  '${!isActive ? ' · отозвано' : ''}',
                  style: TextStyle(color: GE.sub, fontSize: 11),
                ),
              ],
            ),
          ),
          if (isActive && !isOwner && !isMe)
            IconButton(
              icon: Icon(Icons.logout, color: GE.red, size: 18),
              tooltip: 'Отозвать',
              onPressed: onRevoke,
            ),
        ],
      ),
    );
  }
}
