// BookmarkChatScreen — "Избранное" и пользовательские закладки. Чисто
// локально: текст + файлы, ничего не уходит в сеть. "Избранное" (id=default)
// нельзя переименовать/удалить — остальные закладки можно.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;
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
import '../services/auth_service.dart';
import '../services/bookmark_store.dart';
import '../services/chat_organization_store.dart';
import '../services/chat_repo.dart';
import '../services/room_service.dart';

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
  final Map<String, GlobalKey> _messageKeys = {};
  late String _name;
  bool _sending = false;
  bool _emojiOpen = false;
  BookmarkMessage? _replyTo;
  BookmarkMessage? _editing;
  final _sendBtnKey = GlobalKey();
  final _imagePicker = ImagePicker();
  static const double _emojiPanelH = 300;
  // Мало сообщений — держим ленту у низа, рядом с полем ввода (как в
  // chat_screen.dart), а не приклеенной к шапке с пустотой снизу.
  static const int _bottomAnchorMaxMsgs = 40;

  List<BookmarkMessage> get _pinnedMessages =>
      _messages.where((message) => message.isPinned).toList(growable: false);

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
    final editing = _editing;
    final replyTo = _replyTo;
    flySendAnimation(context, _sendBtnKey);
    setState(() => _sending = true);
    try {
      if (editing != null) {
        await BookmarkStore.instance.editMessageText(
          messageId: editing.id,
          bookmarkId: widget.bookmarkId,
          text: text,
        );
      } else {
        await BookmarkStore.instance.addMessage(
          bookmarkId: widget.bookmarkId,
          text: text,
          replyTo: replyTo?.id,
          replyPreview: replyTo == null ? null : _messagePreview(replyTo),
        );
      }
      final msgs = await BookmarkStore.instance.getMessages(widget.bookmarkId);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(msgs);
        _msgCtrl.clear();
        _replyTo = null;
        _editing = null;
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
    if (_editing != null) {
      toast.show('Текстовые заметки редактируются без вложений');
      return;
    }
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
    final replyTo = _replyTo;
    await BookmarkStore.instance.addMessage(
      bookmarkId: widget.bookmarkId,
      fileName: name,
      fileMime: mime,
      fileBytes: bytes,
      replyTo: replyTo?.id,
      replyPreview: replyTo == null ? null : _messagePreview(replyTo),
    );
    final msgs = await BookmarkStore.instance.getMessages(widget.bookmarkId);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(msgs);
      _replyTo = null;
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
            if (_pinnedMessages.isNotEmpty) _pinnedBanner(),
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
                          itemBuilder: (_, i) => KeyedSubtree(
                            key: _messageKeys.putIfAbsent(
                              _messages[i].id,
                              GlobalKey.new,
                            ),
                            child: _bubble(_messages[i]),
                          ),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_replyTo != null || _editing != null) _replyEditBar(),
                  ChatComposer(
                    controller: _msgCtrl,
                    emojiOpen: _emojiOpen,
                    sending: _sending,
                    sendKey: _sendBtnKey,
                    hint: _editing == null
                        ? 'Заметка себе…'
                        : 'Изменить заметку…',
                    onAttach: _openAttachSheet,
                    onToggleEmoji: _toggleEmoji,
                    onSend: _sendText,
                    onFieldTap: () {
                      if (_emojiOpen) setState(() => _emojiOpen = false);
                    },
                  ),
                ],
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

  String _messagePreview(BookmarkMessage m) {
    if (m.text.isNotEmpty) return m.text;
    if (m.fileName != null) return '📎 ${m.fileName}';
    return 'Сообщение';
  }

  Widget _replyEditBar() {
    final editing = _editing;
    final replyTo = _replyTo;
    final title = editing != null ? 'Редактирование' : 'Ответ';
    final preview = editing != null
        ? _messagePreview(editing)
        : _messagePreview(replyTo!);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: GE.glassFill,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: GE.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: GE.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: GE.sub, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Отмена',
            onPressed: () {
              setState(() {
                _replyTo = null;
                _editing = null;
                _msgCtrl.clear();
              });
            },
            icon: Icon(CupertinoIcons.xmark, color: GE.sub, size: 17),
          ),
        ],
      ),
    );
  }

  Future<void> _openMessageActions(BookmarkMessage m) async {
    FocusManager.instance.primaryFocus?.unfocus();
    HapticFeedback.mediumImpact();
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _messageAction(
                  sheetContext,
                  'reply',
                  CupertinoIcons.reply,
                  'Ответить',
                ),
                _messageAction(
                  sheetContext,
                  'react',
                  CupertinoIcons.smiley,
                  'Поставить реакцию',
                ),
                _messageAction(
                  sheetContext,
                  'forward',
                  CupertinoIcons.arrowshape_turn_up_right,
                  'Переслать',
                ),
                _messageAction(
                  sheetContext,
                  'pin',
                  m.isPinned ? CupertinoIcons.pin_slash : CupertinoIcons.pin,
                  m.isPinned ? 'Открепить' : 'Закрепить',
                ),
                if (m.text.isNotEmpty)
                  _messageAction(
                    sheetContext,
                    'copy',
                    CupertinoIcons.doc_on_doc,
                    'Копировать',
                  ),
                if (m.text.isNotEmpty && !m.hasFile)
                  _messageAction(
                    sheetContext,
                    'edit',
                    CupertinoIcons.pencil,
                    'Редактировать',
                  ),
                _messageAction(
                  sheetContext,
                  'delete',
                  CupertinoIcons.trash,
                  'Удалить',
                  danger: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'reply':
        setState(() {
          _editing = null;
          _replyTo = m;
          _msgCtrl.clear();
        });
        break;
      case 'react':
        await _react(m);
        break;
      case 'forward':
        await _forwardMessage(m);
        break;
      case 'pin':
        await _togglePinned(m);
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        toast.show('Скопировано');
        break;
      case 'edit':
        setState(() {
          _replyTo = null;
          _editing = m;
          _msgCtrl.text = m.text;
          _msgCtrl.selection = TextSelection.collapsed(offset: m.text.length);
        });
        break;
      case 'delete':
        await _deleteMessage(m);
        break;
    }
  }

  Widget _pinnedBanner() {
    final pinned = _pinnedMessages;
    final latest = pinned.last;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _showPinnedMessages,
        child: GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Icon(CupertinoIcons.pin_fill, color: GE.primary, size: 17),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pinned.length == 1
                          ? 'Закреплённое сообщение'
                          : 'Закреплённые · ${pinned.length}',
                      style: TextStyle(
                        color: GE.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _messagePreview(latest),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: GE.text, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(CupertinoIcons.chevron_right, color: GE.sub, size: 15),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showPinnedMessages() async {
    final pinned = _pinnedMessages.reversed.toList(growable: false);
    final selectedId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: SizedBox(
              height: MediaQuery.of(sheetContext).size.height * .55,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Закреплённые сообщения',
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      itemCount: pinned.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: GE.sub.withValues(alpha: .15),
                      ),
                      itemBuilder: (_, index) {
                        final message = pinned[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(CupertinoIcons.pin, color: GE.primary),
                          title: Text(
                            _messagePreview(message),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: GE.text, fontSize: 13),
                          ),
                          onTap: () => Navigator.pop(sheetContext, message.id),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (selectedId != null && mounted) {
      await _scrollToMessage(selectedId);
    }
  }

  Future<void> _scrollToMessage(String messageId) async {
    final index = _messages.indexWhere((message) => message.id == messageId);
    if (index < 0 || !_scrollCtrl.hasClients) return;
    final maxExtent = _scrollCtrl.position.maxScrollExtent;
    final ratio = _messages.length <= 1 ? 0.0 : index / (_messages.length - 1);
    await _scrollCtrl.animateTo(
      maxExtent * ratio,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
    await WidgetsBinding.instance.endOfFrame;
    final targetContext = _messageKeys[messageId]?.currentContext;
    if (targetContext != null && mounted) {
      await Scrollable.ensureVisible(
        targetContext,
        alignment: .4,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _togglePinned(BookmarkMessage message) async {
    final pinned = !message.isPinned;
    await BookmarkStore.instance.setMessagePinned(
      messageId: message.id,
      bookmarkId: widget.bookmarkId,
      pinned: pinned,
    );
    final messages = await BookmarkStore.instance.getMessages(
      widget.bookmarkId,
    );
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(messages);
    });
    toast.show(pinned ? 'Сообщение закреплено' : 'Закрепление снято');
  }

  Future<void> _forwardMessage(BookmarkMessage message) async {
    final target = await _pickForwardTarget(includeRooms: true);
    if (target == null || !mounted) return;
    try {
      final author = await AuthService.username() ?? 'Избранное';
      final forwardedCaption = message.text.trim().isEmpty
          ? '↪ $author'
          : '↪ $author\n${message.text.trim()}';
      if (target.room != null) {
        if (message.hasFile) {
          await RoomService.instance.sendAttachment(
            target.room!,
            bytes: message.fileBytes!,
            mime: message.fileMime ?? 'application/octet-stream',
            fileName: message.fileName ?? 'attachment',
            caption: forwardedCaption,
          );
        } else {
          await RoomService.instance.sendText(
            target.room!,
            message.text,
            forwardedFrom: author,
          );
        }
      } else {
        final username = target.username!;
        if (message.hasFile) {
          await ChatRepo.instance.sendDmFile(
            toUsername: username,
            bytes: message.fileBytes!,
            mime: message.fileMime ?? 'application/octet-stream',
            fileName: message.fileName ?? 'attachment',
            caption: forwardedCaption,
          );
        } else if (message.text.isNotEmpty) {
          await ChatRepo.instance.sendDmText(
            username,
            message.text,
            forwardedFrom: author,
          );
        }
      }
      toast.show('Сообщение переслано');
    } catch (error) {
      toast.show('Не удалось переслать: $error');
    }
  }

  Future<RoomForwardTarget?> _pickForwardTarget({
    required bool includeRooms,
  }) async {
    final organization = ChatOrganizationStore.instance;
    final dialogs = ChatRepo.instance.dialogsNotifier.value
        .where(
          (dialog) =>
              !dialog.username.startsWith('g:') &&
              !dialog.username.startsWith('bm:') &&
              !dialog.username.startsWith('lan:'),
        )
        .where(
          (dialog) => organization.canSeeChatInActiveScenario(dialog.username),
        )
        .toList(growable: false);
    var rooms = includeRooms
        ? RoomService.instance.rooms.value
        : <RoomSummary>[];
    if (includeRooms && rooms.isEmpty) {
      try {
        rooms = await RoomService.instance.loadMy();
      } catch (_) {}
    }
    rooms = rooms
        .where(
          (room) =>
              organization.canSeeChatInActiveScenario(roomDialogKey(room)),
        )
        .toList(growable: false);
    return showModalBottomSheet<RoomForwardTarget>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SizedBox(
              height: MediaQuery.of(sheetContext).size.height * .65,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Переслать кому?',
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final dialog in dialogs)
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor: GE.primary2,
                              child: const Icon(
                                CupertinoIcons.person,
                                color: GE.text,
                                size: 18,
                              ),
                            ),
                            title: Text(
                              '@${dialog.username}',
                              style: TextStyle(color: GE.text),
                            ),
                            onTap: () => Navigator.pop(
                              sheetContext,
                              RoomForwardTarget.user(dialog.username),
                            ),
                          ),
                        for (final room in rooms)
                          ListTile(
                            leading: Icon(
                              room.isChannel
                                  ? CupertinoIcons.antenna_radiowaves_left_right
                                  : CupertinoIcons.person_3_fill,
                              color: GE.primary,
                            ),
                            title: Text(
                              room.title,
                              style: TextStyle(color: GE.text),
                            ),
                            onTap: () => Navigator.pop(
                              sheetContext,
                              RoomForwardTarget.room(room),
                            ),
                          ),
                        if (dialogs.isEmpty && rooms.isEmpty)
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _messageAction(
    BuildContext context,
    String value,
    IconData icon,
    String label, {
    bool danger = false,
  }) => ListTile(
    dense: true,
    leading: Icon(icon, color: danger ? GE.red : GE.primary),
    title: Text(label, style: TextStyle(color: danger ? GE.red : GE.text)),
    onTap: () => Navigator.pop(context, value),
  );

  Future<void> _deleteMessage(BookmarkMessage m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Удалить заметку?', style: TextStyle(color: GE.text)),
        content: Text(
          'Это действие удалит сообщение из локальной закладки.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Удалить', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await BookmarkStore.instance.deleteMessage(m.id, widget.bookmarkId);
    final msgs = await BookmarkStore.instance.getMessages(widget.bookmarkId);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(msgs);
      if (_replyTo?.id == m.id) _replyTo = null;
      if (_editing?.id == m.id) {
        _editing = null;
        _msgCtrl.clear();
      }
    });
  }

  Widget _bubble(BookmarkMessage m) {
    final time = DateTime.fromMillisecondsSinceEpoch(m.createdAt * 1000);
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        onLongPress: () => _openMessageActions(m),
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
              if (m.isPinned)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        CupertinoIcons.pin_fill,
                        color: GE.sub,
                        size: 11,
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        'Закреплено',
                        style: TextStyle(color: GE.sub, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              if (m.replyPreview != null) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 5),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: GE.text.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(7),
                    border: Border(
                      left: BorderSide(color: GE.sub, width: 2),
                    ),
                  ),
                  child: Text(
                    m.replyPreview!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: GE.sub, fontSize: 11),
                  ),
                ),
              ],
              if (m.hasFile)
                InkWell(
                  onTap: () => _openBookmarkFile(m),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        CupertinoIcons.doc,
                        color: GE.text,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          m.fileName!,
                          style: const TextStyle(
                            color: GE.text,
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
                  style: const TextStyle(color: GE.text, fontSize: 14),
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
                    color: GE.text.withValues(alpha: 0.18),
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
                '${m.editedAt == null ? '' : 'изменено · '}$hh:$mm',
                style: const TextStyle(color: GE.sub, fontSize: 10),
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
