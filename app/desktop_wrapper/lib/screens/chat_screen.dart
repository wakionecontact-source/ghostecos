// ChatScreen — открытый DM-чат. Native, без WebView.
//
// AUTO-2/AUTO-3: текст + картинки + голосовые, reply/edit/delete/forward/react.
// Все медиа шифруются на клиенте AES-256, blob аплоадится зашифрованным.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../services/chat_repo.dart';
import '../services/db_service.dart';
import '../services/auth_service.dart';
import '../widgets/glass.dart';
import 'profile_screen.dart';

class ChatScreen extends StatefulWidget {
  final String peer;
  final String displayName;

  /// Если задан — после открытия проскролить и подсветить сообщение с этим sid.
  final int? highlightSid;
  const ChatScreen({
    super.key,
    required this.peer,
    required this.displayName,
    this.highlightSid,
  });
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _imagePicker = ImagePicker();
  final _recorder = AudioRecorder();

  bool _sending = false;
  String? _myUsername;
  int? _highlightSid;
  Timer? _highlightTimer;

  StoredMessage? _replyTo;
  StoredMessage? _editing;

  bool _recording = false;
  int _recordStartedAt = 0;
  Timer? _recordTicker;
  Duration _recordDur = Duration.zero;
  final List<double> _recWave = [];
  bool _handsFree = false; // true = тап-запись (ждём кнопку), false = удержание

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Когда возвращаемся на экран — тянем свежее из обоих каналов.
      ChatRepo.instance.fetchPending();
      ChatRepo.instance.fetchPendingSealed();
    }
  }

  Future<void> _init() async {
    _myUsername = await AuthService.username();
    await ChatRepo.instance.markChatRead(widget.peer);
    // Сразу проверяем свежие сообщения от веба (Sealed Sender 2.0) и legacy.
    ChatRepo.instance.fetchPending();
    ChatRepo.instance.fetchPendingSealed();
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.highlightSid != null) {
        _scrollToSid(widget.highlightSid!);
        setState(() => _highlightSid = widget.highlightSid);
        _highlightTimer?.cancel();
        _highlightTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _highlightSid = null);
        });
      } else {
        _scrollToBottom(false);
      }
    });
  }

  void _scrollToSid(int sid) {
    final msgs = ChatRepo.instance.messagesNotifier(widget.peer).value;
    final idx = msgs.indexWhere((m) => m.sid == sid);
    if (idx < 0 || !_scrollCtrl.hasClients) return;
    final approx = (idx * 64.0).clamp(
      0.0,
      _scrollCtrl.position.maxScrollExtent,
    );
    _scrollCtrl.animateTo(
      approx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _highlightTimer?.cancel();
    _recordTicker?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    try {
      _recorder.dispose();
    } catch (_) {}
    super.dispose();
  }

  void _scrollToBottom(bool animate) {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position.maxScrollExtent;
    if (animate) {
      _scrollCtrl.animateTo(
        pos,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _scrollCtrl.jumpTo(pos);
    }
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    final replyTo = _replyTo;
    final editing = _editing;
    // Чистим поле СРАЗУ: текст уходит в pending-бабл, бар свободен (не висит с
    // текстом, пока грузится отправка). При ошибке — вернём текст и контекст.
    _inputCtrl.clear();
    setState(() {
      _sending = true;
      _replyTo = null;
      _editing = null;
    });
    try {
      if (editing != null) {
        await ChatRepo.instance.editDmMessage(
          toUsername: widget.peer,
          sid: editing.sid,
          newText: text,
        );
      } else {
        await ChatRepo.instance.sendDmText(
          widget.peer,
          text,
          replyTo: replyTo?.sid,
          replyPreview: replyTo == null ? null : _msgPreview(replyTo),
        );
      }
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToBottom(true),
      );
    } catch (e) {
      // Вернуть текст/ответ/правку, чтобы можно было переотправить.
      _inputCtrl.text = text;
      setState(() {
        _replyTo = replyTo;
        _editing = editing;
      });
      _snack('Не отправилось: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _pickAndSendImage(ImageSource src) async {
    Navigator.maybePop(context);
    try {
      final x = await _imagePicker.pickImage(source: src, imageQuality: 85);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      await ChatRepo.instance.sendDmFile(
        toUsername: widget.peer,
        bytes: bytes,
        mime: 'image/jpeg',
        fileName: x.name,
      );
    } catch (e) {
      _snack('Картинка не отправилась: $e');
    }
  }

  Future<void> _pickAndSendVideo() async {
    Navigator.maybePop(context);
    try {
      final x = await _imagePicker.pickVideo(source: ImageSource.gallery);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      await ChatRepo.instance.sendDmFile(
        toUsername: widget.peer,
        bytes: bytes,
        mime: 'video/mp4',
        fileName: x.name,
      );
    } catch (e) {
      _snack('Видео не отправилось: $e');
    }
  }

  Future<void> _openAttachSheet() async {
    HapticFeedback.selectionClick();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
            radius: GE.radiusLg,
            child: Wrap(
              children: [
                _attachTile(
                  Icons.camera_alt,
                  'Камера',
                  () => _pickAndSendImage(ImageSource.camera),
                ),
                _attachTile(
                  Icons.photo_library,
                  'Галерея',
                  () => _pickAndSendImage(ImageSource.gallery),
                ),
                _attachTile(Icons.videocam, 'Видео', _pickAndSendVideo),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _attachTile(IconData icon, String label, VoidCallback onTap) {
    return SizedBox(
      width: 96,
      height: 96,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(GE.radiusMd),
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
                ),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(color: GE.text, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startRecording({bool handsFree = false}) async {
    if (_recording) return;
    try {
      final has = await _recorder.hasPermission();
      if (!has) {
        _snack('Нет разрешения на микрофон');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/ghost_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      // Сжатие на устройстве: голосу хватает 24кГц/32кбит — файл в разы меньше.
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 24000,
          numChannels: 1,
          bitRate: 32000,
        ),
        path: path,
      );
      _recordStartedAt = DateTime.now().millisecondsSinceEpoch;
      setState(() {
        _recording = true;
        _handsFree = handsFree;
        _recordDur = Duration.zero;
        _recWave.clear();
      });
      HapticFeedback.lightImpact();
      _recordTicker?.cancel();
      // 100мс: тикаем длительность + копим амплитуду для вейвформы.
      _recordTicker = Timer.periodic(const Duration(milliseconds: 100), (
        _,
      ) async {
        if (!mounted) return;
        double norm = 0.25;
        try {
          final amp = await _recorder.getAmplitude();
          norm = ((amp.current.clamp(-45.0, 0.0)) + 45.0) / 45.0;
        } catch (_) {}
        if (!mounted) return;
        setState(() {
          _recordDur = Duration(
            milliseconds:
                DateTime.now().millisecondsSinceEpoch - _recordStartedAt,
          );
          _recWave.add(norm);
        });
      });
    } catch (e) {
      _snack('Запись не стартовала: $e');
    }
  }

  Future<void> _stopAndSendRecording({bool cancel = false}) async {
    if (!_recording) return;
    _recordTicker?.cancel();
    try {
      final path = await _recorder.stop();
      setState(() => _recording = false);
      if (cancel || path == null) return;
      final file = File(path);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      final durSec = (_recordDur.inMilliseconds / 1000).round();
      final waveform = _downsampleWave(_recWave, 40);
      await ChatRepo.instance.sendDmFile(
        toUsername: widget.peer,
        bytes: bytes,
        mime: 'audio/m4a',
        fileName: 'voice.m4a',
        voice: true,
        duration: durSec,
        waveform: waveform,
      );
      try {
        await file.delete();
      } catch (_) {}
    } catch (e) {
      _snack('Голосовое не отправилось: $e');
    }
  }

  /// Усредняем сырые амплитуды в [target] полосок (компактная вейвформа в payload).
  List<double> _downsampleWave(List<double> raw, int target) {
    if (raw.isEmpty) return const [];
    if (raw.length <= target) {
      return raw.map((v) => double.parse(v.toStringAsFixed(2))).toList();
    }
    final out = <double>[];
    final bucket = raw.length / target;
    for (var i = 0; i < target; i++) {
      final start = (i * bucket).floor();
      final end = ((i + 1) * bucket).floor().clamp(start + 1, raw.length);
      double sum = 0;
      for (var j = start; j < end; j++) {
        sum += raw[j];
      }
      out.add(double.parse((sum / (end - start)).toStringAsFixed(2)));
    }
    return out;
  }

  Future<void> _openBubbleMenu(StoredMessage m) async {
    HapticFeedback.mediumImpact();
    final mine = m.fromMe;
    final canEdit = mine && m.filePayload == null && !m.deleted;
    final res = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            radius: GE.radiusLg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ReactionsBar(onPick: (e) => Navigator.pop(ctx, 'react:$e')),
                Divider(height: 1, color: GE.glassBorder),
                _menuItem(ctx, Icons.reply, 'Ответить', 'reply'),
                _menuItem(ctx, Icons.forward, 'Переслать', 'forward'),
                if (canEdit)
                  _menuItem(ctx, Icons.edit, 'Редактировать', 'edit'),
                _menuItem(ctx, Icons.copy, 'Копировать', 'copy'),
                if (mine && !m.deleted)
                  _menuItem(
                    ctx,
                    Icons.delete_outline,
                    'Удалить',
                    'delete',
                    danger: true,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (res == null || !mounted) return;
    if (res.startsWith('react:')) {
      final emoji = res.substring('react:'.length);
      try {
        await ChatRepo.instance.reactDmMessage(
          toUsername: widget.peer,
          sid: m.sid,
          emoji: emoji,
        );
      } catch (e) {
        _snack('Не вышло: $e');
      }
      return;
    }
    switch (res) {
      case 'reply':
        setState(() => _replyTo = m);
        break;
      case 'edit':
        setState(() {
          _editing = m;
          _inputCtrl.text = m.text;
          _inputCtrl.selection = TextSelection.collapsed(offset: m.text.length);
        });
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        _snack('Скопировано');
        break;
      case 'delete':
        try {
          await ChatRepo.instance.deleteDmMessage(
            toUsername: widget.peer,
            sid: m.sid,
          );
        } catch (e) {
          _snack('Не удалилось: $e');
        }
        break;
      case 'forward':
        await _showForwardPicker(m);
        break;
    }
  }

  Widget _menuItem(
    BuildContext ctx,
    IconData icon,
    String label,
    String value, {
    bool danger = false,
  }) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      borderRadius: BorderRadius.circular(GE.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 18, color: danger ? GE.red : GE.text),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(color: danger ? GE.red : GE.text)),
          ],
        ),
      ),
    );
  }

  Future<void> _showForwardPicker(StoredMessage m) async {
    final dialogs = ChatRepo.instance.dialogsNotifier.value
        .where((d) => d.username != widget.peer && !d.username.startsWith('g:'))
        .toList();
    final target = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            radius: GE.radiusLg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Переслать кому?',
                      style: TextStyle(
                        color: GE.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                for (final d in dialogs)
                  InkWell(
                    onTap: () => Navigator.pop(ctx, d.username),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: GE.primary2,
                            child: const Icon(
                              Icons.person,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '@${d.username}',
                              style: TextStyle(color: GE.text),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (dialogs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'Нет других чатов',
                      style: TextStyle(color: GE.sub),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (target == null || !mounted) return;
    try {
      await ChatRepo.instance.forwardDmMessage(original: m, toUsername: target);
      _snack('Переслано в @$target');
    } catch (e) {
      _snack('Не переслалось: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final notif = ChatRepo.instance.messagesNotifier(widget.peer);
    final isGroup = widget.peer.startsWith('g:');
    // Прозрачная фрост-шапка: контент скроллит ЗА неё (extendBodyBehindAppBar),
    // верхний отступ ленты = статус-бар + высота шапки.
    final headerPad = MediaQuery.of(context).padding.top + 64 + 8;
    return MeshBackground(
      // Mesh-обои: механика 1-в-1 с web mesh.js (частицы + сеть линий +
      // 3-слойный градиент). Шапка/композер-стекло размывают его сверху.
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        // Контент скроллит ЗА шапку → фрост размывает его = прозрачное стекло.
        extendBodyBehindAppBar: true,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          // Прозрачная фрост-шапка (лакшери): глубокий тинт, тает книзу + тёплый
          // золотистый разделитель снизу.
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 9, sigmaY: 9),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Color(0x2BD4B88C), width: 0.7),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xB31C1530),
                      Color(0x661C1530),
                      Color(0x001C1530),
                    ],
                    stops: [0.0, 0.6, 1.0],
                  ),
                ),
                child: _ChatHeader(
                  peer: widget.peer,
                  displayName: widget.displayName,
                  isGroup: isGroup,
                ),
              ),
            ),
          ),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    Expanded(
                      // Матовая подложка над mesh: mesh просвечивает, но сообщения читаемы.
                      // Без BackdropFilter на большом скролле — оптимизация (фрост даёт
                      // композер ниже + бабблы-стекло поверх).
                      child: ColoredBox(
                        color: GE.bg.withValues(alpha: 0.0),
                        child: ValueListenableBuilder<List<StoredMessage>>(
                          valueListenable: notif,
                          builder: (_, msgs, __) {
                            if (msgs.isEmpty) return _empty();
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted && _scrollCtrl.hasClients) {
                                final at = _scrollCtrl.position.pixels;
                                final max =
                                    _scrollCtrl.position.maxScrollExtent;
                                if (max - at < 200) _scrollToBottom(true);
                              }
                            });
                            return ListView.builder(
                              controller: _scrollCtrl,
                              padding: EdgeInsets.fromLTRB(
                                12,
                                headerPad,
                                12,
                                96,
                              ),
                              itemCount: msgs.length,
                              itemBuilder: (_, i) {
                                final m = msgs[i];
                                final prev = i > 0 ? msgs[i - 1] : null;
                                // Линия при смене автора + пилюля-дата при смене дня.
                                final newSender =
                                    prev != null && prev.fromMe != m.fromMe;
                                final newDay =
                                    prev == null ||
                                    !_msgSameDay(m.createdAt, prev.createdAt);
                                final bubble = Dismissible(
                                  key: ValueKey(
                                    'msg_${m.sid}_${m.tempSid ?? ""}',
                                  ),
                                  direction: DismissDirection.startToEnd,
                                  confirmDismiss: (_) async {
                                    // Не «исчезаем», а только триггерим reply.
                                    setState(() => _replyTo = m);
                                    HapticFeedback.selectionClick();
                                    return false;
                                  },
                                  background: Container(
                                    alignment: Alignment.centerLeft,
                                    padding: const EdgeInsets.only(left: 24),
                                    child: Icon(
                                      Icons.reply,
                                      color: GE.primary,
                                      size: 22,
                                    ),
                                  ),
                                  child: GestureDetector(
                                    onLongPress: () => _openBubbleMenu(m),
                                    onDoubleTap: () async {
                                      try {
                                        await ChatRepo.instance.reactDmMessage(
                                          toUsername: widget.peer,
                                          sid: m.sid,
                                          emoji: '❤',
                                        );
                                      } catch (_) {}
                                    },
                                    child: _Bubble(
                                      m,
                                      myUsername: _myUsername,
                                      highlighted: m.sid == _highlightSid,
                                      prevSame:
                                          i > 0 &&
                                          msgs[i - 1].fromMe == m.fromMe,
                                    ),
                                  ),
                                );
                                if (!newSender && !newDay) return bubble;
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (newDay) _dateChip(m.createdAt),
                                    if (newSender && !newDay)
                                      Center(
                                        child: Container(
                                          width: 44,
                                          height: 1,
                                          margin: const EdgeInsets.symmetric(
                                            vertical: 7,
                                          ),
                                          color: GE.borderStrong,
                                        ),
                                      ),
                                    bubble,
                                  ],
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Фрост-композер снизу: лента уходит ЗА него → стекло размывает (как шапка).
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_replyTo != null || _editing != null) _replyEditBar(),
                    _composer(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // «Мыло» под шапкой: BackdropFilter размывает сообщения, уезжающие вверх под
  // шапку, + градиент-тинт для мягкого края (не резкая прямая линия). Раньше
  // дико лагало НЕ из-за этого блюра (он мелкий), а из-за расшифровки фото на
  // главном потоке — её вынесли в изолят, так что блюр теперь по карману.
  // Стекло-фон ПОД шапкой. ВИДИМЫЙ слой: светлый тинт (тёмное-на-тёмном не
  // читается, фон чата тёмный) + BackdropFilter для frost. Низ ПЛАВНО
  // растворяется 4-ступенчатым градиентом альфы (без ShaderMask — он на этой
  // сборке гасит сам блюр, стекло пропадало).
  Widget _topBlurFade() {
    final tint = Color.alphaBlend(
      Colors.white.withValues(alpha: 0.10),
      GE.bgDeep,
    );
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: 58,
      child: IgnorePointer(
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    tint.withValues(alpha: 0.95),
                    tint.withValues(alpha: 0.62),
                    tint.withValues(alpha: 0.26),
                    tint.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.4, 0.72, 1.0],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _replyEditBar() {
    final m = _editing ?? _replyTo;
    final isEdit = _editing != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        radius: GE.radiusMd,
        child: Row(
          children: [
            Icon(
              isEdit ? Icons.edit : Icons.reply,
              size: 16,
              color: GE.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEdit ? 'Редактирование' : 'Ответ',
                    style: TextStyle(
                      color: GE.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _msgPreview(m),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, size: 18, color: GE.sub),
              onPressed: () {
                setState(() {
                  _replyTo = null;
                  if (isEdit) {
                    _editing = null;
                    _inputCtrl.clear();
                  }
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: GlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 40, color: GE.primary),
            const SizedBox(height: 10),
            Text(
              'Напиши первое сообщение',
              style: TextStyle(color: GE.text, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Всё шифруется на твоём устройстве',
              style: TextStyle(color: GE.sub, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    final hasText = _inputCtrl.text.trim().isNotEmpty;
    // НЕ добавляем viewInsets.bottom: Scaffold с resizeToAvoidBottomInset=true
    // (default) уже сжимает body над клавиатурой. Если добавить bottomInset
    // тут — composer улетает на высоту клавиатуры дважды.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            // Стекло как шапка: тёмный тинт тает кверху + золотистая кромка сверху.
            border: Border(
              top: BorderSide(color: Color(0x2BD4B88C), width: 0.7),
            ),
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xCC1C1530), Color(0x801C1530), Color(0x141C1530)],
              stops: [0.0, 0.6, 1.0],
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Лево: при записи — отмена (delete), иначе — вложения.
                _recording
                    ? IconButton(
                        icon: Icon(Icons.delete, color: GE.red),
                        onPressed: () => _stopAndSendRecording(cancel: true),
                      )
                    : IconButton(
                        icon: Icon(Icons.attach_file, color: GE.sub),
                        onPressed: _sending ? null : _openAttachSheet,
                      ),
                // Середина: при записи — таймер+живая вейвформа, иначе поле ввода.
                Expanded(
                  child: _recording
                      ? _recordingMiddle()
                      : TextField(
                          controller: _inputCtrl,
                          minLines: 1,
                          maxLines: 6,
                          style: TextStyle(color: GE.text, fontSize: 15),
                          cursorColor: GE.primary,
                          textInputAction: TextInputAction.newline,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'Сообщение',
                            hintStyle: TextStyle(color: GE.sub),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 10,
                            ),
                          ),
                        ),
                ),
                // Право: текст→отправка; запись-hands-free→отправка голосового;
                // иначе микрофон (тап=hands-free; удержание→отпуск=отправка).
                Material(
                  color: Colors.transparent,
                  child: hasText
                      ? InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _sending ? null : _send,
                          child: _circleBtn(
                            _sending
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.send,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                          ),
                        )
                      : (_recording && _handsFree)
                      ? GestureDetector(
                          onTap: () => _stopAndSendRecording(),
                          child: _circleBtn(
                            const Icon(
                              Icons.send,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        )
                      : GestureDetector(
                          onTap: () {
                            if (!_recording) _startRecording(handsFree: true);
                          },
                          onLongPressStart: (_) {
                            if (!_recording) _startRecording(handsFree: false);
                          },
                          onLongPressEnd: (_) {
                            if (_recording && !_handsFree) {
                              _stopAndSendRecording();
                            }
                          },
                          child: _circleBtn(
                            const Icon(
                              Icons.mic,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _circleBtn(Widget child) => Container(
    width: 42,
    height: 42,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
    ),
    alignment: Alignment.center,
    child: child,
  );

  // Середина композера при записи: точка + таймер + живая вейвформа.
  // delete (отмена) — левая кнопка, send — правая (см. _composer).
  Widget _recordingMiddle() {
    final mm = _recordDur.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = _recordDur.inSeconds.remainder(60).toString().padLeft(2, '0');
    final recent = _recWave.length > 40
        ? _recWave.sublist(_recWave.length - 40)
        : _recWave;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(Icons.fiber_manual_record, color: GE.red, size: 12),
          const SizedBox(width: 6),
          Text(
            '$mm:$ss',
            style: TextStyle(
              color: GE.text,
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 24,
              child: CustomPaint(
                painter: _WaveformPainter(
                  bars: recent.isEmpty ? const [0.1] : recent,
                  progress: 1.0,
                  bg: GE.primary.withValues(alpha: 0.4),
                  fill: GE.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
class _ReactionsBar extends StatelessWidget {
  final void Function(String emoji) onPick;
  const _ReactionsBar({required this.onPick});
  // Server-сторона хранит raw-emoji строкой — сохраняем совместимость.
  // Визуально рендерим Material иконку для каждого (одинаково на всех ОС).
  static const _picks = <_Pick>[
    _Pick('❤', Icons.favorite, Color(0xFFef4444)),
    _Pick('👍', Icons.thumb_up, Color(0xFF60a5fa)),
    _Pick('😂', Icons.sentiment_very_satisfied, Color(0xFFfacc15)),
    _Pick('😮', Icons.sentiment_neutral, Color(0xFFfb923c)),
    _Pick('😢', Icons.sentiment_dissatisfied, Color(0xFF60a5fa)),
    _Pick('🔥', Icons.local_fire_department, Color(0xFFf97316)),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemBuilder: (_, i) => InkWell(
          onTap: () => onPick(_picks[i].emoji),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Icon(_picks[i].icon, color: _picks[i].color, size: 26),
          ),
        ),
        separatorBuilder: (_, _) => const SizedBox(width: 2),
        itemCount: _picks.length,
      ),
    );
  }
}

class _Pick {
  final String emoji;
  final IconData icon;
  final Color color;
  const _Pick(this.emoji, this.icon, this.color);
}

// ────────────────────────────────────────────────────────────────────────
/// Маппинг raw-emoji → Material иконка для отображения реакции на сообщении.
/// Сохраняет совместимость с сервером (он хранит raw-symbol), но рендерит
/// стилистически единый Material набор поверх любой ОС.
Widget _chatReactionIcon(String key, {double size = 12, required Color color}) {
  IconData? ic;
  switch (key) {
    case '❤':
    case '❤️':
    case '♥':
      ic = Icons.favorite;
      break;
    case '👍':
      ic = Icons.thumb_up;
      break;
    case '😂':
    case '🤣':
      ic = Icons.sentiment_very_satisfied;
      break;
    case '😮':
    case '😲':
      ic = Icons.sentiment_neutral;
      break;
    case '😢':
    case '😭':
      ic = Icons.sentiment_dissatisfied;
      break;
    case '🔥':
      ic = Icons.local_fire_department;
      break;
  }
  if (ic == null) {
    return Text(
      key,
      style: TextStyle(color: color, fontSize: size + 1),
    );
  }
  return Icon(ic, size: size, color: color);
}

/// Парсит created_at (наивная UTC-строка / unix int) → локальное DateTime.
/// Сервер шлёт UTC без 'Z' — помечаем как UTC, иначе время уезжает на TZ.
DateTime _msgLocal(dynamic at) {
  if (at is int) {
    return DateTime.fromMillisecondsSinceEpoch(at * 1000).toLocal();
  }
  final p = DateTime.parse(at.toString());
  final utc = p.isUtc
      ? p
      : DateTime.utc(
          p.year,
          p.month,
          p.day,
          p.hour,
          p.minute,
          p.second,
          p.millisecond,
        );
  return utc.toLocal();
}

bool _msgSameDay(dynamic a, dynamic b) {
  final la = _msgLocal(a), lb = _msgLocal(b);
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}

/// «Сегодня» / «Вчера» / «12 июня» / «12 июня 2024».
String _msgDateLabel(dynamic at) {
  final d = _msgLocal(at);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  const months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  final base = '${d.day} ${months[d.month - 1]}';
  return d.year == now.year ? base : '$base ${d.year}';
}

/// Премиум-пилюля даты-разделителя между днями.
Widget _dateChip(dynamic at) {
  return Center(
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.5,
        ),
      ),
      child: Text(
        _msgDateLabel(at),
        style: TextStyle(
          color: GE.sub,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

/// Текстовое превью сообщения для reply-бара и reply-превью: текст, либо
/// «Голосовое сообщение» / «Фото» / «Видео» / «Файл: …» для медиа.
String _msgPreview(StoredMessage? m, {int max = 100}) {
  if (m == null) return '';
  if (m.text.isNotEmpty) {
    return m.text.length > max ? '${m.text.substring(0, max)}…' : m.text;
  }
  final fp = m.filePayload;
  if (fp != null) {
    if (fp['voice'] == true || fp['voice'] == 1) return 'Голосовое сообщение';
    final mime = fp['mime'] as String? ?? '';
    if (mime.startsWith('image/')) return 'Фото';
    if (mime.startsWith('video/')) return 'Видео';
    final name = fp['file_name'] as String?;
    return name != null && name.isNotEmpty ? 'Файл: $name' : 'Файл';
  }
  return '';
}

class _Bubble extends StatelessWidget {
  final StoredMessage m;
  final String? myUsername;
  final bool highlighted;
  final bool prevSame;
  const _Bubble(
    this.m, {
    this.myUsername,
    this.highlighted = false,
    this.prevSame = false,
  });

  @override
  Widget build(BuildContext context) {
    final mine = m.fromMe;
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;
    // Тёмный лакшери: свои — глубокий фиолет-градиент, чужие — solid (фон ниже).
    final bg = mine
        ? const LinearGradient(
            // СВЕТОВАЯ КРОМКА (rim): тонкая сплошная светлая линия по верхнему
            // краю (~1px) → резкий переход → ровный фиолет. Не градиент-залив.
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFC8BAFF),
              Color(0xFFC8BAFF),
              Color(0xFF6A4FD0),
              Color(0xFF3F2E9C),
            ],
            stops: [0.0, 0.03, 0.045, 1.0],
          )
        : const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF3E3658),
              Color(0xFF3E3658),
              Color(0xFF1C1726),
              Color(0xFF131019),
            ],
            stops: [0.0, 0.03, 0.045, 1.0],
          );
    final textColor = mine ? Colors.white : const Color(0xFFD7D2DE);
    final isImg = _isImage(m);
    // Подряд идущие сообщения одного автора — теснее (верх 1), их размытие
    // соединяется; на смене автора — отступ больше (верх 5).
    final vPad = EdgeInsets.only(top: prevSame ? 1.0 : 5.0, bottom: 1.0);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: align,
      decoration: highlighted
          ? BoxDecoration(
              color: GE.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(GE.radiusMd),
              border: Border.all(
                color: GE.primary.withValues(alpha: 0.75),
                width: 1.5,
              ),
            )
          : null,
      padding: highlighted ? const EdgeInsets.all(4) : EdgeInsets.zero,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Container(
          margin: vPad,
          padding: m.filePayload != null && isImg
              ? const EdgeInsets.all(4)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            // Тёмный лакшери: чужие — тёмный градиент, свои — фиолет-градиент;
            // тонкая светлая кромка (у своих ярче = inset-блик) + одна мягкая
            // тень для премиум-объёма (лёгкая, без перегруза GPU).
            gradient: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(mine ? 16 : 6),
              bottomRight: Radius.circular(mine ? 6 : 16),
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: mine ? 0.16 : 0.07),
              width: 0.7,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.32),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.forwardedFrom != null) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.share,
                      size: 11,
                      color: textColor.withValues(alpha: 0.65),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '@${m.forwardedFrom}',
                      style: TextStyle(
                        color: textColor.withValues(alpha: 0.75),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
              ],
              if (m.replyPreview != null && m.replyPreview!.isNotEmpty) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: textColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(7),
                    border: Border(
                      left: BorderSide(
                        color: mine
                            ? Colors.white.withValues(alpha: 0.65)
                            : GE.primary,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Text(
                    m.replyPreview!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.85),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              if (m.deleted)
                Text(
                  '🗑 удалено',
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.55),
                    fontStyle: FontStyle.italic,
                    fontSize: 13,
                  ),
                )
              else ...[
                if (m.filePayload != null)
                  _MediaPart(m: m, textColor: textColor),
                if (m.text.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(
                      top: m.filePayload != null ? 4 : 0,
                    ),
                    child: Text(
                      m.text,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 15,
                        height: 1.35,
                      ),
                    ),
                  ),
              ],
              if (m.reactions != null && m.reactions!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      for (final e in m.reactions!.entries)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: textColor.withValues(alpha: 0.28),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: textColor.withValues(alpha: 0.35),
                              width: 0.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _chatReactionIcon(
                                e.key,
                                size: 14,
                                color: textColor,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '${e.value.length}',
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (m.edited) ...[
                    Icon(
                      Icons.edit,
                      size: 10,
                      color: textColor.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 3),
                  ],
                  Text(
                    _formatTime(m.createdAt),
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.65),
                      fontSize: 10,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (mine) ...[const SizedBox(width: 4), _ticks(m)],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isImage(StoredMessage m) {
    final mime = m.filePayload?['mime'] as String?;
    return mime != null && mime.startsWith('image/');
  }

  Widget _ticks(StoredMessage m) {
    if (m.pending) {
      return const Icon(Icons.access_time, size: 11, color: Colors.white70);
    }
    if (m.read) {
      return Icon(Icons.done_all, size: 14, color: GE.blue);
    }
    if (m.delivered) {
      return const Icon(Icons.done, size: 13, color: Colors.white70);
    }
    return const Icon(Icons.save_outlined, size: 11, color: Colors.white54);
  }

  String _formatTime(dynamic at) {
    if (at == null) return '';
    DateTime dt;
    try {
      if (at is int) {
        dt = DateTime.fromMillisecondsSinceEpoch(at * 1000);
      } else {
        final p = DateTime.parse(at.toString());
        // Сервер шлёт created_at наивной UTC-строкой (без 'Z') → DateTime.parse
        // трактовал её как локаль и время уезжало на TZ-смещение (−3ч МСК).
        // Помечаем как UTC, потом toLocal даёт верное местное время.
        dt = p.isUtc
            ? p
            : DateTime.utc(
                p.year,
                p.month,
                p.day,
                p.hour,
                p.minute,
                p.second,
                p.millisecond,
              );
      }
    } catch (_) {
      return '';
    }
    return DateFormat('HH:mm').format(dt.toLocal());
  }
}

// ────────────────────────────────────────────────────────────────────────
class _MediaPart extends StatefulWidget {
  final StoredMessage m;
  final Color textColor;
  const _MediaPart({required this.m, required this.textColor});

  @override
  State<_MediaPart> createState() => _MediaPartState();
}

class _MediaPartState extends State<_MediaPart> {
  Uint8List? _bytes;
  bool _loading = false;
  bool _failed = false;

  bool get _isImage =>
      (widget.m.filePayload?['mime'] as String?)?.startsWith('image/') ?? false;
  bool get _isVoice =>
      widget.m.filePayload?['voice'] == true ||
      widget.m.filePayload?['voice'] == 1;

  @override
  void initState() {
    super.initState();
    // Пока сообщение pending (своё изображение грузится на сервер) — НЕ грузим:
    // blob ещё не на сервере, расшифровка упадёт. Загрузим после промоушена
    // (баббл пересоздастся с новым sid → initState снова, уже не pending).
    if (_isImage && !widget.m.pending) _load();
  }

  Future<void> _load() async {
    if (_loading || _bytes != null) return;
    setState(() => _loading = true);
    try {
      final b = await ChatRepo.instance.decryptMediaBlob(widget.m);
      if (!mounted) return;
      setState(() {
        _bytes = b;
        _failed = b == null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isImage) return _imageView();
    if (_isVoice) return _voiceView();
    return _fileView();
  }

  Widget _imageView() {
    if (widget.m.pending) {
      // Своё изображение ещё ГРУЗИТСЯ — показываем «Отправляется…», не ошибку.
      return Container(
        width: 240,
        height: 180,
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(strokeWidth: 2, color: GE.primary),
            const SizedBox(height: 8),
            Text(
              'Отправляется…',
              style: TextStyle(color: GE.sub, fontSize: 12),
            ),
          ],
        ),
      );
    }
    if (_loading) {
      return Container(
        width: 240,
        height: 180,
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: CircularProgressIndicator(strokeWidth: 2, color: GE.primary),
      );
    }
    if (_failed || _bytes == null) {
      return Container(
        width: 240,
        height: 80,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(
          'Не удалось расшифровать картинку',
          textAlign: TextAlign.center,
          style: TextStyle(color: GE.red, fontSize: 12),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: GestureDetector(
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            backgroundColor: Colors.black,
            insetPadding: const EdgeInsets.all(8),
            child: InteractiveViewer(child: Image.memory(_bytes!)),
          ),
        ),
        // cacheWidth: декодим фото в ~2x от ширины показа (240), а не в полном
        // разрешении — иначе большой снимок жрёт десятки МБ и дико лагает.
        child: Image.memory(
          _bytes!,
          width: 240,
          fit: BoxFit.cover,
          cacheWidth: 480,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
        ),
      ),
    );
  }

  Widget _voiceView() {
    final dur = (widget.m.filePayload?['duration'] as int?) ?? 0;
    final wf = widget.m.filePayload?['waveform'];
    final waveform = wf is List
        ? wf.map((e) => (e as num).toDouble()).toList()
        : const <double>[];
    return _VoiceTile(
      durationSec: dur,
      bytes: _bytes,
      loading: _loading,
      onLoad: _load,
      textColor: widget.textColor,
      waveform: waveform,
    );
  }

  Widget _fileView() {
    final fp = widget.m.filePayload!;
    final name = fp['file_name'] as String? ?? 'файл';
    final size = (fp['size'] as int?) ?? 0;
    return InkWell(
      onTap: _load,
      child: Container(
        constraints: const BoxConstraints(minWidth: 200),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: widget.textColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _loading ? Icons.hourglass_top : Icons.insert_drive_file,
                color: widget.textColor,
                size: 18,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: widget.textColor, fontSize: 13),
                  ),
                  Text(
                    _humanSize(size),
                    style: TextStyle(
                      color: widget.textColor.withValues(alpha: 0.7),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _humanSize(int b) {
    if (b < 1024) return '$b Б';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} КБ';
    return '${(b / 1024 / 1024).toStringAsFixed(2)} МБ';
  }
}

// ────────────────────────────────────────────────────────────────────────
/// Рисует полоски-вейвформу голосового (как в Telegram): закрашены слева по
/// прогрессу воспроизведения, остальные — приглушённые.
class _WaveformPainter extends CustomPainter {
  final List<double> bars;
  final double progress;
  final Color bg;
  final Color fill;
  _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.bg,
    required this.fill,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final n = bars.length;
    const gap = 2.0;
    final barW = ((size.width - gap * (n - 1)) / n).clamp(0.5, double.infinity);
    final filled = (progress * n).round();
    final bgPaint = Paint()..color = bg;
    final fillPaint = Paint()..color = fill;
    for (var i = 0; i < n; i++) {
      final h = (bars[i].clamp(0.08, 1.0)) * size.height;
      final x = i * (barW + gap);
      final y = (size.height - h) / 2;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barW, h),
        Radius.circular(barW / 2),
      );
      canvas.drawRRect(r, i < filled ? fillPaint : bgPaint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.bars != bars ||
      old.fill != fill ||
      old.bg != bg;
}

class _VoiceTile extends StatefulWidget {
  final int durationSec;
  final Uint8List? bytes;
  final bool loading;
  final VoidCallback onLoad;
  final Color textColor;
  final List<double> waveform;
  const _VoiceTile({
    required this.durationSec,
    required this.bytes,
    required this.loading,
    required this.onLoad,
    required this.textColor,
    this.waveform = const [],
  });

  @override
  State<_VoiceTile> createState() => _VoiceTileState();
}

class _VoiceTileState extends State<_VoiceTile> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _audioDur = Duration.zero;
  double _speed = 1.0;
  String? _tmpPath;
  bool _pendingPlay = false;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _durSub;

  @override
  void initState() {
    super.initState();
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _audioDur = d);
    });
    _stateSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      }
    });
  }

  @override
  void didUpdateWidget(_VoiceTile old) {
    super.didUpdateWidget(old);
    // Один тап: первый тап только грузит blob (bytes == null → onLoad). Когда
    // байты приехали — авто-стартуем, не дожидаясь второго тапа.
    if (_pendingPlay && old.bytes == null && widget.bytes != null) {
      _pendingPlay = false;
      _toggle();
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _durSub?.cancel();
    _player.dispose();
    final p = _tmpPath;
    if (p != null) {
      try {
        File(p).delete();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _ensureFile() async {
    if (_tmpPath != null) return;
    // Играем из ВРЕМЕННОГО ФАЙЛА, а не из BytesSource: даёт надёжную позицию
    // (onPositionChanged → заливка/перемотка работают) и быстрый старт.
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/gc_play_${widget.hashCode}.m4a');
    await f.writeAsBytes(widget.bytes!);
    _tmpPath = f.path;
  }

  Future<void> _toggle() async {
    if (widget.bytes == null) {
      _pendingPlay = true;
      widget.onLoad();
      return;
    }
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
    } else {
      await _ensureFile();
      await _player.play(DeviceFileSource(_tmpPath!));
      if (_speed != 1.0) {
        try {
          await _player.setPlaybackRate(_speed);
        } catch (_) {}
      }
      setState(() => _playing = true);
    }
  }

  Future<void> _cycleSpeed() async {
    const speeds = [1.0, 1.5, 2.0];
    final next = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
    setState(() => _speed = next);
    try {
      await _player.setPlaybackRate(next);
    } catch (_) {}
  }

  // Визуал перемотки — МГНОВЕННО (без ожидания аудио-seek): полоски прыгают
  // сразу, аудио догоняет в фоне. Иначе UI ждал ~600мс пока seek на AAC отработает.
  void _seekVisual(double f) {
    final total = _audioDur.inMilliseconds > 0
        ? _audioDur
        : Duration(seconds: widget.durationSec);
    if (total.inMilliseconds == 0) return;
    setState(() {
      _pos = Duration(
        milliseconds: (total.inMilliseconds * f.clamp(0.0, 1.0)).round(),
      );
    });
  }

  // Реальный аудио-seek на текущую визуальную позицию — на тап / отпуск драга
  // (не на каждый drag-update, иначе очередь seek'ов = лаг).
  Future<void> _seekCommit() async {
    try {
      await _player.seek(_pos);
    } catch (_) {}
  }

  // Реальная вейвформа из payload (или мягкий дефолт для старых гс),
  // РАСТЯНУТАЯ интерполяцией до фикс. числа полосок → всегда во всю ширину.
  List<double> get _bars {
    final raw = widget.waveform.isNotEmpty
        ? widget.waveform
        : List<double>.generate(28, (i) => 0.25 + 0.2 * (((i * 13) % 7) / 6));
    return _resample(raw, 40);
  }

  static List<double> _resample(List<double> src, int target) {
    if (src.length <= 1) return List<double>.filled(target, 0.3);
    if (src.length == target) return src;
    final out = <double>[];
    for (var i = 0; i < target; i++) {
      final pos = i * (src.length - 1) / (target - 1);
      final lo = pos.floor();
      final hi = pos.ceil().clamp(0, src.length - 1);
      final t = pos - lo;
      out.add(src[lo] * (1 - t) + src[hi] * t);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final total = _audioDur.inMilliseconds > 0
        ? _audioDur
        : Duration(seconds: widget.durationSec);
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final started = _playing || _pos > Duration.zero;
    return SizedBox(
      width: 246,
      child: Row(
        children: [
          InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(23),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.textColor.withValues(alpha: 0.96),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.20),
                    blurRadius: 7,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: widget.loading
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF2A1E50),
                      ),
                    )
                  : Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: const Color(0xFF2A1E50),
                      size: 28,
                    ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 26,
                    child: LayoutBuilder(
                      builder: (ctx, c) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) {
                          _seekVisual(d.localPosition.dx / c.maxWidth);
                          _seekCommit();
                        },
                        onHorizontalDragUpdate: (d) =>
                            _seekVisual(d.localPosition.dx / c.maxWidth),
                        onHorizontalDragEnd: (_) => _seekCommit(),
                        child: CustomPaint(
                          size: Size(c.maxWidth, 26),
                          painter: _WaveformPainter(
                            bars: _bars,
                            progress: progress,
                            bg: widget.textColor.withValues(alpha: 0.30),
                            fill: widget.textColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        _fmt(started ? _pos : total),
                        style: TextStyle(
                          color: widget.textColor.withValues(alpha: 0.7),
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const Spacer(),
                      if (started)
                        GestureDetector(
                          onTap: _cycleSpeed,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: widget.textColor.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              _speed == _speed.roundToDouble()
                                  ? '${_speed.toInt()}x'
                                  : '${_speed}x',
                              style: TextStyle(
                                color: widget.textColor,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final mm = d.inMinutes.toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

// ────────────────────────────────────────────────────────────────────────
/// Шапка чата: avatar + display_name + @username + online-индикатор.
/// Тап → ProfileScreen (для DM). Презенс через ChatRepo.watchPresence.
class _ChatHeader extends StatelessWidget {
  final String peer;
  final String displayName;
  final bool isGroup;
  const _ChatHeader({
    required this.peer,
    required this.displayName,
    required this.isGroup,
  });

  @override
  Widget build(BuildContext context) {
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    return SafeArea(
      bottom: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isGroup
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ProfileScreen(username: peer),
                  ),
                ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back, color: GE.text),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [GE.primary2, GE.primary],
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        initial,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    if (!isGroup)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: ChatRepo.instance.watchPresence(
                            peer,
                          ),
                          builder: (_, online, __) => Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: online ? GE.green : GE.muted,
                              border: Border.all(color: GE.bg, width: 2),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          shadows: const [
                            Shadow(color: Color(0xCC000000), blurRadius: 5),
                          ],
                        ),
                      ),
                      if (!isGroup)
                        ValueListenableBuilder<bool>(
                          valueListenable: ChatRepo.instance.watchPresence(
                            peer,
                          ),
                          builder: (_, online, __) => Row(
                            children: [
                              Text(
                                '@$peer',
                                style: TextStyle(color: GE.sub, fontSize: 11),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '·',
                                style: TextStyle(color: GE.sub, fontSize: 11),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                online ? 'в сети' : 'не в сети',
                                style: TextStyle(
                                  color: online ? GE.green : GE.muted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  shadows: const [
                                    Shadow(
                                      color: Color(0xCC000000),
                                      blurRadius: 5,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (isGroup)
                        Text(
                          peer,
                          style: TextStyle(color: GE.sub, fontSize: 11),
                        ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: GE.sub, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
