// BookmarkChatScreen — "Избранное" и пользовательские закладки. Чисто
// локально: текст + файлы, ничего не уходит в сеть. "Избранное" (id=default)
// нельзя переименовать/удалить — остальные закладки можно.
import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
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
    setState(() => _sending = true);
    try {
      await BookmarkStore.instance.addMessage(bookmarkId: widget.bookmarkId, text: text);
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

  Future<void> _attachFile() async {
    final file = await openFile();
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      await BookmarkStore.instance.addMessage(
        bookmarkId: widget.bookmarkId,
        fileName: file.name,
        fileMime: file.mimeType,
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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось прикрепить файл: $e')),
      );
    }
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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось открыть файл: $e')),
      );
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    final ok = await BookmarkStore.instance.renameBookmark(widget.bookmarkId, newName);
    if (ok && mounted) setState(() => _name = newName);
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Удалить закладку?', style: TextStyle(color: GE.text)),
        content: Text('«$_name» вместе со всем содержимым удалится с этого устройства.',
            style: TextStyle(color: GE.sub)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
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
                    icon: Icon(Icons.more_vert, color: GE.sub),
                    color: GE.bgDeep,
                    onSelected: (v) {
                      if (v == 'rename') _rename();
                      if (v == 'delete') _delete();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'rename', child: Text('Переименовать', style: TextStyle(color: GE.text))),
                      PopupMenuItem(value: 'delete', child: Text('Удалить', style: TextStyle(color: GE.red))),
                    ],
                  ),
                ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Text(
                          'Пиши себе заметки или скидывай файлы — видно только тебе, хранится на этом устройстве.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: GE.sub, fontSize: 12.5, height: 1.4),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.all(12),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) => _bubble(_messages[i]),
                    ),
            ),
            _inputRow(),
          ],
        ),
      ),
    );
  }

  Widget _bubble(BookmarkMessage m) {
    final time = DateTime.fromMillisecondsSinceEpoch(m.createdAt * 1000);
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return Align(
      alignment: Alignment.centerRight,
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
                    const Icon(Icons.insert_drive_file_outlined, color: Colors.white, size: 18),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(m.fileName!,
                          style: const TextStyle(color: Colors.white, fontSize: 13, decoration: TextDecoration.underline)),
                    ),
                  ],
                ),
              ),
            if (m.text.isNotEmpty) ...[
              if (m.hasFile) const SizedBox(height: 4),
              Text(m.text, style: const TextStyle(color: Colors.white, fontSize: 14)),
            ],
            const SizedBox(height: 2),
            Text('$hh:$mm', style: const TextStyle(color: Colors.white70, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _inputRow() {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.attach_file, color: GE.sub),
            onPressed: _attachFile,
          ),
          Expanded(
            child: GlassInput(
              controller: _msgCtrl,
              hint: 'Заметка себе…',
              onSubmitted: (_) => _sendText(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.send_rounded, color: GE.primary),
            onPressed: _sendText,
          ),
        ],
      ),
    );
  }
}
