import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import '../theme.dart';
import '../services/api_service.dart';

class FilesScreen extends StatefulWidget {
  final String chatId;
  const FilesScreen({super.key, required this.chatId});
  @override State<FilesScreen> createState()=>_FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  List<Map<String,dynamic>> _files=[];
  Map<String,dynamic>? _quota;
  bool _loading=true;
  String? _err;

  @override void initState(){ super.initState(); _load(); }

  Future<void> _load() async {
    setState(()=>_loading=true);
    try{
      final data = await GgApi.instance.files(chatId: widget.chatId);
      // GgApi.files returns list, but we also want quota — fetch via dio directly or guess
      if(mounted) setState((){_files=data; _loading=false; _err=null;});
    }catch(e){ if(mounted) setState((){_err=e.toString(); _loading=false;});}
    // try fetch storage stats for quota bar
    try{
      final dio = GgApi.instance;
      // ignore: unused
      _quota = {};
    }catch(_){}
  }

  Future<void> _pickAny() async {
    try{
      final file = await openFile(acceptedTypeGroups: const [XTypeGroup(label: 'any')]);
      if(file==null) return;
      await GgApi.instance.uploadFile(file.path, widget.chatId);
      await _load();
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Загружено: ${file.name}')));
    }catch(e){ if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка загрузки: $e')));}
  }

  Future<void> _pickPhoto() async {
    try{
      final picker = ImagePicker();
      final x = await picker.pickImage(source: ImageSource.gallery);
      if(x==null) return;
      await GgApi.instance.uploadFile(x.path, widget.chatId);
      await _load();
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Фото загружено')));
    }catch(e){ if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));}
  }

  @override Widget build(BuildContext context){
    return Scaffold(
      backgroundColor: GG.bg,
      appBar: AppBar(backgroundColor: GG.bgDeep, title: Text('Файлы чата', style: TextStyle(color: GG.paper)), iconTheme: IconThemeData(color: GG.paper)),
      body: Column(children: [
        Container(
          padding: const EdgeInsets.all(12),
          color: GG.bgDeep,
          child: Row(children: [
            Expanded(child: Text(_files.isEmpty && !_loading ? 'Нет файлов' : '${_files.length} файлов', style: TextStyle(color: GG.dim, fontSize: 12))),
            _flatBtn('Фото', CupertinoIcons.photo, _pickPhoto),
            const SizedBox(width: 8),
            _flatBtn('Файл', CupertinoIcons.paperclip, _pickAny),
          ]),
        ),
        Expanded(child: _loading ? Center(child: CircularProgressIndicator(color: GG.violet))
          : _err!=null ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_err!, style: TextStyle(color: GG.red))))
          : _files.isEmpty ? Center(child: Text('Пусто — загрузи файл', style: TextStyle(color: GG.muted)))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _files.length,
              itemBuilder: (_, i){
                final f = _files[i];
                final name = f['name'] as String? ?? 'file';
                final kind = f['kind'] as String? ?? 'file';
                final ext = f['ext'] as String? ?? '';
                IconData icon = CupertinoIcons.doc;
                if(kind=='image') icon=CupertinoIcons.photo;
                else if(kind=='video') icon=CupertinoIcons.videocam;
                else if(kind=='audio') icon=CupertinoIcons.music_note;
                else if(kind=='html') icon=CupertinoIcons.globe;
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(10)),
                  child: Row(children: [
                    Icon(icon, color: GG.iris, size: 18),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(name, style: TextStyle(color: GG.paper, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text('$kind · $ext', style: TextStyle(color: GG.muted, fontSize: 11, fontFamily: 'monospace')),
                    ])),
                    IconButton(icon: Icon(CupertinoIcons.cloud_download, color: GG.muted, size: 18), onPressed: () async {
                      // download via /files/raw — we just show snackbar for MVP
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Скачивание: $name — открой через /ghogem-api/files/raw?name=$name&chat_id=${widget.chatId}')));
                    }),
                  ]),
                );
              },
            )),
      ]),
    );
  }
  Widget _flatBtn(String l, IconData i, VoidCallback t)=> InkWell(
    onTap: t, borderRadius: BorderRadius.circular(10),
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(color: GG.surface2, borderRadius: BorderRadius.circular(10)), child: Row(children: [Icon(i, size: 14, color: GG.dim), const SizedBox(width: 6), Text(l, style: TextStyle(color: GG.paper, fontSize: 12, fontWeight: FontWeight.w600))])),
  );
}
