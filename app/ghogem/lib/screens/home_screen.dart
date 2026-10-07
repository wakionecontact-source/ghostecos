import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:path/path.dart' as p;
import 'package:dio/dio.dart';
import '../services/work_service.dart';
import '../services/work_agent.dart';
import '../services/work_tools.dart';
import '../services/auth_service.dart';
import 'work_screen.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/message_bubble.dart';
import '../services/chat_store.dart';
import '../services/settings_service.dart';
import '../services/api_service.dart';
import '../services/byok_service.dart';
import 'models_screen.dart';
import 'keys_screen.dart';
import 'files_screen.dart';
import 'memory_screen.dart';
import 'reminders_screen.dart';
import 'premium_screen.dart';

class _Attachment {
  final String name;
  final Uint8List bytes;
  final String mime;
  final String? path;
  _Attachment({required this.name, required this.bytes, required this.mime, this.path});
  bool get isImage => mime.startsWith('image/');
}

class HomeScreen extends StatefulWidget {
  final VoidCallback? onLoggedOut;
  const HomeScreen({super.key, this.onLoggedOut});
  @override State<HomeScreen> createState()=>_HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _chatId;
  List<Map<String,dynamic>> _chats = [];
  List<Map<String,dynamic>> _msgs = [];
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  bool _sending=false;
  String? _streamingThinking;
  String _streamingAnswer='';
  final List<TimelineEntry> _timeline = [];
  Map<String,dynamic>? _modelsCache;
  bool _webSearch=false;
  bool _forceVision=false;
  bool _forceTts=false;
  bool _forceStt=false;
  final List<_Attachment> _attachments = [];
  String? _serverChatCache;
  CancelToken? _byokCancelToken;
  CancelToken? _workImageCancelToken;
  bool _dragOver=false;

  @override void initState(){ super.initState(); _init(); }

  Future<void> _init() async {
    await SettingsService.instance.init();
    await _loadChats();
    _preloadModels();
  }

  Future<void> _preloadModels() async {
    try {
      final m = await GgApi.instance.models();
      if (mounted) setState(()=>_modelsCache=m);
    } catch(_){}
  }

  Future<void> _loadChats() async {
    final list = await ChatStore.instance.listChats();
    if (!mounted) return;
    setState(()=>_chats=list);
    if (_chatId==null && list.isNotEmpty) {
      _chatId = list.first['id'] as String;
      await _loadMsgs();
    } else if (_chatId!=null) await _loadMsgs();
    if (_chatId==null && list.isEmpty) await _newChat();
  }

  Future<void> _loadMsgs() async {
    if (_chatId==null) return;
    final m = await ChatStore.instance.messages(_chatId!);
    if (!mounted) return;
    setState(()=>_msgs=m);
    _jumpBottom();
  }

