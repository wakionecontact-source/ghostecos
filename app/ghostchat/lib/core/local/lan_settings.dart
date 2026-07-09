import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'local_transport.dart';

/// Настройки LAN/BLE/WiFi-Direct обнаружения устройств поблизости.
/// Отдельно от основного AppSettings/ThemeService этого приложения —
/// хранит только то, что нужно транспортам из core/local.
class LanSettings {
  static final LanSettings _i = LanSettings._();
  factory LanSettings() => _i;
  LanSettings._();

  bool lanAcceptRequests   = true;
  bool lanAcceptWifi       = true;
  bool lanAcceptWifiDirect = true;
  bool lanAcceptBluetooth  = true;
  bool lanPingEnabled      = true;
  String standardIp        = '';

  // Default: bluetooth > wifi_direct > lan
  List<TransportType> lanTransportPriority = [
    TransportType.bluetooth,
    TransportType.wifiDirect,
    TransportType.lan,
  ];

  List<String> lanBlockedDevices = [];

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    lanAcceptRequests   = p.getBool('lan_accept_requests')    ?? true;
    lanAcceptWifi       = p.getBool('lan_accept_wifi')        ?? true;
    lanAcceptWifiDirect = p.getBool('lan_accept_wifi_direct') ?? true;
    lanAcceptBluetooth  = p.getBool('lan_accept_bluetooth')   ?? true;
    lanPingEnabled      = p.getBool('lan_ping_enabled')       ?? true;
    standardIp          = p.getString('lan_standard_ip')      ?? '';

    final priorityJson = p.getString('lan_transport_priority');
    if (priorityJson != null) {
      try {
        final names = List<String>.from(jsonDecode(priorityJson));
        lanTransportPriority = names.map((n) {
          switch (n) {
            case 'bluetooth':  return TransportType.bluetooth;
            case 'wifiDirect': return TransportType.wifiDirect;
            default:           return TransportType.lan;
          }
        }).toList();
      } catch (_) {}
    }

    final blockedJson = p.getString('lan_blocked_devices');
    if (blockedJson != null) {
      try {
        lanBlockedDevices = List<String>.from(jsonDecode(blockedJson));
      } catch (_) {}
    }
    _loaded = true;
  }

  bool isLanTransportEnabled(TransportType type) {
    if (!lanAcceptRequests) return false;
    switch (type) {
      case TransportType.lan:        return lanAcceptWifi;
      case TransportType.wifiDirect: return lanAcceptWifiDirect;
      case TransportType.bluetooth:  return lanAcceptBluetooth;
    }
  }

  bool isLanDeviceBlocked(String deviceId) => lanBlockedDevices.contains(deviceId);

  Future<void> addLanBlockedDevice(String deviceId) async {
    if (!lanBlockedDevices.contains(deviceId)) {
      lanBlockedDevices.add(deviceId);
      await _saveBlocked();
    }
  }

  Future<void> removeLanBlockedDevice(String deviceId) async {
    if (lanBlockedDevices.remove(deviceId)) {
      await _saveBlocked();
    }
  }

  Future<void> _saveBlocked() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('lan_blocked_devices', jsonEncode(lanBlockedDevices));
  }

  Future<void> setLanAcceptRequests(bool v) async {
    lanAcceptRequests = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('lan_accept_requests', v);
  }

  Future<void> setLanAcceptWifi(bool v) async {
    lanAcceptWifi = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('lan_accept_wifi', v);
  }

  Future<void> setLanAcceptWifiDirect(bool v) async {
    lanAcceptWifiDirect = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('lan_accept_wifi_direct', v);
  }

  Future<void> setLanAcceptBluetooth(bool v) async {
    lanAcceptBluetooth = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('lan_accept_bluetooth', v);
  }

  Future<void> setLanPingEnabled(bool v) async {
    lanPingEnabled = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('lan_ping_enabled', v);
  }

  Future<void> setLanTransportPriority(List<TransportType> order) async {
    lanTransportPriority = order;
    final p = await SharedPreferences.getInstance();
    await p.setString(
      'lan_transport_priority',
      jsonEncode(order.map((t) => t.name).toList()),
    );
  }

  Future<void> setStandardIp(String ip) async {
    standardIp = ip;
    final p = await SharedPreferences.getInstance();
    await p.setString('lan_standard_ip', ip);
  }

  Future<void> clearStandardIp() async {
    standardIp = '';
    final p = await SharedPreferences.getInstance();
    await p.remove('lan_standard_ip');
  }
}
