import 'dart:io';

import 'network_settings.dart';
import 'socks5_proxy.dart';

/// Создаёт dart:io HttpClient с текущими настройками GhostChat.
///
/// Один и тот же фабричный путь используется Dio и WebSocket, чтобы чаты и
/// обычные API-запросы не расходились по маршруту.
class ProxyHttpClient {
  const ProxyHttpClient._();

  static HttpClient create() {
    final client = HttpClient()..idleTimeout = const Duration(seconds: 3);
    final settings = NetworkSettings.instance;
    if (!settings.enabledNotifier.value) return client;

    final host = settings.hostNotifier.value.trim();
    final port = settings.portNotifier.value;
    if (host.isEmpty || port == null) return client;

    final auth = _credentials(settings.authKeyNotifier.value.trim());
    if (settings.typeNotifier.value == ProxyType.http) {
      client.findProxy = (_) => 'PROXY $host:$port';
      if (auth.password.isNotEmpty || auth.username.isNotEmpty) {
        client.addProxyCredentials(
          host,
          port,
          '',
          HttpClientBasicCredentials(auth.username, auth.password),
        );
      }
      return client;
    }

    // Для SOCKS5 не даём HttpClient превратить соединение в HTTP CONNECT:
    // connectionFactory сначала делает SOCKS5 handshake, затем HttpClient
    // пишет обычный HTTP поверх уже подключённого сокета.
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, _, _) {
      Socket? socket;
      var cancelled = false;
      final future =
          Socks5Proxy.connect(
            proxyHost: host,
            proxyPort: port,
            destination: uri,
            username: auth.username,
            password: auth.password,
          ).then((connected) {
            socket = connected;
            if (cancelled) {
              connected.destroy();
              throw const SocketException('SOCKS5: подключение отменено');
            }
            return connected;
          });
      return Future.value(
        ConnectionTask.fromSocket<Socket>(future, () {
          cancelled = true;
          socket?.destroy();
        }),
      );
    };
    return client;
  }

  static _ProxyCredentials _credentials(String value) {
    if (value.isEmpty) return const _ProxyCredentials('', '');
    final separator = value.indexOf(':');
    if (separator > 0) {
      return _ProxyCredentials(
        value.substring(0, separator),
        value.substring(separator + 1),
      );
    }
    // Старый формат поля — одиночный ключ/пароль с пустым логином.
    return _ProxyCredentials('', value);
  }
}

class _ProxyCredentials {
  const _ProxyCredentials(this.username, this.password);

  final String username;
  final String password;
}
