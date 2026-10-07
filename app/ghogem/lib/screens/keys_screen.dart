import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/settings_service.dart';
import '../services/byok_service.dart';

class KeysScreen extends StatefulWidget { const KeysScreen({super.key}); @override State<KeysScreen> createState()=>_KeysScreenState(); }

class _KeysScreenState extends State<KeysScreen> {
  final _providers = const [
    ('groq','Groq','gsk_…'),
    ('mistral','Mistral AI','…'),
    ('openrouter','OpenRouter','sk-or-…'),
    ('sambanova','SambaNova','…'),
    ('bazaarlink','BazaarLink','…'),
    ('zveno','ZvenoAI','…'),
    ('freeai','Free.ai','sk-free-…'),
  ];
  Map<String,String> _keys={};
  bool _loading=true;
  final Map<String,TextEditingController> _ctrls={};
  final Map<String,String> _status={};

  @override void initState(){ super.initState(); _load(); }
  Future<void> _load() async {
    final m = await SettingsService.instance.getAllKeys();
    if(!mounted) return;
    setState((){_keys=m; _loading=false;});
    for(final p in _providers){ _ctrls[p.$1] ??= TextEditingController(text: m[p.$1]??'');}
  }

  Future<void> _save(String p) async {
    final v = _ctrls[p]!.text.trim();
    setState(()=>_status[p]='Сохранение…');
    await SettingsService.instance.setKey(p, v);
    setState(()=>_status[p]= v.isEmpty? 'Удалён' : 'Сохранён ');
    await Future.delayed(const Duration(seconds: 1));
    if(mounted) setState(()=>_status.remove(p));
    await _load();
  }

  Future<void> _probe(String p) async {
    final v = _ctrls[p]!.text.trim();
    if(v.isEmpty){ setState(()=>_status[p]='Введите ключ'); return; }
    setState(()=>_status[p]='Проверка…');
    final r = await ByokService.probe(p, v);
    if(!mounted) return;
    setState(()=>_status[p]= r=='ok' ? 'OK ' : r=='invalid' ? 'Неверный (401)' : r=='limited' ? 'OK, но в лимите 429' : 'Неизвестно');
  }

  @override Widget build(BuildContext context){
    return Scaffold(
      backgroundColor: GG.bg,
      appBar: AppBar(backgroundColor: GG.bgDeep, title: Text('Ключи BYOK', style: TextStyle(color: GG.paper, fontFamily: 'Baskerville')), iconTheme: IconThemeData(color: GG.paper)),
      body: _loading ? Center(child: CircularProgressIndicator(color: GG.violet))
      : ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: GG.surface, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Icon(CupertinoIcons.shield_lefthalf_fill, color: GG.iris, size: 16), const SizedBox(width: 8), Text('Как это работает', style: TextStyle(color: GG.paper, fontWeight: FontWeight.w700, fontSize: 13))]),
              const SizedBox(height: 8),
              Text('• Серверный режим: запросы через ghostecos.duckdns.org/ghogem-api (общие ключи, лимиты).\n• BYOK: запросы идут с устройства напрямую к выбранному провайдеру; ключ хранится локально и не передаётся нашему серверу.\n• Pollinations всегда идёт через серверный SOCKS-прокси с серверным ключом. Vireonix, CVRON, VisionSter и PersorAI работают без пользовательского ключа.\n• Можно комбинировать режимы и переключать их в шапке.', style: TextStyle(color: GG.muted, fontSize: 12, height: 1.5)),
            ]),
          ),
          const SizedBox(height: 16),
          ..._providers.map((pr){
            final id=pr.$1; final label=pr.$2; final hint=pr.$3;
            final has = (_keys[id]?.isNotEmpty ?? false);
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.fromLTRB(14,12,14,12),
              decoration: BoxDecoration(color: has? GG.surface2 : GG.surface, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(width: 8,height: 8, decoration: BoxDecoration(color: has? GG.green : GG.faint, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Text(label, style: TextStyle(color: GG.paper, fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(width: 8),
                  Text(id, style: TextStyle(color: GG.faint, fontFamily: 'monospace', fontSize: 11)),
                  const Spacer(),
                  if (_status[id]!=null) Text(_status[id]!, style: TextStyle(color: GG.iris, fontSize: 11, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 8),
                TextField(
                  controller: _ctrls[id],
                  obscureText: true, style: TextStyle(color: GG.paper, fontSize: 13, fontFamily: 'monospace'),
                  decoration: InputDecoration(hintText: hint, hintStyle: TextStyle(color: GG.faint, fontSize: 12), filled: true, fillColor: GG.bgDeep, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: OutlinedButton(onPressed: ()=>_probe(id), style: OutlinedButton.styleFrom(foregroundColor: GG.dim, side: BorderSide.none, backgroundColor: GG.surface2), child: Text('Проверить', style: TextStyle(fontSize: 12)))),
                  const SizedBox(width: 8),
                  Expanded(child: ElevatedButton(onPressed: ()=>_save(id), style: ElevatedButton.styleFrom(backgroundColor: GG.violet, foregroundColor: Colors.white), child: Text(_ctrls[id]!.text.trim().isEmpty && has ? 'Удалить' : 'Сохранить', style: TextStyle(fontSize: 12)))),
                ]),
              ]),
            );
          }),
          const SizedBox(height: 8),
          Text('Ключи создаются на сайтах провайдеров (Groq Console, Mistral, OpenRouter…). Pollinations использует серверный ключ; Vireonix, CVRON, VisionSter и PersorAI не требуют пользовательского ключа. Для чата Free.ai нужен ключ с префиксом sk-free-.', style: TextStyle(color: GG.faint, fontSize: 11, height: 1.4)),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
