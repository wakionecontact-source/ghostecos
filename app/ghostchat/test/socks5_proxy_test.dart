import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/socks5_proxy.dart';
import 'package:ghost/services/network_settings.dart';
import 'package:ghost/services/proxy_http_client.dart';

void main() {
  test('opens a SOCKS5 domain tunnel and passes bytes through it', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final served = Completer<void>();
    server.listen((socket) {
      _serveNoAuth(socket, served);
    });

    final socket = await Socks5Proxy.connect(
      proxyHost: InternetAddress.loopbackIPv4.address,
      proxyPort: server.port,
      destination: Uri.parse('http://hidden.example.test:8080'),
      timeout: const Duration(seconds: 3),
    );
    final reader = _TestReader(socket, const Duration(seconds: 3));
    socket.add(utf8.encode('ping'));
    await socket.flush();

    expect(utf8.decode(await reader.readExactly(4)), 'pong');
    await served.future;
    await reader.cancel();
    socket.destroy();
    await server.close();
  });

  test('supports SOCKS5 username/password authentication', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final served = Completer<void>();
    server.listen((socket) {
      _serveAuth(socket, served);
    });

    final socket = await Socks5Proxy.connect(
      proxyHost: InternetAddress.loopbackIPv4.address,
      proxyPort: server.port,
      destination: Uri.parse('http://hidden.example.test:8080'),
      username: 'alice',
      password: 'secret',
      timeout: const Duration(seconds: 3),
    );
    final reader = _TestReader(socket, const Duration(seconds: 3));
    socket.add(<int>[1, 2, 3]);
    await socket.flush();

    expect(await reader.readExactly(3), <int>[3, 2, 1]);
    await served.future;
    await reader.cancel();
    socket.destroy();
    await server.close();
  });

  test('routes dart HttpClient through SOCKS5', () async {
    final settings = NetworkSettings.instance;
    final oldEnabled = settings.enabledNotifier.value;
    final oldHost = settings.hostNotifier.value;
    final oldPort = settings.portNotifier.value;
    final oldType = settings.typeNotifier.value;
    final oldKey = settings.authKeyNotifier.value;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final served = Completer<void>();
    server.listen((socket) {
      _serveHttp(socket, served);
    });
    settings.enabledNotifier.value = true;
    settings.hostNotifier.value = InternetAddress.loopbackIPv4.address;
    settings.portNotifier.value = server.port;
    settings.typeNotifier.value = ProxyType.socks5;
    settings.authKeyNotifier.value = '';

    final client = ProxyHttpClient.create();
    try {
      final request = await client.getUrl(
        Uri.parse('http://hidden.example.test/probe'),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, 200);
      expect(body, 'ok');
      await served.future;
    } finally {
      client.close(force: true);
      settings.enabledNotifier.value = oldEnabled;
      settings.hostNotifier.value = oldHost;
      settings.portNotifier.value = oldPort;
      settings.typeNotifier.value = oldType;
      settings.authKeyNotifier.value = oldKey;
      await server.close();
    }
  });
}

Future<void> _serveNoAuth(Socket socket, Completer<void> done) async {
  final reader = _TestReader(socket, const Duration(seconds: 3));
  try {
    expect(await reader.readExactly(3), <int>[5, 1, 0]);
    socket.add(<int>[5, 0]);
    await socket.flush();

    final requestHead = await reader.readExactly(4);
    expect(requestHead, <int>[5, 1, 0, 3]);
    final domainLength = (await reader.readExactly(1))[0];
    expect(
      utf8.decode(await reader.readExactly(domainLength)),
      'hidden.example.test',
    );
    expect(await reader.readExactly(2), <int>[0x1f, 0x90]);
    socket.add(<int>[5, 0, 0, 1, 127, 0, 0, 1, 0, 1]);
    await socket.flush();

    expect(utf8.decode(await reader.readExactly(4)), 'ping');
    socket.add(utf8.encode('pong'));
    await socket.flush();
    done.complete();
  } catch (error, stack) {
    if (!done.isCompleted) done.completeError(error, stack);
  } finally {
    await reader.cancel();
    socket.destroy();
  }
}

Future<void> _serveAuth(Socket socket, Completer<void> done) async {
  final reader = _TestReader(socket, const Duration(seconds: 3));
  try {
    expect(await reader.readExactly(4), <int>[5, 2, 0, 2]);
    socket.add(<int>[5, 2]);
    await socket.flush();

    expect(await reader.readExactly(2), <int>[1, 5]);
    expect(utf8.decode(await reader.readExactly(5)), 'alice');
    expect(await reader.readExactly(1), <int>[6]);
    expect(utf8.decode(await reader.readExactly(6)), 'secret');
    socket.add(<int>[1, 0]);
    await socket.flush();

    expect(await reader.readExactly(4), <int>[5, 1, 0, 3]);
    final domainLength = (await reader.readExactly(1))[0];
    await reader.readExactly(domainLength);
    await reader.readExactly(2);
    socket.add(<int>[5, 0, 0, 1, 127, 0, 0, 1, 0, 1]);
    await socket.flush();

    expect(await reader.readExactly(3), <int>[1, 2, 3]);
    socket.add(<int>[3, 2, 1]);
    await socket.flush();
    done.complete();
  } catch (error, stack) {
    if (!done.isCompleted) done.completeError(error, stack);
  } finally {
    await reader.cancel();
    socket.destroy();
  }
}

Future<void> _serveHttp(Socket socket, Completer<void> done) async {
  final reader = _TestReader(socket, const Duration(seconds: 3));
  try {
    expect(await reader.readExactly(3), <int>[5, 1, 0]);
    socket.add(<int>[5, 0]);
    await socket.flush();

    expect(await reader.readExactly(4), <int>[5, 1, 0, 3]);
    final domainLength = (await reader.readExactly(1))[0];
    expect(
      utf8.decode(await reader.readExactly(domainLength)),
      'hidden.example.test',
    );
    expect(await reader.readExactly(2), <int>[0, 80]);
    socket.add(<int>[5, 0, 0, 1, 127, 0, 0, 1, 0, 1]);
    await socket.flush();

    final request = <int>[];
    while (!_endsWith(request, <int>[13, 10, 13, 10])) {
      request.add((await reader.readExactly(1))[0]);
    }
    expect(utf8.decode(request), contains('GET /probe HTTP/1.1'));
    socket.add(
      utf8.encode(
        'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok',
      ),
    );
    await socket.flush();
    done.complete();
  } catch (error, stack) {
    if (!done.isCompleted) done.completeError(error, stack);
  } finally {
    await reader.cancel();
    socket.destroy();
  }
}

bool _endsWith(List<int> bytes, List<int> suffix) {
  if (bytes.length < suffix.length) return false;
  for (var i = 0; i < suffix.length; i++) {
    if (bytes[bytes.length - suffix.length + i] != suffix[i]) return false;
  }
  return true;
}

class _TestReader {
  _TestReader(Socket socket, this._timeout)
    : _iterator = StreamIterator<List<int>>(socket);

  final StreamIterator<List<int>> _iterator;
  final Duration _timeout;
  final List<int> _buffer = <int>[];

  Future<List<int>> readExactly(int length) async {
    while (_buffer.length < length) {
      if (!await _iterator.moveNext().timeout(_timeout)) {
        throw const SocketException('test socket closed');
      }
      _buffer.addAll(_iterator.current);
    }
    final result = Uint8List.fromList(_buffer.take(length).toList());
    _buffer.removeRange(0, length);
    return result;
  }

  Future<void> cancel() => _iterator.cancel();
}
