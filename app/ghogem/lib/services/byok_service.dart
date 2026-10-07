import 'dart:convert';
import 'package:dio/dio.dart';
import 'api_service.dart';

class _ProviderSpec {
  const _ProviderSpec({
    required this.url,
    this.auth = 'bearer',
    this.mode = 'chat',
    this.extraHeaders = const {},
    this.maxTokensField = 'max_tokens',
    this.dropMessageName = false,
  });

  final String url;
  final String auth;
  final String mode;
  final Map<String, String> extraHeaders;
  final String maxTokensField;
  final bool dropMessageName;
}

// These are provider-specific documented API contracts, not guessed base URLs.
const _providerSpecs = <String, _ProviderSpec>{
  'groq': _ProviderSpec(
    url: 'https://api.groq.com/openai/v1/chat/completions',
    maxTokensField: 'max_completion_tokens',
    dropMessageName: true,
  ),
  'mistral': _ProviderSpec(url: 'https://api.mistral.ai/v1/chat/completions'),
  'openrouter': _ProviderSpec(
    url: 'https://openrouter.ai/api/v1/chat/completions',
    extraHeaders: {
      'HTTP-Referer': 'https://ghostecos.duckdns.org',
      'X-Title': 'GhostGem',
    },
  ),
  'sambanova': _ProviderSpec(url: 'https://api.sambanova.ai/v1/chat/completions'),
  'bazaarlink': _ProviderSpec(url: 'https://api.bazaarlink.ai/v1/chat/completions'),
  'zveno': _ProviderSpec(url: 'https://api.zveno.ai/v1/chat/completions'),
  'vireonix': _ProviderSpec(
    url: 'https://vireonix.ai/v1/chat/completions',
    auth: 'none',
  ),
  'persorai': _ProviderSpec(
    url: 'https://persorai.com/v1/chat/completions',
    auth: 'bearer_any',
  ),
  'freeai': _ProviderSpec(url: 'https://api.free.ai/v1/chat/'),
  'cvron': _ProviderSpec(
    url: 'https://cvron.alwaysdata.net/cvronai/multi-llm.php',
    auth: 'none',
    mode: 'cvron',
  ),
  'visionster': _ProviderSpec(
    url: 'https://www.ahm7xmakki.com/api/imgchat',
    auth: 'none',
    mode: 'visionster',
  ),
};

const _probeModelByProvider = <String, String>{
  'groq': 'groq:gpt-oss-20b',
  'mistral': 'mistral:small',
  'openrouter': 'openrouter:free-router',
  'sambanova': 'sambanova:gpt-oss-120b',
  'pollinations': 'pollinations:gpt-5-mini',
  'bazaarlink': 'bazaarlink:qwen-3.7-flash',
  'zveno': 'zveno:free-router',
  'vireonix': 'vireonix:free-router',
  'freeai': 'freeai:qwen7b',
  'cvron': 'cvron:gpt-6-luna',
};

const _modelMap = <String, String>{
  'groq:gpt-oss-20b': 'openai/gpt-oss-20b',
  'groq:gpt-oss-120b': 'openai/gpt-oss-120b',
  'groq:llama-4-scout': 'meta-llama/llama-4-scout-17b-16e-instruct',
  'mistral:small': 'mistral-small-2603',
  'mistral:medium': 'mistral-medium-3-5',
  'mistral:ministral-3b': 'ministral-3b-2512',
  'mistral:ministral-8b': 'ministral-8b-2512',
  'openrouter:free-router': 'openrouter/free',
  'vireonix:free-router': 'auto',
  'sambanova:gpt-oss-120b': 'gpt-oss-120b',
  'bazaarlink:qwen-3.7-flash': 'qwen/qwen3.7-flash:free',
  'zveno:free-router': 'openrouter/free',
  'cvron:gpt-6-luna': 'gpt-6-luna',
  'pollinations:gpt-5-mini': 'openai/gpt-5.4-nano',
  'freeai:qwen7b': 'qwen7b',
};

String _modelIdFor(String key, Map<String, dynamic>? catalog) {
  if (catalog != null) {
    for (final list in catalog.values) {
      if (list is! List) continue;
      for (final item in list) {
        if (item is Map && item['key'] == key && item['model'] is String) {
          return item['model'] as String;
        }
      }
    }
  }
  return _modelMap[key] ?? key.split(':').last;
}

