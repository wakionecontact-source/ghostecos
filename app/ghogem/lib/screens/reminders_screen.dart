import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/api_service.dart';
import 'package:dio/dio.dart';

class RemindersScreen extends StatefulWidget { const RemindersScreen({super.key}); @override State<RemindersScreen> createState()=>_RemindersScreenState(); }

class _RemindersScreenState extends State<RemindersScreen> {
  List<Map<String,dynamic>> _tasks=[];
  bool _loading=true;
  String? _err;

  @override void initState(){ super.initState(); _load(); }

  Future<void> _load() async {
    setState(()=>_loading=true);
    try{
      final dio = Dio(BaseOptions(baseUrl: GG.apiGhogem, headers: {'Content-Type':'application/json'}));
      final r = await dio.get('/reminders', queryParameters: {'include_finished': false});
      final tasks = (r.data['tasks'] as List).cast<Map<String,dynamic>>();
      if(mounted) setState((){_tasks=tasks; _loading=false;});
    }catch(e){ if(mounted) setState((){_err=e.toString(); _loading=false;});}
  }

  Future<void> _create() async {
    final title = TextEditingController();
    final instruction = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (_)=> AlertDialog(
      backgroundColor: GG.bgCard, title: Text('Новое напоминание', style: TextStyle(color: GG.paper)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: title, decoration: InputDecoration(hintText: 'Название (до 120)', hintStyle: TextStyle(color: GG.faint), filled: true, fillColor: GG.surface, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none)), style: TextStyle(color: GG.paper)),
        const SizedBox(height: 8),
        TextField(controller: instruction, maxLines: 3, decoration: InputDecoration(hintText: 'Инструкция для агента / текст для text-режима', hintStyle: TextStyle(color: GG.faint), filled: true, fillColor: GG.surface, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none)), style: TextStyle(color: GG.paper)),
        const SizedBox(height: 8),
        Text('Время: сейчас + 1 час (MVP). Для точного времени используй чат: "напомни завтра в 15:00"', style: TextStyle(color: GG.faint, fontSize: 11)),
      ]),
      actions: [TextButton(onPressed: ()=>Navigator.pop(context,false), child: Text('Отмена', style: TextStyle(color: GG.muted))), TextButton(onPressed: ()=>Navigator.pop(context,true), child: Text('Создать', style: TextStyle(color: GG.violet)))],
    ));
    if(ok!=true) return;
    try{
      final dio = Dio(BaseOptions(baseUrl: GG.apiGhogem, headers: {'Content-Type':'application/json'}));
      final runAt = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
      await dio.post('/reminders', data: {'title': title.text.trim().isEmpty? 'Напоминание' : title.text.trim(), 'instruction': instruction.text.trim().isEmpty? 'Напомни!' : instruction.text.trim(), 'run_at': runAt, 'recurrence': 'once', 'weekdays': [], 'execution_mode': 'text'});
      await _load();
    }catch(e){ if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));}
  }

  @override Widget build(BuildContext context){
    return Scaffold(
      backgroundColor: GG.bg,
      appBar: AppBar(backgroundColor: GG.bgDeep, title: Text('Напоминания', style: TextStyle(color: GG.paper)), iconTheme: IconThemeData(color: GG.paper), actions: [IconButton(icon: Icon(CupertinoIcons.refresh, color: GG.paper), onPressed: _load)]),
      floatingActionButton: FloatingActionButton(onPressed: _create, backgroundColor: GG.violet, child: Icon(CupertinoIcons.add, color: Colors.white)),
      body: _loading ? Center(child: CircularProgressIndicator(color: GG.violet))
        : _err!=null ? Center(child: Text(_err!, style: TextStyle(color: GG.red)))
        : _tasks.isEmpty ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(CupertinoIcons.alarm, color: GG.faint, size: 36),
            const SizedBox(height: 12),
            Text('Нет активных напоминаний', style: TextStyle(color: GG.muted)),
            const SizedBox(height: 8),
            Text('Создай через + или скажи агенту: "напомни завтра в 9:00 про стендап"', style: TextStyle(color: GG.faint, fontSize: 11), textAlign: TextAlign.center),
          ]))
        : ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _tasks.length,
            itemBuilder: (_, i){
              final t = _tasks[i];
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(10)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t['title'] as String? ?? 'Без названия', style: TextStyle(color: GG.paper, fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text(t['instruction'] as String? ?? '', style: TextStyle(color: GG.muted, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  Row(children: [
                    Text(t['run_label'] as String? ?? '', style: TextStyle(color: GG.faint, fontSize: 11, fontFamily: 'monospace')),
                    const Spacer(),
                    Text(t['status'] as String? ?? '', style: TextStyle(color: GG.iris, fontSize: 11)),
                  ]),
                  if(t['id']!=null) Row(children: [
                    TextButton(onPressed: () async { try{ final dio=Dio(BaseOptions(baseUrl: GG.apiGhogem)); await dio.post('/reminders/${t['id']}/skip'); await _load(); }catch(e){ if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка skip: $e')));} }, child: Text('Пропустить', style: TextStyle(color: GG.dim, fontSize: 11))),
                    TextButton(onPressed: () async { try{ final dio=Dio(BaseOptions(baseUrl: GG.apiGhogem)); await dio.delete('/reminders/${t['id']}'); await _load(); }catch(e){ if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка delete: $e')));} }, child: Text('Удалить', style: TextStyle(color: GG.red, fontSize: 11))),
                  ]),
                ]),
              );
            },
          ),
    );
  }
}
