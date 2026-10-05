// Настройка HTTP/SOCKS5-прокси для запросов приложения к серверу. Персист —
// SharedPreferences, тот же паттерн, что NavBarSettings/ThemeService.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Тип прокси для HTTP API и WebSocket-соединений GhostChat.
enum ProxyType { http, socks5 }

class NetworkSettings {
  NetworkSettings._();
  static final NetworkSettings instance = NetworkSettings._();

  static const _kEnabledKey = 'net_proxy_enabled_v1';
  static const _kHostKey = 'net_proxy_host_v1';
  static const _kPortKey = 'net_proxy_port_v1';
  static const _kTypeKey = 'net_proxy_type_v1';
  static const _kKeyKey = 'net_proxy_key_v1';
  static const _kCheckConnectionKey = 'net_check_connection_v1';

  final ValueNotifier<bool> enabledNotifier = ValueNotifier(false);
  final ValueNotifier<String> hostNotifier = ValueNotifier('');
  final ValueNotifier<int?> portNotifier = ValueNotifier(null);
  final ValueNotifier<ProxyType> typeNotifier = ValueNotifier(ProxyType.http);
  final ValueNotifier<bool> checkConnectionNotifier = ValueNotifier(true);

  /// Ключ/пароль авторизации на прокси (Proxy-Authorization) — необязательный.
  final ValueNotifier<String> authKeyNotifier = ValueNotifier('');

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enabledNotifier.value = prefs.getBool(_kEnabledKey) ?? false;
    hostNotifier.value = prefs.getString(_kHostKey) ?? '';
    portNotifier.value = prefs.getInt(_kPortKey);
    typeNotifier.value = prefs.getString(_kTypeKey) == 'socks5'
        ? ProxyType.socks5
        : ProxyType.http;
    authKeyNotifier.value = prefs.getString(_kKeyKey) ?? '';
    checkConnectionNotifier.value = prefs.getBool(_kCheckConnectionKey) ?? true;
  }

  Future<void> setCheckConnection(bool enabled) async {
    checkConnectionNotifier.value = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCheckConnectionKey, enabled);
  }

  Future<void> save({
    required bool enabled,
    required String host,
    int? port,
    required ProxyType type,
    required String authKey,
  }) async {
    enabledNotifier.value = enabled;
    hostNotifier.value = host;
    portNotifier.value = port;
    typeNotifier.value = type;
    authKeyNotifier.value = authKey;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, enabled);
    await prefs.setString(_kHostKey, host);
    if (port != null) {
      await prefs.setInt(_kPortKey, port);
    } else {
      await prefs.remove(_kPortKey);
    }
    await prefs.setString(
      _kTypeKey,
      type == ProxyType.socks5 ? 'socks5' : 'http',
    );
    await prefs.setString(_kKeyKey, authKey);
  }

  /// HTTP-правило для совместимого с dart:io findProxy.
  /// Для SOCKS5 используется отдельный connectionFactory.
  String? get proxyRule {
    if (!enabledNotifier.value || typeNotifier.value != ProxyType.http) {
      return null;
    }
    final host = hostNotifier.value.trim();
    final port = portNotifier.value;
    if (host.isEmpty || port == null) {
      return null;
    }
    return 'PROXY $host:$port';
  }
}
