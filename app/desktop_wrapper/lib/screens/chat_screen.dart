// ChatScreen — открытый DM-чат. Native, без WebView.
//
// AUTO-2/AUTO-3: текст + картинки + голосовые, reply/edit/delete/forward/react.
// Все медиа шифруются на клиенте AES-256, blob аплоадится зашифрованным.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../theme.dart';
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
        _highlightTimer = Timer(const Duration(seconds: 2), () {
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
    final approx = (idx * 64.0).clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    _scrollCtrl.animateTo(approx,
        duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _highlightTimer?.cancel();
    _recordTicker?.cancel();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    try { _recorder.dispose(); } catch (_) {}
    super.dispose();
  }

  void _scrollToBottom(bool animate) {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position.maxScrollExtent;
    if (animate) {
      _scrollCtrl.animateTo(pos,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    } else {
      _scrollCtrl.jumpTo(pos);
    }
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      if (_editing != null) {
        await ChatRepo.instance.editDmMessage(
          toUsername: widget.peer,
          sid: _editing!.sid,
          newText: text,
        );
        setState(() => _editing = null);
      } else {
        await ChatRepo.instance.sendDmText(widget.peer, text);
      }
      _inputCtrl.clear();
      setState(() => _replyTo = null);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(true));
    } catch (e) {
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
                _attachTile(Icons.camera_alt, 'Камера',
                    () => _pickAndSendImage(ImageSource.camera)),
                _attachTile(Icons.photo_library, 'Галерея',
                    () => _pickAndSendImage(ImageSource.gallery)),
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
                width: 44, height: 44,
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

  Future<void> _startRecording() async {
    if (_recording) return;
    try {
      final has = await _recorder.hasPermission();
      if (!has) { _snack('Нет разрешения на микрофон'); return; }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/ghost_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 44100, numChannels: 1),
        path: path,
      );
      _recordStartedAt = DateTime.now().millisecondsSinceEpoch;
      setState(() {
        _recording = true;
        _recordDur = Duration.zero;
      });
      HapticFeedback.lightImpact();
      _recordTicker?.cancel();
      _recordTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        setState(() => _recordDur =
            Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - _recordStartedAt));
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
      await ChatRepo.instance.sendDmFile(
        toUsername: widget.peer,
        bytes: bytes,
        mime: 'audio/m4a',
        fileName: 'voice.m4a',
        voice: true,
        duration: durSec,
      );
      try { await file.delete(); } catch (_) {}
    } catch (e) {
      _snack('Голосовое не отправилось: $e');
    }
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
                if (canEdit) _menuItem(ctx, Icons.edit, 'Редактировать', 'edit'),
                _menuItem(ctx, Icons.copy, 'Копировать', 'copy'),
                if (mine && !m.deleted)
                  _menuItem(ctx, Icons.delete_outline, 'Удалить', 'delete', danger: true),
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
          toUsername: widget.peer, sid: m.sid, emoji: emoji);
      } catch (e) { _snack('Не вышло: $e'); }
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
            toUsername: widget.peer, sid: m.sid);
        } catch (e) { _snack('Не удалилось: $e'); }
        break;
      case 'forward':
        await _showForwardPicker(m);
        break;
    }
  }

  Widget _menuItem(BuildContext ctx, IconData icon, String label, String value, {bool danger = false}) {
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
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Переслать кому?',
                        style: TextStyle(color: GE.text, fontWeight: FontWeight.w600)),
                  ),
                ),
                for (final d in dialogs)
                  InkWell(
                    onTap: () => Navigator.pop(ctx, d.username),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(children: [
                        CircleAvatar(radius: 16, backgroundColor: GE.primary2,
                            child: const Icon(Icons.person, color: Colors.white, size: 16)),
                        const SizedBox(width: 10),
                        Expanded(child: Text('@${d.username}',
                            style: TextStyle(color: GE.text))),
                      ]),
                    ),
                  ),
                if (dialogs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('Нет других чатов', style: TextStyle(color: GE.sub)),
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: _ChatHeader(
          peer: widget.peer,
          displayName: widget.displayName,
          isGroup: isGroup,
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
        children: [
          Expanded(
            child: ValueListenableBuilder<List<StoredMessage>>(
              valueListenable: notif,
              builder: (_, msgs, __) {
                if (msgs.isEmpty) return _empty();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _scrollCtrl.hasClients) {
                    final at = _scrollCtrl.position.pixels;
                    final max = _scrollCtrl.position.maxScrollExtent;
                    if (max - at < 200) _scrollToBottom(true);
                  }
                });
                return ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) {
                    final m = msgs[i];
                    return Dismissible(
                      key: ValueKey('msg_${m.sid}_${m.tempSid ?? ""}'),
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
                        child: Icon(Icons.reply, color: GE.primary, size: 22),
                      ),
                      child: GestureDetector(
                        onLongPress: () => _openBubbleMenu(m),
                        onDoubleTap: () async {
                          try {
                            await ChatRepo.instance.reactDmMessage(
                                toUsername: widget.peer, sid: m.sid, emoji: '❤');
                          } catch (_) {}
                        },
                        child: _Bubble(m,
                            myUsername: _myUsername,
                            highlighted: m.sid == _highlightSid),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          if (_replyTo != null || _editing != null) _replyEditBar(),
          _composer(),
        ],
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
            Icon(isEdit ? Icons.edit : Icons.reply, size: 16, color: GE.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isEdit ? 'Редактирование' : 'Ответ',
                      style: TextStyle(
                          color: GE.primary, fontSize: 11, fontWeight: FontWeight.w600)),
                  Text(m?.text ?? '',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: GE.sub, fontSize: 12)),
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
            Text('Напиши первое сообщение',
                style: TextStyle(color: GE.text, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('Всё шифруется на твоём устройстве',
                style: TextStyle(color: GE.sub, fontSize: 12)),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        radius: GE.radiusLg,
        child: _recording ? _recordingBar() : Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: Icon(Icons.attach_file, color: GE.sub),
              onPressed: _sending ? null : _openAttachSheet,
            ),
            Expanded(
              child: TextField(
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
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                ),
              ),
            ),
            Material(
              color: Colors.transparent,
              child: hasText
                  ? InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _sending ? null : _send,
                      child: _circleBtn(_sending
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.send, color: Colors.white, size: 18)),
                    )
                  : GestureDetector(
                      onLongPressStart: (_) => _startRecording(),
                      onLongPressEnd: (_) => _stopAndSendRecording(),
                      onLongPressCancel: () => _stopAndSendRecording(cancel: true),
                      child: _circleBtn(
                          const Icon(Icons.mic, color: Colors.white, size: 20)),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _circleBtn(Widget child) => Container(
        width: 42, height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
        ),
        alignment: Alignment.center,
        child: child,
      );

  Widget _recordingBar() {
    final mm = _recordDur.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = _recordDur.inSeconds.remainder(60).toString().padLeft(2, '0');
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.delete, color: GE.red),
          onPressed: () => _stopAndSendRecording(cancel: true),
        ),
        Icon(Icons.fiber_manual_record, color: GE.red, size: 14),
        const SizedBox(width: 8),
        Text('$mm:$ss',
            style: TextStyle(color: GE.text, fontFeatures: const [FontFeature.tabularFigures()])),
        const Spacer(),
        Text('Отпусти — отправит', style: TextStyle(color: GE.sub, fontSize: 12)),
        const SizedBox(width: 8),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