  void _jumpBottom(){ WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent+200, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  });}

  Future<void> _newChat() async {
    final id = await ChatStore.instance.createChat();
    setState(()=>_chatId=id);
    _serverChatCache=null;
    _attachments.clear();
    await _loadChats();
  }

  Future<String> _ensureServerChatId() async {
    if (_serverChatCache!=null) return _serverChatCache!;
    try{
      final data = await GgApi.instance.chats();
      var cur = data['current'] as String?;
      if (cur!=null && cur.isNotEmpty) { _serverChatCache=cur; return cur; }
      final nid = await GgApi.instance.newChat();
      _serverChatCache=nid;
      return nid;
    }catch(e){ throw Exception('Не удалось получить серверный чат: $e'); }
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    final hasAttachments = _attachments.isNotEmpty;
    if ((text.isEmpty && !hasAttachments) || _sending) return;
    if (_chatId==null) await _newChat();
    final cid = _chatId!;
    final model = SettingsService.instance.currentModel;
    _ctrl.clear();
    final pending = List<_Attachment>.from(_attachments);
    final mediaCount = pending.where((a)=>a.isImage || a.mime.startsWith('video/') || a.mime.startsWith('audio/')).length;
    final fileCount = pending.length - mediaCount;
    if (pending.length > 30) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Лимит: всего 30 вложений'))); _attachments.addAll(pending); setState((){}); return; }
    if (mediaCount > 20) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Лимит: до 20 медиа'))); _attachments.addAll(pending); setState((){}); return; }
    if (fileCount > 25) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Лимит: до 25 файлов'))); _attachments.addAll(pending); setState((){}); return; }
    _attachments.clear();
    setState((){});
    List<Map<String,dynamic>>? attJson;
    if (pending.isNotEmpty) {
      attJson = await ChatStore.instance.saveAttachments(cid, pending.map((a)=>{'name':a.name, 'bytes':a.bytes, 'mime':a.mime}).toList());
    }
    await ChatStore.instance.addMessage(cid, 'user', text, modelKey: model, attachments: attJson);
    await _loadMsgs();
    setState((){_sending=true; _streamingAnswer=''; _streamingThinking=null; _timeline.clear();});

    final mode = SettingsService.instance.mode;
    try {
      if (mode== ChatMode.work) {
        await _sendWork(cid, text, pending);
      } else if (mode==ChatMode.byok) {
        await _sendByok(cid, text, model, pending);
      } else {
        await _sendServer(cid, text, model, pending);
      }
    } catch (e) {
      await ChatStore.instance.addMessage(cid, 'assistant', 'Ошибка: $e', modelKey: model);
    } finally {
      _byokCancelToken = null;
      _workImageCancelToken = null;
      if (mounted) setState(()=>_sending=false);
      await _loadMsgs();
    }
  }

  void _stop(){
    if (SettingsService.instance.mode==ChatMode.work) {
      WorkAgent.cancel();
      _workImageCancelToken?.cancel('Stopped by user');
      _workImageCancelToken = null;
      setState(()=>_sending=false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Остановлено')));
    } else if (SettingsService.instance.mode==ChatMode.byok) {
      _byokCancelToken?.cancel('Stopped by user');
      setState(()=>_sending=false);
    } else {
      // для Чат — просто сбрасываем флаг, WS отменится по таймауту
      setState(()=>_sending=false);
    }
  }

  Future<void> _sendServer(String cid, String text, String model, List<_Attachment> atts) async {
    // 1) Сохраняем в хранилище правильно: медиа -> media, файлы -> files (баг был — всё шло в files)
    // 2) И отправляем инлайн base64 для прямого анализа моделью (без роута бота)
    List<Map<String,String>> inlineImages = [];
    if (atts.isNotEmpty) {
      try{
        final serverChat = await _ensureServerChatId();
        for(final a in atts){
          final tmp = File('${Directory.systemTemp.path}/${a.name}');
          await tmp.writeAsBytes(a.bytes);
          final isMedia = a.isImage || a.mime.startsWith('video/') || a.mime.startsWith('audio/');
          try{
            await GgApi.instance.uploadFile(tmp.path, serverChat, storageArea: isMedia ? 'media' : null);
          }catch(e){
            await ChatStore.instance.addMessage(cid, 'assistant', ' Не удалось сохранить ${a.name} в ${isMedia ? 'media' : 'files'}: $e', modelKey: model);
          } finally {
            try{ await tmp.delete(); }catch(_){}
          }
          if (a.isImage) {
            inlineImages.add({'name': a.name, 'mime': a.mime, 'base64': base64Encode(a.bytes)});
          }
        }
        if (text.isEmpty && atts.isNotEmpty) _forceVision = true;
      }catch(e){
        await ChatStore.instance.addMessage(cid, 'assistant', ' Ошибка сохранения файлов: $e', modelKey: model);
      }
    }
    String sendText = text;
    if (atts.isNotEmpty && text.isEmpty) sendText = 'Проанализируй прикреплённые файлы: ${atts.map((a)=>a.name).join(', ')}';
    else if (atts.isNotEmpty) sendText = '$text\n[Прикреплены файлы: ${atts.map((a)=>a.name).join(', ')}]';

    bool gotAny=false;
    bool gotError=false;
    bool receivedDone=false;
    String? errorText;
    // таймлайн: мысли развёрнуты во время стрима, сворачиваются после
    try {
      await for (final ev in GgApi.instance.chatStream(
        text:sendText,
        model:model,
        chatId: await _safeServerChatId(),
        webSearch: _webSearch,
        forceVision: _forceVision,
        forceTts: _forceTts,
        forceStt: _forceStt,
        images: inlineImages,
      ).timeout(const Duration(seconds: 90))) {
        final type = ev['type'] as String?;
        if (type=='done') receivedDone=true;
        if (type=='thinking_start') {
          setState(()=>_timeline.add(TimelineEntry(type: 'thinking', text: '', expanded: true)));
        } else if (type=='thinking') {
          final chunk = ev['text'] as String? ?? '';
          setState((){
            if (_timeline.isNotEmpty && _timeline.last.type=='thinking') {
              _timeline.last.text += chunk;
            } else {
              _timeline.add(TimelineEntry(type: 'thinking', text: chunk, expanded: true));
            }
          });
          _jumpBottom();
        } else if (type=='thinking_end') {
          setState((){
            if (_timeline.isNotEmpty && _timeline.last.type=='thinking') _timeline.last.expanded = false;
          });
        } else if (type=='token') {
          gotAny=true;
          final chunk = ev['text'] as String? ?? '';
          setState((){
            if (_timeline.isNotEmpty && _timeline.last.type=='text') {
              _timeline.last.text += chunk;
            } else {
              _timeline.add(TimelineEntry(type: 'text', text: chunk, expanded: true));
            }
          });
          _jumpBottom();
        } else if (type=='action') {
          final name = ev['name'] as String? ?? 'tool';
          final txt = ev['text'] as String? ?? '';
          setState(()=>_timeline.add(TimelineEntry(type: 'action', text: '$name: $txt', expanded: true)));
        } else if (type=='done') {
          final thinkingCombined = _timeline.where((e)=>e.type=='thinking').map((e)=>e.text).join('\n\n').trim();
          final answerCombined = _timeline.where((e)=>e.type=='text').map((e)=>e.text).join('').trim();
          for(final e in _timeline) if(e.type=='thinking') e.expanded=false;
          if (answerCombined.isNotEmpty) await ChatStore.instance.addMessage(cid, 'assistant', answerCombined, thinking: thinkingCombined.isEmpty ? null : thinkingCombined, modelKey: model);
          if (mounted) setState((){ _timeline.clear(); _streamingAnswer=''; _streamingThinking=null;});
          unawaited(_maybeGenerateTitle(cid));
        } else if (type=='error') {
          gotError=true;
          errorText = ev['text'] as String? ?? ev.toString();
        } else if (type=='media') {
          final name = ev['name'] as String? ?? 'file';
          await ChatStore.instance.addMessage(cid, 'assistant', ' Файл готов: $name (открой в Файлы чата)', modelKey: model);
        }
      }
      if (!receivedDone && !gotError) {
        gotError=true;
        errorText='Сервер закрыл поток до завершения ответа';
      }
    } on TimeoutException {
      gotError=true;
      errorText ??='Сервер не завершил ответ за 90 секунд';
    } catch (e) {
      gotError=true;
      errorText=e.toString();
    }
    if (!gotAny && gotError) {
      if (mounted) setState(()=>_timeline.clear());
      // If Pollinations itself was selected, retrying it as a fallback only
      // repeats the same stalled request and leaves the chat apparently blank.
      final fallbackOk = model.startsWith('pollinations:')
          ? false
          : await _tryPollinationsFallback(cid, sendText);
      if (!fallbackOk) {
        String msg = 'Ошибка сервера: $errorText';
        if ((errorText??'').contains('404')) {
          msg = 'Сервер вернул 404 при загрузке/чате. Чат не найден — создан новый. Попробуй ещё раз.\n\n$errorText';
          _serverChatCache=null;
        }
        await ChatStore.instance.addMessage(cid, 'assistant', msg, modelKey: model);
        if (mounted) await _loadMsgs();
      }
    }
  }

  Future<String?> _safeServerChatId() async {
    try{ return await _ensureServerChatId(); }catch(_){ return null; }
  }

  Future<bool> _tryPollinationsFallback(String cid, String text) async {
    try {
      final hist = _msgs.map((m)=>{'role': m['role'] as String, 'content': m['content'] as String}).toList();
      hist.add({'role':'user','content': text});
      final sys = SettingsService.instance.customPrompt;
      final messages = [ if (sys.isNotEmpty) {'role':'system','content': sys}, ...hist ];
      String acc='';
      await for (final chunk in ByokService.stream(provider: 'pollinations', apiKey: '', modelKey: 'pollinations:gpt-5-mini', messages: messages)) {
        acc += chunk;
        if (mounted) setState(()=>_streamingAnswer=acc);
        _jumpBottom();
      }
      final finalText = acc.trim().isEmpty ? '' : acc.trim();
      if (finalText.isNotEmpty) {
        await ChatStore.instance.addMessage(cid, 'assistant', finalText, modelKey: 'pollinations:gpt-5-mini (fallback)');
        if (mounted) setState(()=>_streamingAnswer='');
        await _loadMsgs();
        return true;
      }
    } catch (e) {
      if (mounted) setState(()=>_streamingAnswer='');
    }
    return false;
  }

  Future<void> _sendByok(String cid, String text, String model, List<_Attachment> atts) async {
    final provider = model.split(':').first;
    String? key = await SettingsService.instance.getKey(provider);
    // Keyless providers follow their documented contracts. Pollinations still
    // goes through the GhoGem server proxy and never receives a client key.
    const noKeyProviders = {'pollinations', 'vireonix', 'persorai', 'cvron', 'visionster'};
    if ((key==null || key.isEmpty) && !noKeyProviders.contains(provider)) {
      await ChatStore.instance.addMessage(cid, 'assistant', ' Нет ключа для `$provider`. Открой Настройки → Ключи и добавь API ключ для $provider, либо переключись в Серверный режим.', modelKey: model);
      // keep attachments for retry
      _attachments.addAll(atts);
      setState((){});
      return;
    }
    key ??= '';
    final hist = _msgs.map((m)=>{'role': m['role'] as String, 'content': m['content'] as String}).toList();
    // _send already stored and reloaded the current user turn before calling
    // this method; remove it here because the BYOK request rebuilds it below
    // with the original text and any image data.
    if (hist.isNotEmpty && hist.last['role']=='user' && hist.last['content']==text) {
      hist.removeLast();
    }
    // Build messages with multimodal if images
    List<Map<String,dynamic>> messages = [];
    final sys = SettingsService.instance.customPrompt;
    if (sys.isNotEmpty) messages.add({'role':'system','content': sys});
    for(final m in hist){
      messages.add({'role': m['role'] as String, 'content': m['content'] as String});
    }
    // current user message with attachments
    if (atts.isEmpty) {
      messages.add({'role':'user','content': text.isEmpty ? 'Привет' : text});
    } else {
      // multimodal content
      final contentParts = <Map<String,dynamic>>[];
      if (text.isNotEmpty) contentParts.add({'type':'text','text': text});
      for(final a in atts){
        if (a.isImage) {
          final b64 = base64Encode(a.bytes);
          final mime = a.mime.isEmpty ? 'image/jpeg' : a.mime;
          contentParts.add({'type':'image_url','image_url':{'url':'data:$mime;base64,$b64'}});
        } else {
          // for non-image, append as text hint
          contentParts.add({'type':'text','text':'[Файл: ${a.name} ${a.bytes.length} байт]'});
        }
      }
      if (contentParts.length==1 && contentParts.first['type']=='text') {
        messages.add({'role':'user','content': contentParts.first['text'] as String});
      } else {
        messages.add({'role':'user','content': contentParts});
      }
    }
    final catalog = _modelsCache?['providers'] as Map<String,dynamic>?;
    String acc='';
    final cancelToken = CancelToken();
    _byokCancelToken = cancelToken;
    // BYOK тоже через таймлайн для единообразия
    setState(()=>_timeline.add(TimelineEntry(type: 'text', text: '', expanded: true)));
    try {
      await for (final chunk in ByokService.stream(
        provider: provider,
        apiKey: key,
        modelKey: model,
        messages: messages,
        catalog: catalog,
        cancelToken: cancelToken,
      )) {
        acc += chunk;
        setState((){
          if (_timeline.isNotEmpty && _timeline.last.type=='text') _timeline.last.text = acc;
        });
        if (mounted) setState(()=>_streamingAnswer=acc);
        _jumpBottom();
      }
    } catch (e) {
      if (cancelToken.isCancelled) {
        if (mounted) setState(()=>_timeline.clear());
        return;
      }
      if (acc.isEmpty) rethrow;
    }
    final finalText = acc.trim().isEmpty ? '(пустой ответ)' : acc.trim();
    await ChatStore.instance.addMessage(cid, 'assistant', finalText, modelKey: model);
    if (mounted) setState(()=>_timeline.clear());
    unawaited(_maybeGenerateTitle(cid));
  }

  Future<void> _maybeGenerateTitle(String chatId) async {
    try{
      final chats = await ChatStore.instance.listChats();
      final chat = chats.firstWhere((c)=>c['id']==chatId, orElse: ()=>{});
      if (chat.isEmpty || chat['title']!='Новый чат') return;
      final msgs = await ChatStore.instance.messages(chatId);
      if (msgs.length < 2) return;
      final snippet = msgs.take(4).map((m)=>'${m['role']}: ${(m['content'] as String).split('\n').first}').join('\n').substring(0, 600);
      final prompt = 'Сгенерируй короткий заголовок чата (2-4 слова, до 40 символов, без кавычек и эмодзи) по диалогу:\n$snippet\nЗаголовок:';
      String title = '';
      try{
        await for(final chunk in ByokService.stream(provider: 'pollinations', apiKey: '', modelKey: 'pollinations:gpt-5-mini', messages: [{'role':'user','content': prompt}], maxTokens: 16)){
          title += chunk;
          if (title.length>50) break;
        }
      }catch(_){
        final first = msgs.firstWhere((m)=>m['role']=='user', orElse: ()=>msgs.first);
        title = (first['content'] as String).split('\n').first.trim();
      }
      title = title.replaceAll(RegExp(r'["«»„“\n\r]'), '').trim();
      title = title.replaceAll(RegExp(r'^(Заголовок|Title)\s*:\s*', caseSensitive:false), '').trim();
      if (title.length>40) title = title.substring(0,40).trim();
      if (title.isEmpty || title=='Новый чат') {
        final first = msgs.firstWhere((m)=>m['role']=='user', orElse: ()=>msgs.first);
        title = (first['content'] as String).split('\n').first.trim();
        if (title.length>40) title = title.substring(0,40);
      }
      if (title.isNotEmpty && title!='Новый чат') {
        await ChatStore.instance.renameChat(chatId, title);
        if (mounted) await _loadChats();
      }
    }catch(_){}
  }

  Future<void> _sendWork(String cid, String text, List<_Attachment> atts) async {
    // Work: локальные файлы + Pollinations через серверный SOCKS proxy.
    // 1) вложения файлов — уже сохранены локально для отображения, дополнительно сохраняем в Work dir если это файлы?
    // Для Work вложения — это уже файлы, которые можно положить в Work dir как артефакты
    // 2) Стримим через WorkAgent
    final workDir = await WorkService.instance.getWorkDir();
    final hist = _msgs.map((m)=>{'role': m['role'] as String, 'content': m['content'] as String}).toList();
    // если есть вложения-картинки — добавим инлайн для Pollinations (аналог BYOK)
    String prompt = text;
    if (atts.isNotEmpty) {
      final names = atts.map((a)=>a.name).join(', ');
      prompt = text.isEmpty ? 'Проанализируй файлы: $names' : '$text\n[Файлы: $names]';
      for(final a in atts){
        try{
          final dir = await WorkService.instance.getWorkDir();
          final fpath = p.join(dir, 'attachments', a.name);
          await Directory(p.dirname(fpath)).create(recursive: true);
          await File(fpath).writeAsBytes(a.bytes);
        }catch(_){}
      }
    }
    // если есть картинки — прямое vision-подключение без ключа
    if (atts.any((a)=>a.isImage)) {
      final shortHist = hist.length > 6 ? hist.sublist(hist.length - 6) : hist;
      var extra = SettingsService.instance.customPrompt.trim();
      if (extra.length > 500) extra = extra.substring(0, 500);
      final messages = <Map<String,dynamic>>[
        {'role':'system','content': extra.isEmpty ? workSystemPrompt(workDir) : '${workSystemPrompt(workDir)} User prefs: $extra'},
        ...shortHist,
      ];
      final contentParts = <Map<String,dynamic>>[];
      if (prompt.isNotEmpty) contentParts.add({'type':'text','text': prompt});
      for(final a in atts.where((a)=>a.isImage)){
        contentParts.add({'type':'image_url','image_url':{'url':'data:${a.mime};base64,${base64Encode(a.bytes)}'}});
      }
      messages.add({'role':'user','content': contentParts});
      String acc='';
      setState(()=>_timeline.add(TimelineEntry(type:'text', text:'', expanded:true)));
      final imgCancel = CancelToken();
      _workImageCancelToken = imgCancel;
      try{
        await for(final chunk in WorkAgent.vision(messages: messages, cancelToken: imgCancel)){
          acc+=chunk;
          setState((){
            if (_timeline.isNotEmpty && _timeline.last.type=='text') _timeline.last.text = acc;
          });
          _jumpBottom();
        }
      }catch(e){
        if (e is DioException && CancelToken.isCancel(e)) {
          await ChatStore.instance.addMessage(cid, 'assistant', 'Остановлено пользователем', modelKey: 'work:openai');
          if (mounted) setState(()=>_timeline.clear());
          return;
        }
        acc = acc.isEmpty ? 'Ошибка Work: $e' : acc;
      } finally {
        _workImageCancelToken = null;
      }
      final finalText = acc.trim().isEmpty ? '(пустой ответ)' : acc.trim();
      await ChatStore.instance.addMessage(cid, 'assistant', finalText, modelKey: 'work:openai');
      if (mounted) setState(()=>_timeline.clear());
      unawaited(_maybeGenerateTitle(cid));
      return;
    }

    // обычный Work агент с tools
    bool gotAny=false;
    await for(final ev in WorkAgent.stream(prompt: prompt, workDir: workDir, history: hist, customPrompt: SettingsService.instance.customPrompt)){
      final type = ev['type'] as String?;
      if (type=='thinking_start') setState(()=>_timeline.add(TimelineEntry(type:'thinking', text:'', expanded:true)));
      else if (type=='thinking') {
        final chunk = ev['text'] as String? ?? '';
        setState((){
          if (_timeline.isNotEmpty && _timeline.last.type=='thinking') _timeline.last.text += chunk;
          else _timeline.add(TimelineEntry(type:'thinking', text:chunk, expanded:true));
        });
      } else if (type=='thinking_end') {
        setState((){
          if (_timeline.isNotEmpty && _timeline.last.type=='thinking') _timeline.last.expanded=false;
        });
      } else if (type=='token') {
        gotAny=true;
        final chunk = ev['text'] as String? ?? '';
        setState((){
          if (_timeline.isNotEmpty && _timeline.last.type=='text') _timeline.last.text += chunk;
          else _timeline.add(TimelineEntry(type:'text', text:chunk, expanded:true));
        });
        _jumpBottom();
      } else if (type=='action') {
        final phase = ev['phase'] as String? ?? '';
        final name = ev['name'] as String? ?? '';
        final txt = ev['text'] as String? ?? '';
        if (phase=='start') setState(()=>_timeline.add(TimelineEntry(type:'action', text:'$name: $txt', expanded:true)));
        else setState(()=>_timeline.add(TimelineEntry(type:'action', text:txt, expanded:true)));
      } else if (type=='done') {
        final thinkingCombined = _timeline.where((e)=>e.type=='thinking').map((e)=>e.text).join('\n\n').trim();
        final answerCombined = _timeline.where((e)=>e.type=='text').map((e)=>e.text).join('').trim();
        for(final e in _timeline) if(e.type=='thinking') e.expanded=false;
        if (answerCombined.isNotEmpty || !gotAny) {
          final finalText = answerCombined.isNotEmpty ? answerCombined : '(готово)';
          await ChatStore.instance.addMessage(cid, 'assistant', finalText, thinking: thinkingCombined.isEmpty? null: thinkingCombined, modelKey: 'work:openai');
        }
        if (mounted) setState(()=>_timeline.clear());
        unawaited(_maybeGenerateTitle(cid));
        return;
      } else if (type=='cancelled') {
        await ChatStore.instance.addMessage(cid, 'assistant', 'Остановлено пользователем', modelKey: 'work:openai');
        if (mounted) setState(()=>_timeline.clear());
        return;
      } else if (type=='error') {
        await ChatStore.instance.addMessage(cid, 'assistant', 'Ошибка Work: ${ev['text']}', modelKey: 'work:openai');
        if (mounted) setState(()=>_timeline.clear());
        return;
      }
    }
    if (!gotAny && _timeline.isEmpty) {
      await ChatStore.instance.addMessage(cid, 'assistant', '(пустой ответ Work)', modelKey: 'work:openai');
      if (mounted) setState(()=>_timeline.clear());
    }
  }

  @override Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 860;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: isWide ? Row(children: [SizedBox(width: 280, child: _sidebar()), Expanded(child: _chatPane())])
                   : _chatPane(),
      drawer: isWide ? null : Drawer(backgroundColor: GG.bgDeep, child: _sidebar()),
    );
  }

  Widget _sidebar() {
    return Container(
      decoration: BoxDecoration(color: GG.bgDeep),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 36, height: 36, decoration: BoxDecoration(color: GG.violet, borderRadius: BorderRadius.circular(10)), child: Icon(CupertinoIcons.sparkles, color: Colors.white, size: 18)),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('GhostGem', style: TextStyle(color: GG.paper, fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.5, fontFamily: 'Baskerville')),
                Text('приватный агент', style: TextStyle(color: GG.faint, fontSize: 10, letterSpacing: 1.2, fontFamily: 'monospace')),
              ]),
              const Spacer(),
              _modeToggle(),
            ]),
            const SizedBox(height: 14),
            InkWell(
              onTap: _newChat,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: GG.paper, borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(CupertinoIcons.plus, size: 14, color: GG.bg), const SizedBox(width: 8),
                  Text('Новый чат', style: TextStyle(color: GG.bg, fontSize: 13, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
            const SizedBox(height: 10),
            _modelSelector(),
          ]),
        ),
        Expanded(child: _chats.isEmpty
          ? Center(child: Text('Нет чатов', style: TextStyle(color: GG.muted, fontSize: 13)))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _chats.length,
              itemBuilder: (_, i) {
                final c = _chats[i];
                final sel = c['id']==_chatId;
                return InkWell(
                  onTap: () async { setState(()=>_chatId=c['id'] as String); _serverChatCache=null; _attachments.clear(); await _loadMsgs(); if (!isWide(context)) Navigator.pop(context); },
                  onLongPress: ()=>_chatMenu(c),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(color: sel ? GG.violet : GG.surface, borderRadius: BorderRadius.circular(10)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text((c['title'] as String?)??'Новый чат', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: sel? GG.paper : GG.dim, fontSize: 13, fontWeight: sel?FontWeight.w600:FontWeight.w400)),
                      const SizedBox(height: 2),
                      Text(_date(c['updated_at'] as int?), style: TextStyle(color: GG.faint, fontSize: 11, fontFamily: 'monospace')),
                    ]),
                  ),
                );
              },
            )),
          Container(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Row(children: [
                _iconBtn(CupertinoIcons.settings, ()=>_openSettings()),
                const SizedBox(width: 6),
                _iconBtn(CupertinoIcons.lock_shield, ()=>Navigator.push(context, MaterialPageRoute(builder: (_)=>const KeysScreen()))),
                const SizedBox(width: 6),
                _iconBtn(CupertinoIcons.folder, ()=> _openFiles()),
                const SizedBox(width: 6),
                _iconBtn(CupertinoIcons.book, ()=>Navigator.push(context, MaterialPageRoute(builder: (_)=>const MemoryScreen()))),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                _iconBtn(CupertinoIcons.alarm, ()=>Navigator.push(context, MaterialPageRoute(builder: (_)=>const RemindersScreen()))),
                const SizedBox(width: 6),
                _iconBtn(CupertinoIcons.star, ()=>Navigator.push(context, MaterialPageRoute(builder: (_)=>const PremiumScreen()))),
                const SizedBox(width: 6),
                _iconBtn(CupertinoIcons.hammer_fill, ()=>Navigator.push(context, MaterialPageRoute(builder: (_)=>const WorkScreen()))),
                const SizedBox(width: 6),
                _iconBtn(CupertinoIcons.square_arrow_left, ()=>_logout()),
                const Spacer(),
                _accountLabel(),
              ]),
            ]),
          ),
        ]),
      );
    }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: GG.bgCard,
        title: Text('Выйти из аккаунта?', style: TextStyle(color: GG.paper)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Отмена', style: TextStyle(color: GG.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Выйти', style: TextStyle(color: GG.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AuthService.instance.logout();
    widget.onLoggedOut?.call();
  }

  Widget _accountLabel() {
    return FutureBuilder<String?>(
      future: AuthService.instance.username(),
      builder: (_, snap) {
        final name = (snap.data ?? '').isEmpty ? 'гость' : '@${snap.data}';
        return Text(
          name,
          style: TextStyle(color: GG.faint, fontSize: 10, fontFamily: 'monospace'),
        );
      },
    );
  }

  bool isWide(BuildContext c)=>MediaQuery.of(c).size.width>=860;
  String _date(int? ts){
    if (ts==null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ts*1000);
    final now = DateTime.now();
    if (d.day==now.day && d.month==now.month && d.year==now.year) return '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
    return '${d.day.toString().padLeft(2,'0')}.${d.month.toString().padLeft(2,'0')}';
  }
  Future<void> _chatMenu(Map<String,dynamic> c) async {
    final id = c['id'] as String;
    final r = await showCupertinoDialog<String>(context: context, builder: (_) => CupertinoAlertDialog(
      title: Text(c['title'] as String),
      actions: [
        CupertinoDialogAction(isDestructiveAction: true, onPressed: ()=>Navigator.pop(context,'del'), child: const Text('Удалить')),
        CupertinoDialogAction(onPressed: ()=>Navigator.pop(context,'rename'), child: const Text('Переименовать')),
        CupertinoDialogAction(onPressed: ()=>Navigator.pop(context,''), child: const Text('Отмена')),
      ],
    ));
    if (r=='del') { await ChatStore.instance.deleteChat(id); if (_chatId==id) _chatId=null; await _loadChats();}
    if (r=='rename') {
      final ctrl = TextEditingController(text: c['title'] as String);
      final nv = await showDialog<String>(context: context, builder: (_)=>AlertDialog(
        backgroundColor: GG.bgCard, title: Text('Переименовать', style: TextStyle(color: GG.paper)),
        content: TextField(controller: ctrl, style: TextStyle(color: GG.paper), autofocus: true),
        actions: [TextButton(onPressed: ()=>Navigator.pop(context), child: Text('Отмена', style: TextStyle(color: GG.muted))), TextButton(onPressed: ()=>Navigator.pop(context, ctrl.text.trim()), child: Text('Сохранить', style: TextStyle(color: GG.violet)))],
      ));
      if (nv!=null && nv.isNotEmpty) { await ChatStore.instance.renameChat(id, nv); await _loadChats();}
    }
  }
  Widget _iconBtn(IconData i, VoidCallback t)=> InkWell(onTap: t, borderRadius: BorderRadius.circular(8), child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(8)), child: Icon(i, size: 16, color: GG.dim)));

  Widget _modeToggle(){
    final m = SettingsService.instance.mode;
    final isWork = m==ChatMode.work;
    final label = switch (m) {
      ChatMode.server => 'Сервер',
      ChatMode.byok => 'BYOK',
      ChatMode.work => 'Work',
    };
    return InkWell(
      onTap: () async {
        final next = switch (m) {
          ChatMode.server => ChatMode.byok,
          ChatMode.byok => ChatMode.work,
          ChatMode.work => ChatMode.server,
        };
        await SettingsService.instance.setMode(next);
        setState((){});
        if (next==ChatMode.work) {
          final dir = await WorkService.instance.getWorkDir();
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Work: $dir')));
        } else if (next==ChatMode.byok) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('BYOK: запросы идут по ключу провайдера')));
        } else {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Чат (сервер)')));
        }
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: isWork ? GG.yellow.withValues(alpha: 0.22) : GG.surface, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(isWork ? CupertinoIcons.hammer_fill : m==ChatMode.byok ? CupertinoIcons.lock_shield_fill : CupertinoIcons.cloud_fill, size: 12, color: isWork ? GG.yellow : GG.dim),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: isWork ? GG.yellow : GG.dim, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
        ]),
      ),
    );
  }

  Widget _modeSwitcherTop(){
    final m = SettingsService.instance.mode;
    Widget btn(ChatMode mode, String label, IconData icon){
      final sel = m==mode;
      Color bg;
      Color fg;
      if (mode==ChatMode.server || mode==ChatMode.byok){ bg = sel ? GG.surface2 : GG.surface; fg = sel ? GG.paper : GG.muted; }
      else { bg = sel ? GG.yellow.withValues(alpha: 0.22) : GG.surface; fg = sel ? GG.yellow : GG.muted; }
      return Expanded(
        child: InkWell(
          onTap: () async {
            await SettingsService.instance.setMode(mode);
            setState((){});
          },
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 13, color: fg),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );
    }
    return Row(children: [
      btn(ChatMode.server, 'Сервер', CupertinoIcons.cloud_fill),
      const SizedBox(width: 6),
      btn(ChatMode.byok, 'BYOK', CupertinoIcons.lock_shield_fill),
      const SizedBox(width: 6),
      btn(ChatMode.work, 'Work', CupertinoIcons.hammer_fill),
    ]);
  }

  Widget _modelSelector(){
    final cur = SettingsService.instance.currentModel;
    final short = cur.split(':').last;
    final mode = SettingsService.instance.mode;
    final isWork = mode==ChatMode.work;
    return InkWell(
      onTap: () async {
        final sel = await Navigator.push<String>(context, MaterialPageRoute(builder: (_)=> ModelsScreen(initial: cur, cache: _modelsCache)));
        if (sel!=null) { await SettingsService.instance.setCurrentModel(sel); setState((){}); }
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: isWork? GG.green : GG.iris, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(child: Text(short, style: TextStyle(color: GG.paper, fontSize: 12, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          Icon(CupertinoIcons.chevron_up_chevron_down, size: 12, color: GG.muted),
        ]),
      ),
    );
  }

  void _openSettings(){
    showModalBottomSheet(context: context, backgroundColor: Colors.transparent, isScrollControlled: true, builder: (_)=> _SettingsSheet(onChanged: ()=>setState((){})));
  }

  // Wrap pane with Focus for Enter and Ctrl+V
  Widget _chatPane(){
    return DropTarget(
      onDragDone: (details) async {
        for(final f in details.files){
          try{
            final bytes = await File(f.path).readAsBytes();
            final mime = _guessMime(f.name);
            final isMedia = mime.startsWith('image/') || mime.startsWith('video/') || mime.startsWith('audio/');
            if (!_canAddAttachment(isMedia)) break;
            setState(()=>_attachments.add(_Attachment(name: f.name, bytes: bytes, mime: mime, path: f.path)));
            if (isMedia) setState(()=>_forceVision=true);
          }catch(_){}
        }
      },
      onDragEntered: (_)=>setState(()=>_dragOver=true),
      onDragExited: (_)=>setState(()=>_dragOver=false),
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event){
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
              _send();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.keyV && HardwareKeyboard.instance.isControlPressed) {
              _handlePaste();
            }
          }
          return KeyEventResult.ignored;
        },
        child: Container(
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [GG.bg, GG.bgDeep])),
        child: Column(children: [
          Container(
            padding: EdgeInsets.fromLTRB(12, MediaQuery.of(context).padding.top+8, 12, 12),
            decoration: BoxDecoration(color: GG.bgDeep),
            child: Row(children: [
              if (MediaQuery.of(context).size.width < 860) Builder(builder: (c)=> IconButton(icon: Icon(CupertinoIcons.line_horizontal_3, color: GG.paper), onPressed: ()=>Scaffold.of(c).openDrawer())),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('GhoGem', style: TextStyle(color: GG.paper, fontSize: 16, fontWeight: FontWeight.w800, fontFamily: 'Baskerville')),
                FutureBuilder<String>(
                future: SettingsService.instance.mode==ChatMode.work ? WorkService.instance.getWorkDir() : Future.value(''),
                builder: (_, snap){
                  final m = SettingsService.instance.mode;
                  String txt;
                  if (m==ChatMode.work) txt = 'Work · ${snap.data ?? ''} · Pollinations proxy';
                  else if (m==ChatMode.byok) txt = 'BYOK · ${SettingsService.instance.currentModel.split(':').last}';
                  else txt = 'Сервер · ${SettingsService.instance.currentModel.split(':').last} · лимиты';
                  return Text(txt, style: TextStyle(color: GG.faint, fontSize: 11, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis);
                },
              ),
              ])),
              IconButton(icon: Icon(CupertinoIcons.add, color: GG.paper), onPressed: _newChat, tooltip: 'Новый чат'),
              PopupMenuButton<String>(icon: Icon(CupertinoIcons.ellipsis, color: GG.paper), onSelected: (v) async {
                if (v=='clear') { if (_chatId!=null) {await ChatStore.instance.clearChat(_chatId!); await _loadMsgs();}}
                if (v=='delete') { if (_chatId!=null) {await ChatStore.instance.deleteChat(_chatId!); _chatId=null; await _loadChats();}}
              }, itemBuilder: (_)=>[
                PopupMenuItem(value: 'clear', child: Text('Очистить чат', style: TextStyle(color: GG.text))),
                PopupMenuItem(value: 'delete', child: Text('Удалить чат', style: TextStyle(color: GG.red))),
              ]),
            ]),
          ),
          // Переключатель режимов сверху чата
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: GG.bgDeep,
            child: _modeSwitcherTop(),
          ),
          Expanded(child: _msgs.isEmpty && !_sending && _streamingAnswer.isEmpty && _timeline.isEmpty
            ? _emptyState()
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(vertical: 12),
                itemCount: _msgs.length + ((_sending && (_timeline.isNotEmpty || _streamingAnswer.isNotEmpty)) ? 1 : 0),
                itemBuilder: (_, i){
                  if (i < _msgs.length) {
                    final m = _msgs[i];
                    final atts = m['attachments'] is List ? (m['attachments'] as List).cast<Map<String,dynamic>>() : null;
                    return MessageBubble(role: m['role'] as String, content: m['content'] as String, thinking: m['thinking'] as String?, modelKey: m['model_key'] as String?, attachments: atts);
                  } else {
                    if (_timeline.isNotEmpty) {
                      return TimelineBubble(entries: _timeline, modelKey: SettingsService.instance.currentModel);
                    }
                    if (_streamingAnswer.isEmpty && _streamingThinking==null) {
                      return Padding(padding: const EdgeInsets.all(16), child: Row(children: [SizedBox(width:16,height:16,child: CircularProgressIndicator(strokeWidth:2, color: GG.violet)), const SizedBox(width: 10), Text('Думает…', style: TextStyle(color: GG.muted, fontSize: 13))]));
                    }
                    return MessageBubble(role: 'assistant', content: _streamingAnswer.isEmpty ? '' : '$_streamingAnswer ', thinking: _streamingThinking, modelKey: SettingsService.instance.currentModel);
                  }
                },
              )),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            color: GG.bgDeep,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                _toggleChip('Поиск', CupertinoIcons.search, _webSearch, (v)=>setState(()=>_webSearch=v)),
                const SizedBox(width: 6),
                _toggleChip('Зрение', CupertinoIcons.eye, _forceVision, (v)=>setState(()=>_forceVision=v)),
                const SizedBox(width: 6),
                _toggleChip('Озвучка', CupertinoIcons.speaker_2, _forceTts, (v)=>setState(()=>_forceTts=v)),
                const SizedBox(width: 6),
                _toggleChip('Транскрипт', CupertinoIcons.mic, _forceStt, (v)=>setState(()=>_forceStt=v)),
                const SizedBox(width: 12),
                Text('Enter — отправить, Shift+Enter — новая строка', style: TextStyle(color: GG.faint, fontSize: 10, fontFamily: 'monospace')),
              ]),
            ),
          ),
          if (_attachments.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              color: GG.bgDeep,
              child: SizedBox(
                height: 72,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _attachments.length,
                  separatorBuilder: (_,__)=>const SizedBox(width: 8),
                  itemBuilder: (_, i){
                    final a = _attachments[i];
                    return Stack(children: [
                      Container(
                        width: 72, height: 72,
                        decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(10)),
                        child: a.isImage
                          ? ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(a.bytes, fit: BoxFit.cover))
                          : Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(CupertinoIcons.doc, color: GG.iris, size: 22), const SizedBox(height: 4), Text(a.name, style: TextStyle(color: GG.muted, fontSize: 9), maxLines: 1, overflow: TextOverflow.ellipsis)])),
                      ),
                      Positioned(top: 4, right: 4, child: InkWell(
                        onTap: ()=>setState(()=>_attachments.removeAt(i)),
                        child: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle), child: Icon(Icons.close, size: 12, color: Colors.white)),
                      )),
                      Positioned(bottom: 2, left: 4, right: 4, child: Text(a.name, style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center)),
                    ]);
                  },
                ),
              ),
            ),
          Container(
            padding: EdgeInsets.fromLTRB(12, 6, 12, 12 + MediaQuery.of(context).padding.bottom),
            decoration: BoxDecoration(color: GG.bgDeep),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(child: Container(
                decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(12)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(child: TextField(
                    controller: _ctrl, focusNode: _focus, minLines: 1, maxLines: 6, style: TextStyle(color: GG.paper, fontSize: 14),
                    decoration: InputDecoration(hintText: 'Сообщение…', hintStyle: TextStyle(color: GG.faint, fontSize: 13), border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
                    textInputAction: TextInputAction.newline,
                  )),
                  IconButton(icon: Icon(CupertinoIcons.paperclip, color: GG.muted, size: 20), onPressed: ()=>_pickFile(), tooltip: 'Файл'),
                  IconButton(icon: Icon(CupertinoIcons.camera, color: GG.muted, size: 20), onPressed: ()=>_pickPhoto(), tooltip: 'Фото'),
                ]),
              )),
              const SizedBox(width: 8),
              InkWell(
                onTap: _sending ? _stop : _send,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(color: _sending ? GG.red.withValues(alpha: 0.85) : GG.violet, borderRadius: BorderRadius.circular(14)),
                  child: Icon(_sending? CupertinoIcons.stop_fill : CupertinoIcons.paperplane_fill, color: Colors.white, size: 18),
                ),
              ),
            ]),
          ),
        ]),
      ),
    ),
  );
  }

  Widget _emptyState(){
    final mode = SettingsService.instance.mode;
    final isWork = mode==ChatMode.work;
    return Center(child: Padding(padding: const EdgeInsets.all(24), child: GlassCard(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(CupertinoIcons.sparkles, size: 36, color: GG.violet.withValues(alpha: 0.8)),
      const SizedBox(height: 12),
      Text('GhoGem — твой агент', style: TextStyle(color: GG.paper, fontSize: 18, fontWeight: FontWeight.w700, fontFamily: 'Baskerville')),
      const SizedBox(height: 8),
      Text(isWork
        ? 'Work работает с локальными файлами и Pollinations через серверный SOCKS proxy.'
        : mode==ChatMode.byok
          ? 'Запросы идут напрямую к выбранному провайдеру с твоим ключом. Pollinations всегда использует серверный SOCKS proxy.'
          : 'Запросы идут через GhoGem API с серверными ключами и лимитами.',
        textAlign: TextAlign.center, style: TextStyle(color: GG.muted, fontSize: 13, height: 1.5)),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
        _suggest('Напиши код на Flutter'),
        _suggest('Проанализируй файл'),
        _suggest('Поищи в сети свежие новости'),
        _suggest('Создай напоминание'),
      ]),
    ]))));
  }
  Widget _suggest(String t)=> InkWell(
    onTap: (){ _ctrl.text=t; _focus.requestFocus();},
    borderRadius: BorderRadius.circular(20),
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(20)), child: Text(t, style: TextStyle(color: GG.dim, fontSize: 12))),
  );

  void _openFiles(){
    if(_chatId==null) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Сначала создай чат'))); return; }
    Navigator.push(context, MaterialPageRoute(builder: (_)=> FilesScreen(chatId: _chatId!)));
  }
  Widget _toggleChip(String label, IconData icon, bool value, ValueChanged<bool> onChanged){
    return InkWell(
      onTap: ()=>onChanged(!value),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: value ? GG.violet : GG.surface, borderRadius: BorderRadius.circular(20)),
        child: Row(children: [Icon(icon, size: 12, color: value? Colors.white : GG.dim), const SizedBox(width: 6), Text(label, style: TextStyle(color: value? Colors.white : GG.dim, fontSize: 11, fontWeight: FontWeight.w600))]),
      ),
    );
  }
  Future<void> _handlePaste() async {
    try{
      final img = await Pasteboard.image;
      if (img!=null && img.isNotEmpty) {
        if (!_canAddAttachment(true)) return;
        final name = 'paste_${DateTime.now().millisecondsSinceEpoch}.png';
        setState(()=>_attachments.add(_Attachment(name: name, bytes: img, mime: 'image/png')));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Вставлено изображение: $name')));
        return;
      }
    }catch(_){}
  }
  Future<void> _pickFile() async {
    if(_chatId==null) { await _newChat(); }
    try{
      final f = await openFile(acceptedTypeGroups: const [XTypeGroup(label: 'any')]);
      if(f==null) return;
      final bytes = await f.readAsBytes();
      final mime = _guessMime(f.name);
      final isMedia = mime.startsWith('image/') || mime.startsWith('video/') || mime.startsWith('audio/');
      if (!_canAddAttachment(isMedia)) return;
      setState(()=>_attachments.add(_Attachment(name: f.name, bytes: bytes, mime: mime, path: f.path)));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Файл прикреплён: ${f.name}')));
    }catch(e){ if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));}
  }
  Future<void> _pickPhoto() async {
    if(_chatId==null) await _newChat();
    if (!_canAddAttachment(true)) return;
    try{
      final picker = ImagePicker();
      final x = await picker.pickImage(source: ImageSource.gallery);
      if(x==null) return;
      final bytes = await x.readAsBytes();
      setState(()=>_attachments.add(_Attachment(name: x.name, bytes: bytes, mime: 'image/jpeg', path: x.path)));
      setState(()=>_forceVision=true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Фото прикреплено — нажми Enter для отправки')));
    }catch(e){ if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));}
  }
  bool _canAddAttachment(bool isMedia){
    final mediaCount = _attachments.where((a)=>a.isImage || a.mime.startsWith('video/') || a.mime.startsWith('audio/')).length;
    final fileCount = _attachments.length - mediaCount;
    if (_attachments.length >= 30) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Лимит: всего 30 вложений'))); return false; }
    if (isMedia && mediaCount >= 20) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Лимит 20 медиа'))); return false; }
    if (!isMedia && fileCount >= 25) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Лимит 25 файлов'))); return false; }
    return true;
  }
  String _guessMime(String name){
    final ext = name.split('.').last.toLowerCase();
    if (['jpg','jpeg'].contains(ext)) return 'image/jpeg';
    if (ext=='png') return 'image/png';
    if (ext=='webp') return 'image/webp';
    if (ext=='gif') return 'image/gif';
    if (ext=='mp4') return 'video/mp4';
    if (ext=='mp3') return 'audio/mpeg';
    if (ext=='pdf') return 'application/pdf';
    return 'application/octet-stream';
  }
}

