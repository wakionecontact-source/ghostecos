import 'work_service.dart';

const workTools = [
  {
    "type": "function",
    "function": {
      "name": "list_files",
      "description": "Список файлов и папок в рабочей директории Work (относительный путь, '' = корень)",
      "parameters": {"type": "object", "properties": {"path": {"type": "string", "description": "Относительный путь, '' для корня"}}, "required": []}
    }
  },
  {
    "type": "function",
    "function": {
      "name": "read_file",
      "description": "Прочитать текстовый файл из Work (до 5МБ)",
      "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write_file",
      "description": "Создать/перезаписать файл в Work (создаст папки если нужно)",
      "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}
    }
  },
  {
    "type": "function",
    "function": {
      "name": "edit_file",
      "description": "Точечно заменить oldString на newString в файле Work",
      "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "old_string": {"type": "string"}, "new_string": {"type": "string"}, "replace_all": {"type": "boolean"}}, "required": ["path", "old_string", "new_string"]}
    }
  },
  {
    "type": "function",
    "function": {
      "name": "delete_file",
      "description": "Удалить файл или папку в Work",
      "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}
    }
  },
];

Future<String> runWorkTool(String name, Map<String,dynamic> args) async {
  final ws = WorkService.instance;
  try{
    switch(name){
      case 'list_files':
        final path = (args['path'] as String? ?? '').trim();
        final list = await ws.list(path);
        if (list.isEmpty) return 'Папка пуста';
        return list.map((e)=> '${e['isDir'] ? 'DIR ' : 'FILE'} ${e['name']} ${e['isDir'] ? '' : '(${e['size']} Б)'}').join('\n');
      case 'read_file':
        final p = (args['path'] as String? ?? '').trim();
        if (p.isEmpty) return 'Укажи path';
        return await ws.read(p);
      case 'write_file':
        final p = (args['path'] as String? ?? '').trim();
        final c = (args['content'] as String? ?? '');
        if (p.isEmpty) return 'Укажи path';
        await ws.write(p, c);
        return 'Файл сохранён: $p';
      case 'edit_file':
        final p = (args['path'] as String? ?? '').trim();
        final oldS = (args['old_string'] as String? ?? '');
        final newS = (args['new_string'] as String? ?? '');
        final all = (args['replace_all'] as bool?) ?? false;
        return await ws.edit(p, oldS, newS, replaceAll: all);
      case 'delete_file':
        final p = (args['path'] as String? ?? '').trim();
        await ws.delete(p);
        return 'Удалено: $p';
      default:
        return 'Неизвестный tool: $name';
    }
  }catch(e){ return 'Ошибка: $e'; }
}

String workSystemPrompt(String workDir) {
  final safeDir = workDir.replaceAll('\\', '/');
  return 'You are GhostGem Work agent with local file tools. '
      'Work dir: $safeDir. '
      'Tools: list_files, read_file, write_file, edit_file, delete_file. '
      'Prefer edit_file for small edits. Stay inside work dir. '
      'Reply in Russian.';
}
