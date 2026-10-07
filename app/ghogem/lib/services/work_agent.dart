import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'work_tools.dart';

class WorkAgent {
  static CancelToken? _cancelToken;
  static void cancel(){ try{ _cancelToken?.cancel('user stop'); }catch(_){} _cancelToken=null; }
  static bool get isCancelled => _cancelToken?.isCancelled ?? false;

  // Прямое подключение к Pollinations без ключа (по документации):
  // POST https://text.pollinations.ai/openai, без Authorization.
  // Проверено: model "openai" работает anon; system — только короткий
  // английский (кириллица + C:\ даёт 402/ENOSPC).
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 120),
    sendTimeout: const Duration(seconds: 60),
    headers: {'Content-Type': 'application/json'},
  ));

  static const _url = 'https://text.pollinations.ai/openai';
  static const _model = 'openai';

  static Stream<Map<String,dynamic>> stream({
    required String prompt,
    required String workDir,
    List<Map<String,dynamic>> history = const [],
    String? customPrompt,
  }) async* {
    final safeDir = workDir.replaceAll('\\', '/');
    final system = StringBuffer('You are GhostGem Work agent. Work dir: $safeDir. '
        'Tools: list_files, read_file, write_file, edit_file, delete_file. '
        'Reply in Russian, keep answers short.');
    var extra = (customPrompt ?? '').trim();
    if (extra.length > 500) extra = extra.substring(0, 500);
    if (extra.isNotEmpty) system.write(' User prefs: $extra');

    final shortHistory = history.length > 6 ? history.sublist(history.length - 6) : history;
    final messages = <Map<String,dynamic>>[
      {'role': 'system', 'content': system.toString()},
      for (final m in shortHistory) {'role': m['role'], 'content': m['content']},
      {'role': 'user', 'content': prompt},
    ];

    _cancelToken = CancelToken();
    try {
      final body = {
        'model': _model,
        'messages': messages,
        'temperature': 0.7,
        'max_tokens': 1024,
        'stream': true,
        'tools': workTools,
        'tool_choice': 'auto',
      };
      final resp = await _dio.post<ResponseBody>(
        _url,
        data: jsonEncode(body),
        options: Options(responseType: ResponseType.stream),
        cancelToken: _cancelToken,
      );
      final stream = (resp.data!.stream as Stream<List<int>>)
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      Map<int, Map<String,dynamic>> toolCallsAcc = {};
      bool hasTool = false;
      bool inReasoning = false;
      await for (final line in stream) {
        if (isCancelled) { yield {'type': 'cancelled'}; _cancelToken = null; return; }
        final l = line.trim();
        if (l.isEmpty || !l.startsWith('data:')) continue;
        final d = l.substring(5).trim();
        if (d == '[DONE]') break;
        try {
          final j = jsonDecode(d) as Map<String,dynamic>;
          final delta = (j['choices'] as List?)?.firstOrNull?['delta'] as Map<String,dynamic>?;
          if (delta == null) continue;
          final tcs = delta['tool_calls'] as List?;
          if (tcs != null && tcs.isNotEmpty) {
            hasTool = true;
            for (final tc in tcs) {
              final idx = tc['index'] as int? ?? 0;
              final slot = toolCallsAcc.putIfAbsent(idx, () => {'id': tc['id'], 'name': '', 'arguments': ''});
              if (tc['id'] != null) slot['id'] = tc['id'];
              final fn = tc['function'] as Map?;
              if (fn != null) {
                if (fn['name'] != null) slot['name'] = (slot['name'] as String) + (fn['name'] as String);
                if (fn['arguments'] != null) slot['arguments'] = (slot['arguments'] as String) + (fn['arguments'] as String);
              }
            }
            continue;
          }
          final reasoning = delta['reasoning_content'] ?? delta['reasoning'] ?? delta['thinking'];
          final content = delta['content'] as String?;
          if (reasoning is String && reasoning.isNotEmpty) {
            if (!inReasoning) { yield {'type': 'thinking_start'}; inReasoning = true; }
            yield {'type': 'thinking', 'text': reasoning};
          } else if (content != null && content.isNotEmpty) {
            if (inReasoning) { yield {'type': 'thinking_end'}; inReasoning = false; }
            yield {'type': 'token', 'text': content};
          }
        } catch (_) {}
      }
      if (inReasoning) yield {'type': 'thinking_end'};
      if (!hasTool || toolCallsAcc.isEmpty) {
        yield {'type': 'done'};
        _cancelToken = null;
        return;
      }
      final ordered = toolCallsAcc.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
      for (final e in ordered) {
        if (isCancelled) { yield {'type': 'cancelled'}; _cancelToken = null; return; }
        final name = e.value['name'] as String? ?? '';
        final argsStr = e.value['arguments'] as String? ?? '{}';
        Map<String,dynamic> args;
        try { args = jsonDecode(argsStr) as Map<String,dynamic>; } catch (_) { args = {}; }
        yield {'type': 'action', 'phase': 'start', 'name': name, 'text': '$name $args'};
        final result = await runWorkTool(name, args);
        yield {'type': 'action', 'phase': 'done', 'name': name, 'text': result};
        yield {'type': 'token', 'text': '\n\nРезультат $name:\n$result'};
      }
      yield {'type': 'done'};
      _cancelToken = null;
      return;
    } catch (e) {
      if (e is DioException && CancelToken.isCancel(e)) {
        yield {'type': 'cancelled'};
        _cancelToken = null;
        return;
      }
      final msg = e.toString();
      if (msg.contains('cancel') || msg.contains('Cancelled')) {
        yield {'type': 'cancelled'};
        _cancelToken = null;
        return;
      }
      yield {'type': 'token', 'text': 'Work: прямое подключение не ответило. $msg'};
      yield {'type': 'done'};
      _cancelToken = null;
      return;
    }
  }

  /// Прямое vision-подключение для картинок (тот же endpoint, content-массив).
  static Stream<String> vision({
    required List<Map<String,dynamic>> messages,
    CancelToken? cancelToken,
  }) async* {
    final resp = await _dio.post<ResponseBody>(
      _url,
      data: jsonEncode({
        'model': _model,
        'messages': messages,
        'temperature': 0.7,
        'max_tokens': 1024,
        'stream': true,
      }),
      options: Options(responseType: ResponseType.stream),
      cancelToken: cancelToken ?? _cancelToken,
    );
    final stream = (resp.data!.stream as Stream<List<int>>)
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in stream) {
      final l = line.trim();
      if (l.isEmpty || !l.startsWith('data:')) continue;
      final d = l.substring(5).trim();
      if (d == '[DONE]') break;
      try {
        final j = jsonDecode(d) as Map<String,dynamic>;
        final delta = (j['choices'] as List?)?.firstOrNull?['delta'] as Map<String,dynamic>?;
        final content = delta?['content'];
        if (content is String && content.isNotEmpty) yield content;
      } catch (_) {}
    }
  }
}

extension _FirstOrNull<E> on List<E> { E? get firstOrNull => isEmpty ? null : first; }
