// BookmarkChatScreen — "Избранное" и пользовательские закладки. Чисто
// локально: текст + файлы, ничего не уходит в сеть. "Избранное" (id=default)
// нельзя переименовать/удалить — остальные закладки можно.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../widgets/attach_sheet.dart';
import '../widgets/chat_composer.dart';
import '../widgets/emoji_picker.dart';
import '../widgets/emoji_text.dart';
import '../widgets/empty_chat_state.dart';
import '../widgets/reactions_bar.dart';
import '../widgets/send_fly_animation.dart';
import '../widgets/toast_overlay.dart';
import '../services/bookmark_store.dart';

class BookmarkChatScreen extends StatefulWidget {
  final String bookmarkId;
  final String name;
  final bool isDefault;
  const BookmarkChatScreen({
    super.key,
    required this.bookmarkId,
    required this.name,
    required this.isDefault,
  });

  @override
  State<BookmarkChatScreen> createState() => _BookmarkChatScreenState();
}

class _BookmarkChatScreenState extends State<BookmarkChatScreen> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<BookmarkMessage> _messages = [];
  late String _name;
  bool _sending = false;
  bool _emojiOpen = false;
  final _sendBtnKey = GlobalKey();
  final _imagePicker = ImagePicker();
  static const double _emojiPanelH = 300;
  // Мало сообщений — держим ленту у низа, рядом с полем ввода (как в
  // chat_screen.dart), а не приклеенной к шапке с пустотой снизу.
  static const int _bottomAnchorMaxMsgs = 40;

  @override
  void initState() {
    super.initState();
    _name = widget.name;
    _load();
  }

  Future<void> _load() async {
    final msgs = await BookmarkStore.instance.getMessages(widget.bookmarkId);
    if (!mounted) return;
    setState(() => _messages.addAll(msgs));
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _sendText() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    flySendAnimation(context, _sendBtnKey);
    setState(() => _sending = true);
    try {
      await BookmarkStore.instance.addMessage(
        bookmarkId: widget.bookmarkId,
        text: text,
      );
      final msgs = await BookmarkStore.instance.getMessages(widget.bookmarkId);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(msgs);
        _msgCtrl.clear();
      });
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // Единый лист вложений (та же «скрепка», что в основном чате). Заметки
  // локальные — гео/кошелёк не имеют смысла здесь, поэтому это заглушки «скоро»
  // (единый вид листа важнее, чем прятать пункты).
  Future<void> _openAttachSheet() async {
    HapticFeedback.selectionClick();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AttachSheet(
        onPickedSend: _sendPickedItems,
        onGallery: () => _pickImageAndSave(ImageSource.gallery),
        onFile: _pickFileAndSave,
        onCamera: () => _pickImageAndSave(ImageSource.camera),
        onGeo: () => toast.show('Геопозиция — скоро'),
        onWallet: () => toast.show('Кошелёк — после интеграции GhostBank'),
      ),
    );
  }

  Future<void> _sendPickedItems(List<AttachItem> items) async {
    for (final it in items) {
      try {
        final bytes = await it.file.readAsBytes();
        await _saveBookmarkBytes(
          bytes,
          p.basename(it.file.path),
          it.isVideo ? 'video/mp4' : 'image/jpeg',
        );
      } catch (e) {
        toast.show('Не удалось прикрепить: $e');
      }
    }
  }

  Future<void> _pickImageAndSave(ImageSource src) async {
    try {
      final x = await _imagePicker.pickImage(
        source: src,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      );
      if (x == null) return;
      await _saveBookmarkBytes(await x.readAsBytes(), x.name, 'image/jpeg');
    } catch (e) {
      toast.show('Не удалось прикрепить фото: $e');
    }
  }

  Future<void> _pickFileAndSave() async {
    final file = await openFile();
    if (file == null) return;
    try {
      await _saveBookmarkBytes(
        await file.readAsBytes(),
        file.name,
        file.mimeType,
      );
    } catch (e) {
      toast.show('Не удалось прикрепить файл: $e');
    }
  }

  // Общее сохранение байтов файла в закладку (локально) — используется всеми
  // ветками листа вложений.
  Future<void> _saveBookmarkBytes(
    Uint8List bytes,
    String name,
    String? mime,
  ) async {
    await BookmarkStore.instance.addMessage(
      bookmarkId: widget.bookmarkId,
      fileName: name,
      fileMime: mime,
      fileBytes: bytes,
    );
    final msgs = await BookmarkStore.instance.getMessages(widget.bookmarkId);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(msgs);
    });
    _scrollToBottom();
  }

  Future<void> _openBookmarkFile(BookmarkMessage m) async {
    if (!m.hasFile) return;
    try {
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path, m.fileName!);
      final f = File(path);
      await f.writeAsBytes(m.fileBytes!, flush: true);
      await OpenFilex.open(path);
    } catch (e) {
      toast.show('Не удалось открыть файл: $e');
    }
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Переименовать закладку', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: GE.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    final ok = await BookmarkStore.instance.renameBookmark(
      widget.bookmarkId,
      newName,
    );
    if (ok && mounted) setState(() => _name = newName);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Удалить закладку?', style: TextStyle(color: GE.text)),
        content: Text(
          '«$_name» вместе со всем содержимым удалится с этого устройства.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Удалить', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await BookmarkStore.instance.deleteBookmark(widget.bookmarkId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          showBack: true,
          titleText: _name,
          actions: widget.isDefault
              ? null
              : [
                  PopupMenuButton<String>(
                    icon: Icon(CupertinoIcons.ellipsis_vertical, color: GE.sub),
                    color: GE.bgDeep,
                    onSelected: (v) {
                      if (v == 'rename') _rename();
                      if (v == 'delete') _delete();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'rename',
                        child: Text(
                          'Переименовать',
                          style: TextStyle(color: GE.text),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text('Удалить', style: TextStyle(color: GE.red)),
                      ),
                    ],
                  ),
                ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? const EmptyChatState(
                      icon: CupertinoIcons.bookmark,
                      title: 'Сообщений нет',
                      subtitle:
                          'Заметки и файлы видно только тебе — хранится на этом устройстве',
                    )
                  : Builder(
                      builder: (_) {
                        final bottomAnchor =
                            _messages.length <= _bottomAnchorMaxMsgs;
                        final list = ListView.builder(
                          shrinkWrap: bottomAnchor,
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.all(12),
                          itemCount: _messages.length,
                          itemBuilder: (_, i) => _bubble(_messages[i]),
                        );
                        return bottomAnchor
                            ? Align(
                                alignment: Alignment.bottomCenter,
                                child: list,
                              )
                            : list;
                      },
                    ),
            ),
            SafeArea(
              top: false,
              bottom: !_emojiOpen,
              child: ChatComposer(
                controller: _msgCtrl,
                emojiOpen: _emojiOpen,
                sending: _sending,
                sendKey: _sendBtnKey,
                hint: 'Заметка себе…',
                onAttach: _openAttachSheet,
                onToggleEmoji: _toggleEmoji,
                onSend: _sendText,
                onFieldTap: () {
                  if (_emojiOpen) setState(() => _emojiOpen = false);
                },
              ),
            ),
            if (_emojiOpen)
              SizedBox(
                height: _emojiPanelH,
                child: EmojiPicker(onPick: _insertEmoji),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _react(BookmarkMessage m) async {
    final emoji = await showReactionPalette(context);
    if (emoji == null) return;
    await BookmarkStore.instance.setReaction(m.id, emoji);
    final msgs = await BookmarkStore.instance.getMessages(widget.bookmarkId);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(msgs);
    });
  }

  /// Двойной тап — быстрая реакция сердцем; долгое нажатие по-прежнему
  /// открывает полный список реакций.
  Future<void> _quickReact(BookmarkMessage m) async {
    await BookmarkStore.instance.setReaction(m.id, quickReactionEmoji);
    final msgs = await BookmarkStore.instance.getMessages(widget.bookmarkId);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(msgs);
    });
  }

  Widget _bubble(BookmarkMessage m) {
    final time = DateTime.fromMillisecondsSinceEpoch(m.createdAt * 1000);
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onLongPress: () => _react(m),
        onDoubleTap: () => _quickReact(m),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: const BoxConstraints(maxWidth: 280),
          decoration: BoxDecoration(
            color: GE.primary.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.hasFile)
                InkWell(
                  onTap: () => _openBookmarkFile(m),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        CupertinoIcons.doc,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          m.fileName!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (m.text.isNotEmpty) ...[
                if (m.hasFile) const SizedBox(height: 4),
                EmojiText(
                  m.text,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
              if (m.reaction != null) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: EmojiText(
                    m.reaction!,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
              const SizedBox(height: 2),
              Text(
                '$hh:$mm',
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleEmoji() {
    setState(() => _emojiOpen = !_emojiOpen);
    if (_emojiOpen) FocusScope.of(context).unfocus();
  }

  void _insertEmoji(String e) {
    final text = _msgCtrl.text;
    final sel = _msgCtrl.selection;
    final start = sel.start < 0 ? text.length : sel.start;
    final end = sel.end < 0 ? text.length : sel.end;
    final next = text.replaceRange(start, end, e);
    _msgCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + e.length),
    );
  }
}
