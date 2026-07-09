// LogsScreen — просмотр внутренних логов (перенесено из 1.19.3, дизайн Ghost).
// Пока пишут только LAN/BLE/Wi-Fi Direct транспорты (core/local/app_logger.dart) —
// единственная часть приложения с этим логгером сейчас.
import 'dart:async';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../core/local/app_logger.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});
  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final _scrollCtrl = ScrollController();
  StreamSubscription<LogEntry>? _sub;
  List<LogEntry> _logs = [];
  String _filter = 'all';
  bool _autoScroll = true;
  bool _showDebug = false;

  static const _categories = ['all', 'lan', 'bt', 'wifi_direct'];

  @override
  void initState() {
    super.initState();
    _logs = List.of(appLog.entries);
    _sub = appLog.onLog.listen((entry) {
      if (!mounted) return;
      setState(() => _logs.add(entry));
      if (_autoScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  List<LogEntry> get _filtered {
    var list = _logs;
    if (!_showDebug) list = list.where((e) => e.level != 'debug').toList();
    if (_filter != 'all') list = list.where((e) => e.category == _filter).toList();
    return list;
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'error': return GE.red;
      case 'warn':  return GE.yellow;
      case 'debug': return GE.muted;
      default:      return GE.text;
    }
  }

  Color _categoryColor(String cat) {
    switch (cat) {
      case 'lan':         return const Color(0xFF22C55E);
      case 'bt':          return const Color(0xFF60A5FA);
      case 'wifi_direct': return const Color(0xFF34D399);
      default:            return GE.sub;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          showBack: true,
          titleText: 'Логи (${filtered.length})',
          actions: [
            IconButton(
              icon: Icon(_showDebug ? Icons.bug_report : Icons.bug_report_outlined,
                  color: _showDebug ? GE.primary : GE.sub, size: 20),
              tooltip: 'Debug',
              onPressed: () => setState(() => _showDebug = !_showDebug),
            ),
            IconButton(
              icon: Icon(Icons.vertical_align_bottom,
                  color: _autoScroll ? GE.primary : GE.sub, size: 20),
              tooltip: 'Автопрокрутка',
              onPressed: () => setState(() => _autoScroll = !_autoScroll),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: GE.sub, size: 20),
              tooltip: 'Очистить',
              onPressed: () => setState(() { appLog.clear(); _logs.clear(); }),
            ),
          ],
        ),
        body: Column(
          children: [
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                itemCount: _categories.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final cat = _categories[i];
                  final active = _filter == cat;
                  final c = active ? _categoryColor(cat) : GE.sub;
                  return GestureDetector(
                    onTap: () => setState(() => _filter = cat),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.withValues(alpha: active ? 0.18 : 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: c.withValues(alpha: active ? 0.5 : 0.2)),
                      ),
                      child: Text(cat, style: TextStyle(color: c, fontSize: 11.5)),
                    ),
                  );
                },
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text('Нет логов', style: TextStyle(color: GE.sub, fontSize: 13)),
                    )
                  : ListView.builder(
                      controller: _scrollCtrl,
                      itemCount: filtered.length,
                      padding: const EdgeInsets.all(10),
                      itemBuilder: (_, i) {
                        final e = filtered[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: RichText(
                            text: TextSpan(
                              style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.4),
                              children: [
                                TextSpan(text: '${e.timeStr} ', style: TextStyle(color: GE.muted)),
                                TextSpan(text: '[${e.category}] ', style: TextStyle(color: _categoryColor(e.category))),
                                TextSpan(text: e.message, style: TextStyle(color: _levelColor(e.level))),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
