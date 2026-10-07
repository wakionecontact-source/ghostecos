import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../theme.dart';
import 'settings_service.dart';

class GgApi {
  static final GgApi instance = GgApi._();
  GgApi._() {
    _dio.interceptors.add(CookieManager(_cookieJar));
  }
  final _cookieJar = CookieJar();
  final Dio _dio = Dio(BaseOptions(
    baseUrl: GG.apiGhogem,
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 300),
    headers: {'Content-Type': 'application/json'},
  ))..interceptors.add(LogInterceptor(responseBody: false));

  Map<String,String> _headers() {
    final token = SettingsService.instance.gsToken;
    final h = <String,String>{};
    if (token.isNotEmpty) {
      h['X-Gs-Token'] = token;
    }
    return h;
  }

  Future<Map<String,dynamic>> health() async {
    final r = await _dio.get('/health', options: Options(headers: _headers()));
    return r.data as Map<String,dynamic>;
  }

  Future<Map<String,dynamic>> models() async {
    final r = await _dio.get('/models', options: Options(headers: _headers()));
    return r.data as Map<String,dynamic>;
  }

  Future<void> selectModel(String key) async {
    await _dio.post('/models/select', data: {'model_key': key}, options: Options(headers: _headers()));
  }

  Future<Map<String,dynamic>> chats() async {
    final r = await _dio.get('/chats', options: Options(headers: _headers()));
    return r.data as Map<String,dynamic>;
  }

  Future<String> newChat() async {
    final r = await _dio.post('/chats/new', options: Options(headers: _headers()));
    return (r.data['chat_id'] as String);
  }

  Future<void> switchChat(String id) async {
    await _dio.post('/chats/switch', queryParameters: {'chat_id': id}, options: Options(headers: _headers()));
  }

  Future<List<Map<String,dynamic>>> history(String chatId) async {
    final r = await _dio.get('/chats/history', queryParameters: {'chat_id': chatId}, options: Options(headers: _headers()));
    return (r.data['messages'] as List).cast<Map<String,dynamic>>();
  }

  Stream<Map<String,dynamic>> pollinationsChatCompletions({
    required String model,
    required List<Map<String,dynamic>> messages,
    double temperature=0.7,
    int maxTokens=2048,
    List<Map<String,dynamic>>? tools,
    dynamic toolChoice,
    CancelToken? cancelToken,
  }) async* {
    final body = <String,dynamic>{
      'model': model,
      'messages': messages,
      'temperature': temperature,
      'max_tokens': maxTokens,
      if (tools!=null && tools.isNotEmpty) 'tools': tools,
      if (toolChoice!=null) 'tool_choice': toolChoice,
    };
    final response = await _dio.post<ResponseBody>(
      '/providers/pollinations/chat/completions',
      data: body,
      options: Options(headers: _headers(), responseType: ResponseType.stream),
      cancelToken: cancelToken,
    );
    final responseBody = response.data;
    if (responseBody==null) throw Exception('Pollinations proxy returned no stream');
    final lines = responseBody.stream.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      final value = line.trim();
      if (!value.startsWith('data:')) continue;
      final data = value.substring(5).trim();
      if (data=='[DONE]') break;
      final decoded = jsonDecode(data);
      if (decoded is! Map) continue;
      final event = Map<String,dynamic>.from(decoded);
      final error = event['error'];
      if (error!=null) {
        final message = error is Map ? error['message'] : error;
        throw Exception(message?.toString() ?? 'Pollinations proxy failed');
      }
      yield event;
    }
  }

  Future<List<Map<String,dynamic>>> files({String? chatId}) async {
    final r = await _dio.get('/files', queryParameters: chatId != null ? {'chat_id': chatId} : {}, options: Options(headers: _headers()));
    return (r.data['files'] as List).cast<Map<String,dynamic>>();
  }

  Future<Map<String,dynamic>> uploadFile(String path, String chatId, {String? storageArea, bool urgent=false}) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(path),
    });
    final qp = <String, dynamic>{'chat_id': chatId, if (storageArea!=null) 'storage_area': storageArea, 'urgent': urgent.toString()};
    // важно: не слать Content-Type: application/json для FormData, иначе 404/422
    final r = await _dio.post('/files/upload', data: form, queryParameters: qp, options: Options(headers: _headers(), contentType: 'multipart/form-data'));
    return r.data as Map<String,dynamic>;
  }

  // WebSocket chat — поток событий как в web_api ws_chat, images — для прямого анализа моделью без роута
  Stream<Map<String,dynamic>> chatStream({
    required String text,
    required String model,
    String? chatId,
    bool webSearch=false,
    bool forceTts=false,
    bool forceVision=false,
    bool forceStt=false,
    List<Map<String,String>> images = const [],
  }) {
    final controller = StreamController<Map<String,dynamic>>();
    _connectWs(controller, text, model, chatId, webSearch, forceTts, forceVision, forceStt, images);
    return controller.stream;
  }

  void _connectWs(StreamController<Map<String,dynamic>> ctrl, String text, String model, String? chatId, bool ws,bool tts,bool vis,bool stt, List<Map<String,String>> images) async {
    WebSocketChannel? channel;
    HttpClient? httpClient;
    try {
      final uri = Uri.parse(GG.wsGhogem);
      httpClient = HttpClient()..findProxy = (u) => "DIRECT";
      // Attach guest session cookie to WS handshake so it matches the HTTP session used for /files/upload
      final cookies = await _cookieJar.loadForRequest(uri);
      final cookieHeader = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      final wsHeaders = <String, dynamic>{};
      if (cookieHeader.isNotEmpty) wsHeaders['Cookie'] = cookieHeader;
      channel = IOWebSocketChannel.connect(uri, headers: wsHeaders.isEmpty ? null : wsHeaders, customClient: httpClient);
      await channel.ready.timeout(const Duration(seconds: 10));
      final payload = {
        'type':'message',
        'text': text,
        'model': model,
        if (chatId != null) 'chat_id': chatId,
        'web_search': ws,
        'force_tts': tts,
        'force_vision': vis,
        'force_stt': stt,
        if (images.isNotEmpty) 'images': images,
        if (SettingsService.instance.gsToken.isNotEmpty) 'gs_token': SettingsService.instance.gsToken,
      };
      channel.sink.add(jsonEncode(payload));
      channel.stream.listen((raw) {
        try {
          final ev = jsonDecode(raw as String) as Map<String,dynamic>;
          ctrl.add(ev);
          if (ev['type']=='done' || ev['type']=='cancelled' || ev['type']=='error') {
            ctrl.close();
            channel?.sink.close();
          }
        } catch (_) {}
      }, onError: (e) {
        if (!ctrl.isClosed) { ctrl.addError(e); ctrl.close(); }
      }, onDone: () {
        if (!ctrl.isClosed) ctrl.close();
      });
    } catch (e) {
      if (!ctrl.isClosed) {
        ctrl.add({'type':'error','text':'WS недоступен: $e'});
        ctrl.close();
      }
      try { await channel?.sink.close(); } catch(_){}
      try { httpClient?.close(force: true); } catch(_){}
    }
  }
}
