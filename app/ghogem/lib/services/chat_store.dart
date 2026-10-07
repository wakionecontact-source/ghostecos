import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ChatStore {
  static final ChatStore instance = ChatStore._();
  ChatStore._();
  Database? _db;
  bool _ffiInit = false;

  void _initFfiIfNeeded() {
    if (_ffiInit) return;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _ffiInit = true;
  }

  Future<Database> get db async {
    _initFfiIfNeeded();
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'ghogem.db');
    _db = await openDatabase(path, version: 3, onCreate: (d, v) async {
      await d.execute('''CREATE TABLE chats(
        id TEXT PRIMARY KEY, title TEXT, created_at INTEGER, updated_at INTEGER)''');
      await d.execute('''CREATE TABLE messages(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chat_id TEXT, role TEXT, content TEXT, created_at INTEGER,
        thinking TEXT, model_key TEXT, attachments TEXT,
        FOREIGN KEY(chat_id) REFERENCES chats(id) ON DELETE CASCADE)''');
      await d.execute('CREATE INDEX idx_msg_chat ON messages(chat_id)');
    }, onUpgrade: (d, o, n) async {
      if (o<2) {
        try { await d.execute('ALTER TABLE messages ADD COLUMN thinking TEXT'); } catch(_){}
        try { await d.execute('ALTER TABLE messages ADD COLUMN model_key TEXT'); } catch(_){}
      }
      if (o<3) {
        try { await d.execute('ALTER TABLE messages ADD COLUMN attachments TEXT'); } catch(_){}
      }
    });
    return _db!;
  }

  Future<String> createChat({String? title}) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final d = await db;
    await d.insert('chats', {'id': id, 'title': (title?.isEmpty ?? true) ? 'Новый чат' : title, 'created_at': now, 'updated_at': now});
    return id;
  }

  Future<List<Map<String,dynamic>>> listChats() async {
    final d = await db;
    final rows = await d.query('chats', orderBy: 'updated_at DESC');
    return rows;
  }

  Future<void> renameChat(String id, String title) async {
    final d = await db;
    await d.update('chats', {'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch ~/1000}, where: 'id=?', whereArgs: [id]);
  }

  Future<void> deleteChat(String id) async {
    final d = await db;
    await d.delete('chats', where: 'id=?', whereArgs: [id]);
    await d.delete('messages', where: 'chat_id=?', whereArgs: [id]);
    // also clean attachments dir
    try{
      final dir = await getApplicationDocumentsDirectory();
      final attDir = Directory(p.join(dir.path, 'ghogem_attachments', id));
      if (await attDir.exists()) await attDir.delete(recursive: true);
    }catch(_){}
  }

  Future<void> touchChat(String id) async {
    final d = await db;
    await d.update('chats', {'updated_at': DateTime.now().millisecondsSinceEpoch ~/1000}, where: 'id=?', whereArgs: [id]);
  }

  Future<void> addMessage(String chatId, String role, String content, {String? thinking, String? modelKey, List<Map<String,dynamic>>? attachments}) async {
    final d = await db;
    String? attJson;
    if (attachments!=null && attachments.isNotEmpty) {
      attJson = jsonEncode(attachments);
    }
    await d.insert('messages', {
      'chat_id': chatId, 'role': role, 'content': content,
      'thinking': thinking, 'model_key': modelKey, 'attachments': attJson,
      'created_at': DateTime.now().millisecondsSinceEpoch ~/1000,
    });
    await touchChat(chatId);
    // title теперь генерируется ИИ отдельно (см. _maybeGenerateTitle), а не первым сообщением
  }

  // Save attachments to disk and return JSON list for DB
  Future<List<Map<String,dynamic>>> saveAttachments(String chatId, List<Map<String, dynamic>> files) async {
    final dir = await getApplicationDocumentsDirectory();
    final chatDir = Directory(p.join(dir.path, 'ghogem_attachments', chatId));
    await chatDir.create(recursive: true);
    final out = <Map<String,dynamic>>[];
    for(final f in files){
      final name = f['name'] as String? ?? 'file';
      final bytes = f['bytes'] as Uint8List? ?? Uint8List(0);
      final mime = f['mime'] as String? ?? 'application/octet-stream';
      final safeName = name.replaceAll(RegExp(r'[^\w\-. ]'), '_');
      final fname = '${DateTime.now().millisecondsSinceEpoch}_${safeName}';
      final fpath = p.join(chatDir.path, fname);
      await File(fpath).writeAsBytes(bytes);
      out.add({
        'name': name,
        'mime': mime,
        'path': fpath,
        'size': bytes.length,
        'isImage': mime.startsWith('image/'),
        'isVideo': mime.startsWith('video/'),
        'isAudio': mime.startsWith('audio/'),
      });
    }
    return out;
  }

  Future<List<Map<String,dynamic>>> messages(String chatId) async {
    final d = await db;
    final rows = await d.query('messages', where: 'chat_id=?', whereArgs: [chatId], orderBy: 'id ASC');
    // decode attachments json
    for(final r in rows){
      final att = r['attachments'] as String?;
      if (att!=null && att.isNotEmpty) {
        try{ r['attachments'] = jsonDecode(att); }catch(_){ r['attachments'] = null; }
      }
    }
    return rows;
  }

  Future<void> clearChat(String id) async {
    final d = await db; await d.delete('messages', where: 'chat_id=?', whereArgs: [id]);
    try{
      final dir = await getApplicationDocumentsDirectory();
      final attDir = Directory(p.join(dir.path, 'ghogem_attachments', id));
      if (await attDir.exists()) await attDir.delete(recursive: true);
    }catch(_){}
  }
}

// helper for file data before saving
class _AttachmentFile {
  final String name;
  final Uint8List bytes;
  final String mime;
  _AttachmentFile({required this.name, required this.bytes, required this.mime});
}