class ByokService {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 300),
    sendTimeout: const Duration(seconds: 300),
  ));

  static Stream<String> stream({
    required String provider,
    required String apiKey,
    required String modelKey,
    required List<Map<String, dynamic>> messages,
    Map<String, dynamic>? catalog,
    CancelToken? cancelToken,
    double temperature = 0.7,
    int maxTokens = 2048,
  }) async* {
    final modelId = _modelIdFor(modelKey, catalog);

    if (provider == 'pollinations') {
      // Pollinations' server key must never be sent from the app. The GhoGem
      // API owns the key and forces this request through its configured proxy.
      await for (final event in GgApi.instance.pollinationsChatCompletions(
        model: modelId,
        messages: messages,
        temperature: temperature,
        maxTokens: maxTokens,
        cancelToken: cancelToken,
      )) {
        final text = _eventText(event);
        if (text.isNotEmpty) yield text;
      }
      return;
    }

    final spec = _providerSpecs[provider];
    if (spec == null) throw StateError('Unknown provider $provider');

    if (spec.mode == 'cvron') {
      final response = await _dio.get<Map<String, dynamic>>(
        spec.url,
        queryParameters: {
          'model': modelId,
          'prompt': _flattenMessages(messages),
        },
        cancelToken: cancelToken,
      );
      final text = response.data?['response'];
      if (text is! String) throw StateError('CVRON response field is missing');
      if (text.isNotEmpty) yield text;
      return;
    }

    if (spec.mode == 'visionster') {
      final request = _visionsterRequest(messages);
      final response = await _dio.post<Map<String, dynamic>>(
        spec.url, data: request, cancelToken: cancelToken,
      );
      final text = response.data?['response'];
      if (text is! String) throw StateError('VisionSter response field is missing');
      if (text.isNotEmpty) yield text;
      return;
    }

    final requestMessages = messages.map((message) {
      final result = Map<String, dynamic>.from(message);
      if (spec.dropMessageName) result.remove('name');
      if (result['role'] == 'developer') result['role'] = 'system';
      return result;
    }).toList();
    final body = <String, dynamic>{
      'model': provider == 'vireonix' ? 'auto' : modelId,
      'messages': requestMessages,
      'temperature': temperature,
      spec.maxTokensField: maxTokens,
      'stream': true,
    };
    final headers = <String, String>{
      'Content-Type': 'application/json',
      ...spec.extraHeaders,
      if (spec.auth == 'bearer') 'Authorization': 'Bearer $apiKey',
      if (spec.auth == 'bearer_any')
        'Authorization': 'Bearer ${apiKey.isEmpty ? 'any-random-key' : apiKey}',
    };
    final response = await _dio.post<ResponseBody>(
      spec.url,
      data: jsonEncode(body),
      options: Options(headers: headers, responseType: ResponseType.stream),
      cancelToken: cancelToken,
    );
    final responseBody = response.data;
    if (responseBody == null) throw StateError('$provider returned no response stream');
    final lines = responseBody.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      final value = line.trim();
      if (value.isEmpty || value.startsWith(':') || !value.startsWith('data:')) continue;
      final data = value.substring(5).trim();
      if (data == '[DONE]') break;
      final decoded = jsonDecode(data);
      if (decoded is! Map) throw FormatException('$provider returned an invalid SSE event');
      final event = Map<String, dynamic>.from(decoded);
      if (event['error'] != null) {
        final error = event['error'];
        final message = error is Map ? error['message'] : error;
        throw StateError(message?.toString() ?? '$provider stream failed');
      }
      final text = _eventText(event);
      if (text.isNotEmpty) yield text;
    }
  }

  static String _eventText(Map<String, dynamic> event) {
    final choices = event['choices'];
    final delta = choices is List && choices.isNotEmpty && choices.first is Map
        ? (choices.first as Map)['delta']
        : null;
    if (delta is! Map) return '';
    final content = _textValue(delta['content']);
    if (content.isNotEmpty) return content;
    return _textValue(delta['reasoning_content'] ?? delta['reasoning'] ?? delta['thinking']);
  }

  static String _textValue(dynamic value) {
    if (value is String) return value;
    if (value is List) {
      return value.whereType<Map>().map((part) => part['text']?.toString() ?? '').join();
    }
    return '';
  }

  static String _flattenMessages(List<Map<String, dynamic>> messages) {
    return messages.map((message) {
      final role = (message['role'] ?? 'user').toString().toUpperCase();
      return '$role: ${_textValue(message['content'])}';
    }).where((line) => line.trim().isNotEmpty).join('\n\n');
  }

  static Map<String, dynamic> _visionsterRequest(List<Map<String, dynamic>> messages) {
    var prompt = '';
    String? image;
    String? url;
    final history = <Map<String, String>>[];
    for (final message in messages) {
      final role = (message['role'] ?? 'user').toString();
      final content = message['content'];
      var text = content is String ? content : '';
      if (content is List) {
        for (final part in content.whereType<Map>()) {
          if (part['type'] == 'text') text = '$text ${part['text'] ?? ''}'.trim();
          if (part['type'] == 'image_url' && part['image_url'] is Map) {
            final source = (part['image_url'] as Map)['url'];
            if (source is String && source.startsWith('data:image/')) image = source;
            if (source is String && source.startsWith(RegExp(r'https?://'))) url = source;
          }
        }
      }
      if (role == 'user' && text.trim().isNotEmpty) prompt = text.trim();
      if ((role == 'user' || role == 'assistant') && text.trim().isNotEmpty) {
        history.add({'type': role == 'user' ? 'user' : 'ai', 'content': text.trim()});
      }
    }
    if (prompt.isEmpty || (image == null && url == null)) {
      throw StateError('VisionSter requires a prompt and image');
    }
    return {
      'userPrompt': prompt,
      if (image != null) 'image': image,
      if (image == null && url != null) 'url': url,
      if (history.isNotEmpty) 'messages': history.length > 20 ? history.sublist(history.length - 20) : history,
    };
  }

  static Future<String> probe(String provider, String apiKey) async {
    try {
      final modelKey = _probeModelByProvider[provider];
      if (modelKey == null) return 'unsupported';
      final stream = ByokService.stream(
        provider: provider,
        apiKey: apiKey,
        modelKey: modelKey,
        messages: const [{'role': 'user', 'content': 'Reply with OK.'}],
        maxTokens: 3,
      );
      final first = await stream.first.timeout(const Duration(seconds: 8));
      return first.isNotEmpty ? 'ok' : 'unknown';
    } catch (error) {
      final code = error is DioException ? error.response?.statusCode : null;
      if (code == 401 || error.toString().contains('401')) return 'invalid';
      if (code == 429 || error.toString().contains('429')) return 'limited';
      return 'unknown';
    }
  }
}
