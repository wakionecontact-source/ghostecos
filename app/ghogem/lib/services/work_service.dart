import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WorkService {
  static final WorkService instance = WorkService._();
  WorkService._();

  String? _cachedDir;

  Future<String> getWorkDir() async {
    if (_cachedDir != null) return _cachedDir!;
    final prefs = await SharedPreferences.getInstance();
    String? dir = prefs.getString('work_dir');
    if (dir != null && dir.isNotEmpty && await Directory(dir).exists()) {
      _cachedDir = dir;
      return dir;
    }
    // default: ghogem home if exists, else Documents/GhostGemWork
    const candidates = [
      r'C:\Users\Home\GE',
      r'C:\Users\Home\GE\server\ghogem',
    ];
    for (final c in candidates) {
      if (await Directory(c).exists()) {
        _cachedDir = c;
        await prefs.setString('work_dir', c);
        return c;
      }
    }
    final docs = await getApplicationDocumentsDirectory();
    final fallback = p.join(docs.path, 'GhostGemWork');
    await Directory(fallback).create(recursive: true);
    _cachedDir = fallback;
    await prefs.setString('work_dir', fallback);
    return fallback;
  }

  Future<void> setWorkDir(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('work_dir', path);
    _cachedDir = path;
  }

  Future<bool> get confirmWrites async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('work_confirm_writes') ?? false;
  }

  Future<void> setConfirmWrites(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('work_confirm_writes', v);
  }

  String _safeJoin(String base, String rel) {
    final baseReal = p.normalize(p.absolute(base));
    final full = p.normalize(p.join(baseReal, rel));
    if (full == baseReal || p.isWithin(baseReal, full)) return full;
    throw Exception('Недопустимый путь: $rel');
  }

  Future<List<Map<String,dynamic>>> list(String relPath) async {
    final base = await getWorkDir();
    final target = relPath.isEmpty ? base : _safeJoin(base, relPath);
    final dir = Directory(target);
    if (!await dir.exists()) return [];
    final out = <Map<String,dynamic>>[];
    await for (final e in dir.list(followLinks: false)) {
      final stat = await e.stat();
      out.add({
        'name': p.basename(e.path),
        'path': e.path,
        'relative': p.relative(e.path, from: base),
        'isDir': stat.type == FileSystemEntityType.directory,
        'size': stat.size,
        'modified': stat.modified.millisecondsSinceEpoch ~/ 1000,
      });
    }
    out.sort((a,b){
      if (a['isDir']!=b['isDir']) return a['isDir'] ? -1 : 1;
      return (a['name'] as String).compareTo(b['name'] as String);
    });
    return out;
  }

  Future<String> read(String relPath) async {
    final base = await getWorkDir();
    final full = _safeJoin(base, relPath);
    final f = File(full);
    if (!await f.exists()) throw Exception('Файл не найден: $relPath');
    if (await f.length() > 5*1024*1024) throw Exception('Файл слишком большой (>5МБ)');
    return f.readAsString();
  }

  Future<void> write(String relPath, String content) async {
    final base = await getWorkDir();
    final full = _safeJoin(base, relPath);
    await Directory(p.dirname(full)).create(recursive: true);
    await File(full).writeAsString(content);
  }

  Future<String> edit(String relPath, String oldString, String newString, {bool replaceAll=false}) async {
    final base = await getWorkDir();
    final full = _safeJoin(base, relPath);
    final f = File(full);
    if (!await f.exists()) throw Exception('Файл не найден: $relPath');
    String content = await f.readAsString();
    if (!content.contains(oldString)) throw Exception('Строка для замены не найдена');
    final count = oldString.allMatches(content).length;
    final newContent = replaceAll ? content.replaceAll(oldString, newString) : content.replaceFirst(oldString, newString);
    await f.writeAsString(newContent);
    return 'Заменено $count → ${replaceAll ? count : 1}';
  }

  Future<void> delete(String relPath) async {
    final base = await getWorkDir();
    final full = _safeJoin(base, relPath);
    final type = await FileSystemEntity.type(full);
    if (type == FileSystemEntityType.notFound) throw Exception('Не найдено: $relPath');
    if (type == FileSystemEntityType.directory) {
      await Directory(full).delete(recursive: true);
    } else {
      await File(full).delete();
    }
  }
}
