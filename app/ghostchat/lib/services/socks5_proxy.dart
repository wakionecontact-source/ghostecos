import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Минимальная реализация SOCKS5 CONNECT (RFC 1928/1929).
///
/// Доменные имена передаются самому SOCKS5-серверу, поэтому DNS для целевого
/// адреса не выполняется локально. Авторизация поддерживает либо только пароль
/// (пустой логин), либо пару в формате `логин:пароль`.
class Socks5Proxy {
  const Socks5Proxy._();

  static Future<Socket> connect({
    required String proxyHost,
    required int proxyPort,
    required Uri destination,
    String username = '',
    String password = '',
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final socket = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
    final session = _Socks5Session(socket, timeout);

    try {
      final hasCredentials = username.isNotEmpty || password.isNotEmpty;
      final methods = <int>[0x00];
      if (hasCredentials) methods.add(0x02);
      await _write(socket, <int>[0x05, methods.length, ...methods]);

      final greeting = await session.readExactly(2);
      if (greeting[0] != 0x05) {
        throw const FormatException('SOCKS5: неверная версия ответа');
      }
      final method = greeting[1];
      if (method == 0xff) {
        throw const SocketException(
          'SOCKS5: сервер отклонил способы авторизации',
        );
      }

      if (method == 0x02) {
        if (!hasCredentials) {
          throw const SocketException('SOCKS5: сервер требует авторизацию');
        }
        final user = utf8.encode(username);
        final pass = utf8.encode(password);
        if (user.length > 255 || pass.length > 255) {
          throw const FormatException(
            'SOCKS5: логин или пароль длиннее 255 байт',
          );
        }
        await _write(socket, <int>[
          0x01,
          user.length,
          ...user,
          pass.length,
          ...pass,
        ]);
        final authReply = await session.readExactly(2);
        if (authReply[0] != 0x01 || authReply[1] != 0x00) {
          throw const SocketException('SOCKS5: авторизация не пройдена');
        }
      } else if (method != 0x00) {
        throw SocketException(
          'SOCKS5: неподдерживаемый способ авторизации 0x${method.toRadixString(16)}',
        );
      }

      final target = _encodeAddress(destination.host);
      final targetPort = destination.hasPort
          ? destination.port
          : (destination.scheme == 'https' || destination.scheme == 'wss'
                ? 443
                : 80);
      await _write(socket, <int>[
        0x05,
        0x01,
        0x00,
        ...target,
        targetPort >> 8,
        targetPort & 0xff,
      ]);

      final connectReply = await session.readExactly(4);
      if (connectReply[0] != 0x05) {
        throw const FormatException('SOCKS5: неверная версия ответа CONNECT');
      }
      if (connectReply[1] != 0x00) {
        throw SocketException(
          'SOCKS5: CONNECT отклонён (${_replyName(connectReply[1])})',
        );
      }
      await _discardReplyAddress(session, connectReply[3]);

      // HttpClient получает уже установленный TLS-сокет для https/wss. Для
      // обычного http возвращается прозрачная обёртка над тем же транспортом.
      if (destination.scheme == 'https' || destination.scheme == 'wss') {
        return await session.finishTls(destination.host).timeout(timeout);
      }
      return session.finishHttp();
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  static Future<void> _write(Socket socket, List<int> bytes) async {
    socket.add(Uint8List.fromList(bytes));
    await socket.flush();
  }

  static List<int> _encodeAddress(String host) {
    final ip = InternetAddress.tryParse(host);
    if (ip != null && ip.type == InternetAddressType.IPv4) {
      return <int>[0x01, ...ip.rawAddress];
    }
    if (ip != null && ip.type == InternetAddressType.IPv6) {
      return <int>[0x04, ...ip.rawAddress];
    }
    final domain = utf8.encode(host);
    if (domain.isEmpty || domain.length > 255) {
      throw const FormatException('SOCKS5: недопустимое доменное имя');
    }
    return <int>[0x03, domain.length, ...domain];
  }

  static Future<void> _discardReplyAddress(
    _Socks5Session reader,
    int addressType,
  ) async {
    switch (addressType) {
      case 0x01:
        await reader.readExactly(4);
      case 0x03:
        final length = (await reader.readExactly(1))[0];
        await reader.readExactly(length);
      case 0x04:
        await reader.readExactly(16);
      default:
        throw FormatException(
          'SOCKS5: неизвестный тип адреса 0x${addressType.toRadixString(16)}',
        );
    }
    await reader.readExactly(2); // BND.PORT
  }

  static String _replyName(int code) {
    const names = <int, String>{
      0x01: 'общая ошибка',
      0x02: 'запрещено правилами',
      0x03: 'сеть недоступна',
      0x04: 'хост недоступен',
      0x05: 'соединение отклонено',
      0x06: 'TTL истёк',
      0x07: 'команда не поддерживается',
      0x08: 'тип адреса не поддерживается',
    };
    return names[code] ?? 'код 0x${code.toRadixString(16)}';
  }
}

class _Socks5Session {
  _Socks5Session(this._socket, this._timeout) {
    _subscription = _socket.listen(_onData, onError: _onError, onDone: _onDone);
  }

  final Socket _socket;
  final Duration _timeout;
  final List<int> _buffer = <int>[];
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _subscription;
  Completer<void>? _dataWaiter;
  bool _handshakeComplete = false;
  bool _closed = false;

  void _onData(Uint8List data) {
    if (_handshakeComplete) {
      if (!_incoming.isClosed) _incoming.add(data);
      return;
    }
    _buffer.addAll(data);
    final waiter = _dataWaiter;
    _dataWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _onError(Object error, StackTrace stack) {
    if (!_handshakeComplete) {
      final waiter = _dataWaiter;
      _dataWaiter = null;
      if (waiter != null && !waiter.isCompleted) {
        waiter.completeError(error, stack);
      }
    }
    if (!_incoming.isClosed) _incoming.addError(error, stack);
  }

  void _onDone() {
    if (!_handshakeComplete) {
      final waiter = _dataWaiter;
      _dataWaiter = null;
      if (waiter != null && !waiter.isCompleted) {
        waiter.completeError(
          const SocketException('SOCKS5: прокси закрыл соединение'),
        );
      }
    }
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  Future<List<int>> readExactly(int length) async {
    while (_buffer.length < length) {
      final waiter = Completer<void>();
      _dataWaiter = waiter;
      if (_buffer.length < length) {
        await waiter.future.timeout(_timeout);
      }
    }
    final result = Uint8List.fromList(_buffer.take(length).toList());
    _buffer.removeRange(0, length);
    return result;
  }

  Socket finishHttp() {
    _handshakeComplete = true;
    if (_buffer.isNotEmpty && !_incoming.isClosed) {
      _incoming.add(Uint8List.fromList(_buffer));
      _buffer.clear();
    }
    return _Socks5DetachedSocket(_socket, _incoming.stream);
  }

  Future<SecureSocket> finishTls(String host) async {
    _handshakeComplete = true;
    _buffer.clear();
    // SecureSocket.secure() transfers the existing paused subscription to the
    // TLS layer. This avoids trying to listen to the same Socket twice.
    _subscription.pause();
    unawaited(_incoming.close());
    return SecureSocket.secure(_socket, host: host);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    unawaited(_incoming.close());
    _socket.destroy();
  }
}

/// Socket-обёртка для передачи handshake-потока в dart:io HttpClient.
/// Внутренний Socket уже прослушивается с момента подключения к прокси, а
/// HttpClient получает отдельный single-subscription stream без повторной
/// подписки на исходный Socket.
class _Socks5DetachedSocket extends Stream<Uint8List> implements Socket {
  _Socks5DetachedSocket(this._socket, this._incoming);

  final Socket _socket;
  final Stream<Uint8List> _incoming;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _incoming.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) => _socket.encoding = value;

  @override
  void write(Object? obj) => _socket.write(obj);

  @override
  void writeln([Object? obj = '']) => _socket.writeln(obj);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);

  @override
  void add(List<int> bytes) => _socket.add(bytes);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);

  @override
  Future addStream(Stream<List<int>> stream) => _socket.addStream(stream);

  @override
  void destroy() => _socket.destroy();

  @override
  Future flush() => _socket.flush();

  @override
  Future close() => _socket.close();

  @override
  Future get done => _socket.done;

  @override
  int get port => _socket.port;

  @override
  InternetAddress get address => _socket.address;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get remotePort => _socket.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}
