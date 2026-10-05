// LanSettingsScreen — настройки LAN/BLE/Wi-Fi Direct (перенесено из 1.19.3,
// дизайн Ghost). Приём запросов, приоритет транспортов, блокировки.
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../core/local/lan_settings.dart';
import '../core/local/local_transport.dart';
import '../services/theme_service.dart';

class LanSettingsScreen extends StatefulWidget {
  const LanSettingsScreen({super.key});
  @override
  State<LanSettingsScreen> createState() => _LanSettingsScreenState();
}

class _LanSettingsScreenState extends State<LanSettingsScreen> {
  final _settings = LanSettings();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _settings.load().then((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  String _label(TransportType t) {
    switch (t) {
      case TransportType.bluetooth:
        return 'Bluetooth';
      case TransportType.wifiDirect:
        return 'Wi-Fi Direct';
      case TransportType.lan:
        return 'Wi-Fi (LAN)';
    }
  }

  IconData _icon(TransportType t) {
    switch (t) {
      case TransportType.bluetooth:
        return CupertinoIcons.bluetooth;
      case TransportType.wifiDirect:
        return CupertinoIcons.antenna_radiowaves_left_right;
      case TransportType.lan:
        return CupertinoIcons.wifi;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: true, titleText: 'LAN-чаты'),
        body: _loading
            ? const SizedBox.shrink()
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  GlassCard(
                    isListSection: true,
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: Text(
                            'Принимать запросы',
                            style: TextStyle(
                              color: GE.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle:
                              ThemeService.instance.showDetailedDescriptions
                              ? Text(
                                  'Выключено — новые входящие запросы на подключение игнорируются',
                                  style: TextStyle(
                                    color: GE.sub,
                                    fontSize: 11.5,
                                  ),
                                )
                              : null,
                          value: _settings.lanAcceptRequests,
                          activeThumbColor: GE.primary,
                          onChanged: (v) async {
                            await _settings.setLanAcceptRequests(v);
                            setState(() {});
                          },
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          child: _settings.lanAcceptRequests
                              ? Column(
                                  children: [
                                    Divider(
                                      height: 1,
                                      color: GE.glassBorder,
                                      indent: 16,
                                    ),
                                    SwitchListTile(
                                      dense: true,
                                      secondary: Icon(
                                        CupertinoIcons.wifi,
                                        color: GE.sub,
                                        size: 20,
                                      ),
                                      title: Text(
                                        'Wi-Fi (LAN)',
                                        style: TextStyle(
                                          color: GE.text,
                                          fontSize: 13,
                                        ),
                                      ),
                                      value: _settings.lanAcceptWifi,
                                      activeThumbColor: GE.primary,
                                      onChanged: (v) async {
                                        await _settings.setLanAcceptWifi(v);
                                        setState(() {});
                                      },
                                    ),
                                    Divider(
                                      height: 1,
                                      color: GE.glassBorder,
                                      indent: 16,
                                    ),
                                    SwitchListTile(
                                      dense: true,
                                      secondary: Icon(
                                        CupertinoIcons
                                            .antenna_radiowaves_left_right,
                                        color: GE.sub,
                                        size: 20,
                                      ),
                                      title: Text(
                                        'Wi-Fi Direct',
                                        style: TextStyle(
                                          color: GE.text,
                                          fontSize: 13,
                                        ),
                                      ),
                                      value: _settings.lanAcceptWifiDirect,
                                      activeThumbColor: GE.primary,
                                      onChanged: (v) async {
                                        await _settings.setLanAcceptWifiDirect(
                                          v,
                                        );
                                        setState(() {});
                                      },
                                    ),
                                    Divider(
                                      height: 1,
                                      color: GE.glassBorder,
                                      indent: 16,
                                    ),
                                    SwitchListTile(
                                      dense: true,
                                      secondary: Icon(
                                        CupertinoIcons.bluetooth,
                                        color: GE.sub,
                                        size: 20,
                                      ),
                                      title: Text(
                                        'Bluetooth',
                                        style: TextStyle(
                                          color: GE.text,
                                          fontSize: 13,
                                        ),
                                      ),
                                      value: _settings.lanAcceptBluetooth,
                                      activeThumbColor: GE.primary,
                                      onChanged: (v) async {
                                        await _settings.setLanAcceptBluetooth(
                                          v,
                                        );
                                        setState(() {});
                                      },
                                    ),
                                  ],
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  GlassCard(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: SwitchListTile(
                      title: Text(
                        'Пинг (статус онлайн)',
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: ThemeService.instance.showDetailedDescriptions
                          ? Text(
                              'Каждые 10 сек проверяет доступность собеседника',
                              style: TextStyle(color: GE.sub, fontSize: 11.5),
                            )
                          : null,
                      value: _settings.lanPingEnabled,
                      activeThumbColor: GE.primary,
                      onChanged: (v) async {
                        await _settings.setLanPingEnabled(v);
                        setState(() {});
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.only(left: 8, bottom: 8),
                    child: Text(
                      'ПРИОРИТЕТ СОЕДИНЕНИЙ',
                      style: TextStyle(
                        color: GE.sub,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  GlassCard(
                    isListSection: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _settings.lanTransportPriority.length,
                      onReorder: (oldIndex, newIndex) async {
                        if (newIndex > oldIndex) newIndex--;
                        final list = List<TransportType>.from(
                          _settings.lanTransportPriority,
                        );
                        final item = list.removeAt(oldIndex);
                        list.insert(newIndex, item);
                        await _settings.setLanTransportPriority(list);
                        setState(() {});
                      },
                      itemBuilder: (ctx, i) {
                        final t = _settings.lanTransportPriority[i];
                        final last =
                            i == _settings.lanTransportPriority.length - 1;
                        return Column(
                          key: ValueKey(t),
                          children: [
                            ListTile(
                              leading: Icon(_icon(t), color: GE.sub),
                              title: Text(
                                _label(t),
                                style: TextStyle(color: GE.text, fontSize: 14),
                              ),
                              subtitle:
                                  ThemeService.instance.showDetailedDescriptions
                                  ? Text(
                                      i == 0
                                          ? 'Высший приоритет'
                                          : 'Приоритет ${i + 1}',
                                      style: TextStyle(
                                        color: GE.sub,
                                        fontSize: 11.5,
                                      ),
                                    )
                                  : null,
                              trailing: Icon(Icons.drag_handle, color: GE.sub),
                            ),
                            if (!last)
                              Divider(
                                height: 1,
                                color: GE.glassBorder,
                                indent: 16,
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 14),
                  GlassCard(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: ListTile(
                      leading: Icon(CupertinoIcons.nosign, color: GE.red),
                      title: Text(
                        'Заблокированные устройства',
                        style: TextStyle(color: GE.text, fontSize: 14),
                      ),
                      subtitle: ThemeService.instance.showDetailedDescriptions
                          ? Text(
                              '${_settings.lanBlockedDevices.length} устройств',
                              style: TextStyle(color: GE.sub, fontSize: 11.5),
                            )
                          : null,
                      trailing: Icon(
                        CupertinoIcons.chevron_right,
                        color: GE.sub,
                      ),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const LanBlockedScreen(),
                          ),
                        );
                        setState(() {});
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class LanBlockedScreen extends StatefulWidget {
  const LanBlockedScreen({super.key});
  @override
  State<LanBlockedScreen> createState() => _LanBlockedScreenState();
}

class _LanBlockedScreenState extends State<LanBlockedScreen> {
  final _settings = LanSettings();

  Future<void> _unblock(String deviceId) async {
    await _settings.removeLanBlockedDevice(deviceId);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _settings.lanBlockedDevices;
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: true, titleText: 'Заблокированные'),
        body: blocked.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.nosign, size: 44, color: GE.sub),
                      const SizedBox(height: 12),
                      Text(
                        'Нет заблокированных устройств',
                        style: TextStyle(color: GE.sub, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: blocked.length,
                itemBuilder: (_, i) {
                  final deviceId = blocked[i];
                  final label = deviceId.length > 12
                      ? '${deviceId.substring(0, 12)}…'
                      : deviceId;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: GlassCard(
                      lite: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 4,
                      ),
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          backgroundColor: GE.red.withValues(alpha: 0.16),
                          child: Icon(
                            CupertinoIcons.nosign,
                            color: GE.red,
                            size: 18,
                          ),
                        ),
                        title: Text(
                          label,
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 13,
                            fontFamily: 'monospace',
                          ),
                        ),
                        trailing: TextButton(
                          onPressed: () => _unblock(deviceId),
                          child: Text(
                            'Разблокировать',
                            style: TextStyle(color: GE.primary, fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
