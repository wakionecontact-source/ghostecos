// DevicesScreen — список всех устройств, через которые входили в аккаунт.
// Показывает: имя, платформу, last_seen, owner-флаг, кнопку Revoke.
// «Это устройство» помечено отдельно.
//
// Endpoints: GET /api/soc/device/list, POST /api/soc/device/{id}/revoke

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../theme.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../widgets/glass.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final _api = ApiClient();
  List<Map<String, dynamic>> _devices = [];
  String? _myDeviceId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _myDeviceId = await AuthService.deviceId();
      final r = await _api.socGet('/device/list');
      if (!mounted) return;
      List<Map<String, dynamic>> list = [];
      if (r is Map && r['devices'] is List) {
        list = (r['devices'] as List)
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
      }
      setState(() {
        _devices = list;
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

  Future<void> _revoke(Map<String, dynamic> d) async {
    final isThis = d['device_id'] == _myDeviceId;
    if (isThis) {
      _snack('Это устройство — выйди через "Выйти из аккаунта"');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
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
    try {
      await _api.socPost('/device/${d['id']}/revoke');
      await _load();
      _snack('Устройство отозвано');
    } catch (e) {
      _snack('Не удалось: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(10, 12, 10, 80),
                    itemCount: _devices.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (_, i) {
                      if (i == 0) return _info();
                      return _DeviceTile(
                        d: _devices[i - 1],
                        isMe: _devices[i - 1]['device_id'] == _myDeviceId,
                        onRevoke: () => _revoke(_devices[i - 1]),
                      );
                    },
                  ),
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
              border: Border.all(
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
                  'Уровень $level · ${_fmtLastSeen(d['last_seen'])}'
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
