import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../theme.dart';
import '../services/settings_service.dart';

class MemoryScreen extends StatefulWidget { const MemoryScreen({super.key}); @override State<MemoryScreen> createState()=>_MemoryScreenState(); }

class _MemoryScreenState extends State<MemoryScreen> {
  late final TextEditingController _ctrl = TextEditingController(text: SettingsService.instance.customPrompt);
  // For server mode memory is file users/<uid>/memory.md, доступен через агента.
  // Здесь показываем локальную память + инструкцию как работает на сервере.
  @override Widget build(BuildContext context){
    return Scaffold(
      backgroundColor: GG.bg,
      appBar: AppBar(backgroundColor: GG.bgDeep, title: Text('Память агента', style: TextStyle(color: GG.paper)), iconTheme: IconThemeData(color: GG.paper)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Icon(CupertinoIcons.book, color: GG.violet, size: 16), const SizedBox(width: 8), Text('Как работает память', style: TextStyle(color: GG.paper, fontWeight: FontWeight.w700))]),
            const SizedBox(height: 8),
            Text('На сервере память хранится в users/<твой_id>/memory.md (общая для всех чатов). Агент читает её каждый запрос и обновляет через write_memory когда узнаёт важное (имя, предпочтения, договорённости). В BYOK-режиме память локальная — хранится на устройстве.', style: TextStyle(color: GG.muted, fontSize: 12, height: 1.5)),
            const SizedBox(height: 8),
            Text('Подскажи агенту: "запомни что я люблю тёмную тему" или "забудь про мой старый проект"', style: TextStyle(color: GG.dim, fontSize: 12, fontStyle: FontStyle.italic)),
          ]),
        ),
        const SizedBox(height: 16),
        Text('Кастомный системный промпт (переопределяет память на лету):', style: TextStyle(color: GG.muted, fontSize: 12)),
        const SizedBox(height: 8),
        TextField(
          controller: _ctrl, maxLines: 6, style: TextStyle(color: GG.paper, fontSize: 13),
          decoration: InputDecoration(hintText: 'Например: Ты — мой личный ассистент, помни что я CTO GhostEcos...', hintStyle: TextStyle(color: GG.faint), filled: true, fillColor: GG.surface, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)),
        ),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: () async { await SettingsService.instance.setCustomPrompt(_ctrl.text.trim()); if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Сохранено'))); },
          style: ElevatedButton.styleFrom(backgroundColor: GG.violet, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
          child: const Text('Сохранить'),
        )),
        const SizedBox(height: 12),
        Text('Память сервера редактируется диалогом: напиши боту "покажи что ты помнишь" или "обнови память: ..." — агент вызовет read_memory/write_memory.', style: TextStyle(color: GG.faint, fontSize: 11)),
      ]),
    );
  }
}