class _SettingsSheet extends StatelessWidget {
  final VoidCallback onChanged;
  const _SettingsSheet({required this.onChanged});
  @override Widget build(BuildContext context){
    final s = SettingsService.instance;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(color: GG.bgDeep, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 36, height: 4, decoration: BoxDecoration(color: GG.faint, borderRadius: BorderRadius.circular(2)), margin: const EdgeInsets.only(bottom: 16)),
        Text('Настройки GhoGem', style: TextStyle(color: GG.paper, fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        _row('Режим', s.mode==ChatMode.work ? 'Work' : s.mode==ChatMode.byok ? 'BYOK (свои ключи)' : 'Сервер (лимиты)'),
        const SizedBox(height: 8),
        Text('Кастомный системный промпт (для агента):', style: TextStyle(color: GG.muted, fontSize: 12)),
        const SizedBox(height: 6),
        _PromptField(),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: GlassButton(label: 'Ключи BYOK', icon: CupertinoIcons.lock_shield, onTap: (){ Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_)=>const KeysScreen())); })),
          const SizedBox(width: 8),
          Expanded(child: GlassButton(label: 'Модели', icon: CupertinoIcons.square_stack_3d_up, onTap: (){ Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_)=> ModelsScreen(initial: s.currentModel))); })),
        ]),
        const SizedBox(height: 8),
        Text('Сервер: ${GG.apiGhogem}\nEnter — отправить, Shift+Enter — новая строка. Ctrl+V — вставить картинку.', style: TextStyle(color: GG.faint, fontSize: 11, fontFamily: 'monospace')),
      ]),
    );
  }
  Widget _row(String k, String v)=> Row(children: [Text(k, style: TextStyle(color: GG.muted, fontSize: 12)), const Spacer(), Flexible(child: Text(v, style: TextStyle(color: GG.paper, fontSize: 12), textAlign: TextAlign.right))]);
}

class _PromptField extends StatefulWidget { @override State<_PromptField> createState()=> _PromptFieldState(); }
class _PromptFieldState extends State<_PromptField>{
  late final _c = TextEditingController(text: SettingsService.instance.customPrompt);
  @override Widget build(BuildContext context){
    return TextField(
      controller: _c, maxLines: 3, style: TextStyle(color: GG.paper, fontSize: 13),
      decoration: InputDecoration(hintText: 'Например: Ты — строгий редактор…', hintStyle: TextStyle(color: GG.faint), filled: true, fillColor: GG.surface, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)),
      onSubmitted: (v) async { await SettingsService.instance.setCustomPrompt(v.trim()); },
    );
  }
}