class _ReactionsBar extends StatelessWidget {
  final void Function(String emoji) onPick;
  const _ReactionsBar({required this.onPick});
  static const _emojis = ['❤', '👍', '😂', '😮', '😢', '🔥'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemBuilder: (_, i) => InkWell(
          onTap: () => onPick(_emojis[i]),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(_emojis[i], style: const TextStyle(fontSize: 22)),
          ),
        ),
        separatorBuilder: (_, _) => const SizedBox(width: 2),
        itemCount: _emojis.length,
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
class _Bubble extends StatelessWidget {
  final StoredMessage m;
  final String? myUsername;
  final bool highlighted;
  const _Bubble(this.m, {this.myUsername, this.highlighted = false});

  @override
  Widget build(BuildContext context) {
    final mine = m.fromMe;
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;
    final bg = mine ? LinearGradient(colors: [GE.primary2, GE.primary]) : null;
    final textColor = mine ? Colors.white : GE.text;
    final isImg = _isImage(m);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: align,
      decoration: highlighted
          ? BoxDecoration(
              color: GE.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(GE.radiusMd),
            )
          : null,
      padding: highlighted ? const EdgeInsets.all(4) : EdgeInsets.zero,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: m.filePayload != null && isImg
              ? const EdgeInsets.all(4)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: mine ? null : GE.glassFill,
            gradient: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(mine ? 16 : 4),
              bottomRight: Radius.circular(mine ? 4 : 16),
            ),
            border: mine ? null : Border.all(color: GE.glassBorder, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.forwardedFrom != null) ...[
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.share, size: 11, color: textColor.withValues(alpha: 0.65)),
                  const SizedBox(width: 4),
                  Text('@${m.forwardedFrom}',
                      style: TextStyle(
                        color: textColor.withValues(alpha: 0.75),
                        fontSize: 11, fontWeight: FontWeight.w600,
                      )),
                ]),
                const SizedBox(height: 2),
              ],
              if (m.replyPreview != null && m.replyPreview!.isNotEmpty) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: textColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border(
                      left: BorderSide(color: textColor.withValues(alpha: 0.5), width: 3),
                    ),
                  ),
                  child: Text(m.replyPreview!,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: textColor.withValues(alpha: 0.85), fontSize: 12)),
                ),
              ],
              if (m.deleted)
                Text('🗑 удалено',
                    style: TextStyle(
                        color: textColor.withValues(alpha: 0.55),
                        fontStyle: FontStyle.italic, fontSize: 13))
              else ...[
                if (m.filePayload != null) _MediaPart(m: m, textColor: textColor),
                if (m.text.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: m.filePayload != null ? 4 : 0),
                    child: Text(m.text,
                        style: TextStyle(color: textColor, fontSize: 15, height: 1.35)),
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
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: textColor.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${e.key} ${e.value.length}',
                            style: TextStyle(color: textColor, fontSize: 11),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (m.edited)
                    Text('изм. ', style: TextStyle(
                        color: textColor.withValues(alpha: 0.55), fontSize: 10)),
                  Text(_formatTime(m.createdAt),
                      style: TextStyle(
                          color: textColor.withValues(alpha: 0.65),
                          fontSize: 10,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                  if (mine) ...[
                    const SizedBox(width: 4),
                    _ticks(m),
                  ],
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
      return Icon(Icons.done_all, size: 12, color: GE.blue);
    }
    if (m.delivered) {
      return const Icon(Icons.done, size: 12, color: Colors.white70);
    }
    return const Icon(Icons.save_outlined, size: 11, color: Colors.white54);
  }

  String _formatTime(dynamic at) {
    if (at == null) return '';
    DateTime dt;
    try {
      dt = at is int
          ? DateTime.fromMillisecondsSinceEpoch(at * 1000)
          : DateTime.parse(at.toString());
    } catch (_) { return ''; }
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
  bool get _isVoice => widget.m.filePayload?['voice'] == true
      || widget.m.filePayload?['voice'] == 1;

  @override
  void initState() {
    super.initState();
    if (_isImage) _load();
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
      setState(() { _failed = true; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isImage) return _imageView();
    if (_isVoice) return _voiceView();
    return _fileView();
  }

  Widget _imageView() {
    if (_loading) {
      return Container(
        width: 240, height: 180,
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
        width: 240, height: 80,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text('Не удалось расшифровать картинку',
            textAlign: TextAlign.center,
            style: TextStyle(color: GE.red, fontSize: 12)),
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
        child: Image.memory(_bytes!, width: 240, fit: BoxFit.cover),
      ),
    );
  }

  Widget _voiceView() {
    final dur = (widget.m.filePayload?['duration'] as int?) ?? 0;
    return _VoiceTile(
      durationSec: dur,
      bytes: _bytes,
      loading: _loading,
      onLoad: _load,
      textColor: widget.textColor,
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
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: widget.textColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_loading ? Icons.hourglass_top : Icons.insert_drive_file,
                  color: widget.textColor, size: 18),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: widget.textColor, fontSize: 13)),
                  Text(_humanSize(size),
                      style: TextStyle(
                          color: widget.textColor.withValues(alpha: 0.7), fontSize: 11)),
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
class _VoiceTile extends StatefulWidget {
  final int durationSec;
  final Uint8List? bytes;
  final bool loading;
  final VoidCallback onLoad;
  final Color textColor;
  const _VoiceTile({
    required this.durationSec,
    required this.bytes,
    required this.loading,
    required this.onLoad,
    required this.textColor,
  });

  @override
  State<_VoiceTile> createState() => _VoiceTileState();
}

class _VoiceTileState extends State<_VoiceTile> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _pos = Duration.zero;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;

  @override
  void initState() {
    super.initState();
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _stateSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _playing = false; _pos = Duration.zero; });
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (widget.bytes == null) {
      widget.onLoad();
      return;
    }
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
    } else {
      await _player.play(BytesSource(widget.bytes!));
      setState(() => _playing = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = Duration(seconds: widget.durationSec);
    final progress = total.inMilliseconds == 0
        ? 0.0 : (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.textColor.withValues(alpha: 0.2),
              ),
              child: widget.loading
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(_playing ? Icons.pause : Icons.play_arrow,
                      color: widget.textColor, size: 22),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor: widget.textColor.withValues(alpha: 0.2),
                    valueColor: AlwaysStoppedAnimation(widget.textColor),
                  ),
                ),
                const SizedBox(height: 4),
                Text(_fmt(total),
                    style: TextStyle(color: widget.textColor.withValues(alpha: 0.7),
                        fontSize: 11)),
              ],
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
              : () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ProfileScreen(username: peer),
                  )),
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
                      width: 42, height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient:
                            LinearGradient(colors: [GE.primary2, GE.primary]),
                      ),
                      alignment: Alignment.center,
                      child: Text(initial,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 18)),
                    ),
                    if (!isGroup)
                      Positioned(
                        right: -2, bottom: -2,
                        child: ValueListenableBuilder<bool>(
                          valueListenable:
                              ChatRepo.instance.watchPresence(peer),
                          builder: (_, online, __) => Container(
                            width: 14, height: 14,
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
                      Text(displayName,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: GE.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      if (!isGroup)
                        ValueListenableBuilder<bool>(
                          valueListenable:
                              ChatRepo.instance.watchPresence(peer),
                          builder: (_, online, __) => Row(children: [
                            Text('@$peer',
                                style: TextStyle(color: GE.sub, fontSize: 11)),
                            const SizedBox(width: 6),
                            Text('·',
                                style: TextStyle(color: GE.sub, fontSize: 11)),
                            const SizedBox(width: 6),
                            Text(
                              online ? 'в сети' : 'не в сети',
                              style: TextStyle(
                                color: online ? GE.green : GE.muted,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ]),
                        ),
                      if (isGroup)
                        Text(peer,
                            style: TextStyle(color: GE.sub, fontSize: 11)),
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
