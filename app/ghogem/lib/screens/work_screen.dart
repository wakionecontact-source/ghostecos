import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/work_service.dart';

class WorkScreen extends StatefulWidget {
  const WorkScreen({super.key});
  @override State<WorkScreen> createState()=>_WorkScreenState();
}

class _WorkScreenState extends State<WorkScreen> {
  String _dir = '';
  List<Map<String,dynamic>> _files=[];
  bool _loading=true;
  bool _confirm=false;
  String _path='';

  @override void initState(){ super.initState(); _load(); }

  Future<void> _load() async {
    final d = await WorkService.instance.getWorkDir();
    final c = await WorkService.instance.confirmWrites;
    final list = await WorkService.instance.list(_path);
    if(mounted) setState((){_dir=d; _confirm=c; _files=list; _loading=false;});
  }

  Future<void> _pickDir() async {
    final p = await getDirectoryPath();
    if(p==null) return;
    await WorkService.instance.setWorkDir(p);
    setState(()=>_path='');
    await _load();
  }

  @override Widget build(BuildContext context){
    return Scaffold(
      backgroundColor: GG.bg,
      appBar: AppBar(backgroundColor: GG.bgDeep, title: Text('Work', style: TextStyle(color: GG.paper)), iconTheme: IconThemeData(color: GG.paper)),
      body: _loading ? Center(child: CircularProgressIndicator(color: GG.violet)) : Column(children: [
        Container(
          padding: const EdgeInsets.all(12),
          color: GG.bgDeep,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Рабочая папка', style: TextStyle(color: GG.faint, fontSize: 10, letterSpacing: 1.2)),
            const SizedBox(height: 4),
            InkWell(
              onTap: _pickDir,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  Icon(CupertinoIcons.folder_fill, color: GG.violet, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_dir, style: TextStyle(color: GG.paper, fontSize: 12, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis)),
                  Icon(CupertinoIcons.chevron_right, color: GG.muted, size: 14),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Text('Подтверждение записи', style: TextStyle(color: GG.muted, fontSize: 12)),
              const Spacer(),
              Switch(value: _confirm, activeThumbColor: GG.violet, onChanged: (v) async { await WorkService.instance.setConfirmWrites(v); setState(()=>_confirm=v); }),
            ]),
            if (_path.isNotEmpty) InkWell(
              onTap: (){ setState(()=>_path=''); _load(); },
              child: Padding(padding: const EdgeInsets.only(top: 6), child: Text('← Корень', style: TextStyle(color: GG.iris, fontSize: 12))),
            ),
          ]),
        ),
        Expanded(child: _files.isEmpty ? Center(child: Text('Папка пуста', style: TextStyle(color: GG.muted))) : ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: _files.length,
          itemBuilder: (_, i){
            final f = _files[i];
            final isDir = f['isDir'] as bool;
            return InkWell(
              onTap: () async {
                if (isDir) {
                  setState(()=>_path = f['relative'] as String);
                  await _load();
                } else {
                  // preview first 5kb
                  try{
                    final content = await WorkService.instance.read(f['relative'] as String);
                    if(!mounted) return;
                    showDialog(context: context, builder: (_)=> AlertDialog(
                      backgroundColor: GG.bgCard,
                      title: Text(f['name'] as String, style: TextStyle(color: GG.paper, fontSize: 14)),
                      content: SizedBox(width: 400, child: SingleChildScrollView(child: SelectableText(content.length>4000 ? content.substring(0,4000) : content, style: TextStyle(color: GG.paper, fontSize: 12, fontFamily: 'monospace')))),
                      actions: [TextButton(onPressed: ()=>Navigator.pop(context), child: Text('Закрыть', style: TextStyle(color: GG.violet)))],
                    ));
                  }catch(e){ if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));}
                }
              },
              child: Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  Icon(isDir ? CupertinoIcons.folder_fill : CupertinoIcons.doc_fill, color: isDir ? GG.yellow : GG.iris, size: 18),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(f['name'] as String, style: TextStyle(color: GG.paper, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(isDir ? 'Папка' : '${f['size']} Б', style: TextStyle(color: GG.muted, fontSize: 11)),
                  ])),
                  if (!isDir) Icon(CupertinoIcons.eye, color: GG.faint, size: 14),
                ]),
              ),
            );
          },
        )),
      ]),
    );
  }
}
