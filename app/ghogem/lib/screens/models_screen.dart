import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/api_service.dart';
import '../services/settings_service.dart';

class ModelsScreen extends StatefulWidget {
  final String initial; final Map<String,dynamic>? cache;
  const ModelsScreen({super.key, required this.initial, this.cache});
  @override State<ModelsScreen> createState()=>_ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  Map<String,dynamic>? _data;
  String _filter = '';
  int _providerIdx=0;
  bool _loading=true;
  String? _error;
  Set<String> _byokProviders = const {'pollinations','vireonix','persorai','cvron','visionster'};

  @override void initState(){ super.initState();
    _data = widget.cache;
    _loading = _data==null;
    _fetch();
  }
  Future<void> _fetch() async {
    try{
      final d = await GgApi.instance.models();
      final keys = await SettingsService.instance.getAllKeys();
      if(!mounted) return;
      setState((){_data=d; _byokProviders={..._byokProviders,...keys.keys}; _loading=false;});
      // set current provider idx to initial
      final provs = (d['providers'] as Map).keys.toList();
      final initProv = widget.initial.split(':').first;
      final idx = provs.indexOf(initProv);
      if(idx>=0) setState(()=>_providerIdx=idx);
    }catch(e){ if(mounted) setState((){_error=e.toString(); _loading=false;});}
  }

  @override Widget build(BuildContext context){
    final allProviders = _data==null ? <String>[] : ((_data!['providers'] as Map).keys.cast<String>().toList());
    // WorkAgent uses Pollinations through the server proxy for documented tools.
    final isWork = SettingsService.instance.mode==ChatMode.work;
    final isByok = SettingsService.instance.mode==ChatMode.byok;
    final anonIds = {'pollinations'};
    final providers = isWork
        ? allProviders.where((p)=> anonIds.contains(p)).toList()
        : isByok
            ? allProviders.where((p)=> _byokProviders.contains(p)).toList()
            : allProviders;
    if (providers.isEmpty && isWork && allProviders.isNotEmpty) {
      // fallback если anon ещё не загрузились — покажем все
    }
    final curProv = providers.isEmpty ? '' : providers[_providerIdx % providers.length];
    final models = _data==null ? <Map>[] : ((_data!['providers'][curProv] as List?)?.cast<Map>() ?? []);
    final filtered = models.where((m){
      if (_filter.isEmpty) return true;
      final f=_filter.toLowerCase();
      return (m['key'] as String).toLowerCase().contains(f) || (m['name'] as String).toLowerCase().contains(f);
    }).toList();

    return Scaffold(
      backgroundColor: GG.bg,
      appBar: AppBar(backgroundColor: GG.bgDeep, title: Text('Модели', style: TextStyle(color: GG.paper, fontFamily: 'Baskerville')), iconTheme: IconThemeData(color: GG.paper)),
      body: _loading ? Center(child: CircularProgressIndicator(color: GG.violet))
           : _error!=null ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: TextStyle(color: GG.red))))
           : Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(12,12,12,8), child: TextField(
          style: TextStyle(color: GG.paper), decoration: InputDecoration(hintText: 'Поиск модели…', hintStyle: TextStyle(color: GG.faint), prefixIcon: Icon(CupertinoIcons.search, color: GG.muted), filled: true, fillColor: GG.surface, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)),
          onChanged: (v)=>setState(()=>_filter=v),
        )),
        // provider tabs noir
        SizedBox(height: 44, child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 12), scrollDirection: Axis.horizontal, itemCount: providers.length,
          separatorBuilder: (_,_)=>const SizedBox(width: 8),
          itemBuilder: (_, i){
            final sel = i==_providerIdx;
            final label = providers[i];
            return InkWell(
              onTap: ()=>setState(()=>_providerIdx=i),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(color: sel? GG.paper : GG.surface, borderRadius: BorderRadius.circular(20)),
                child: Center(child: Text(label, style: TextStyle(color: sel? GG.bg : GG.dim, fontSize: 12, fontWeight: FontWeight.w600))),
              ),
            );
          },
        )),
        const SizedBox(height: 8),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
          Text(curProv, style: TextStyle(color: GG.faint, fontSize: 11, letterSpacing: 1.2, fontFamily: 'monospace')),
          const Spacer(),
          Text('${filtered.length} моделей', style: TextStyle(color: GG.faint, fontSize: 11, fontFamily: 'monospace')),
        ])),
        const SizedBox(height: 8),
        Expanded(child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12,0,12,12), itemCount: filtered.length,
          itemBuilder: (_, i){
            final m = filtered[i];
            final key = m['key'] as String;
            final isSel = key==widget.initial;
            final isPrem = m['premium']==true;
            final avail = m['available']!=false;
            final name = m['name'] as String? ?? key;
            final short = key.split(':').last;
            final params = m['params_label'] ?? (m['params_b']!=null ? '${(m['params_b'] as num).toStringAsFixed(m['params_b'] is int? 0:1)}B' : '');
            final tier = m['power_tier'] as String?;
            Color tierC = GG.muted;
            if(tier=='crown') {
              tierC = GG.yellow;
            } else if(tier=='green') tierC = GG.green;
            else if(tier=='yellow') tierC = GG.yellow;
            else if(tier=='red') tierC = GG.red;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(color: isSel? GG.violet.withValues(alpha: 0.22) : GG.surface, borderRadius: BorderRadius.circular(12)),
              child: ListTile(
                onTap: () async {
                  if (!avail) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m['status_detail'] ?? 'Модель недоступна'))); return; }
                  if (isPrem && SettingsService.instance.mode==ChatMode.server) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Premium — нужен Premium'))); 
                  }
                  // Work uses its no-key provider paths; premium credentials are not needed.
                  Navigator.pop(context, key);
                },
                title: Row(children: [
                  Container(width: 8,height: 8, decoration: BoxDecoration(color: avail? tierC : GG.red, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(name, style: TextStyle(color: GG.paper, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (isPrem) Container(margin: const EdgeInsets.only(left: 6), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: GG.yellow.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)), child: Text('PREMIUM', style: TextStyle(color: GG.yellow, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.6))),
                ]),
                subtitle: Text('$short · $params  ·  ${m['creator']??''}', style: TextStyle(color: GG.muted, fontSize: 11, fontFamily: 'monospace')),
                trailing: isSel ? Icon(CupertinoIcons.check_mark_circled_solid, color: GG.violet) : Icon(CupertinoIcons.chevron_right, color: GG.faint, size: 14),
              ),
            );
          },
        )),
      ]),
    );
  }
}
