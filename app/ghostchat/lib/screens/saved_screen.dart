// SavedScreen — «Избранное» / личные заметки себе.
//
// Чисто ЛОКАЛЬНЫЙ экран: ничего не отправляет в чат/сеть. Заметки хранятся
// в SharedPreferences под ключом 'saved_notes' как JSON-список строк
// [{"t": "текст", "ts": 1700000000000}, ...]. Переживают перезапуск:
// читаем в initState, пишем при каждом изменении (добавление/удаление).
//
// UI: список заметок (GlassCard на каждую) со свайпом и кнопкой удаления,
// поле ввода снизу + кнопка добавить. При пустом списке — мягкая заглушка.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../widgets/skeleton.dart';

class SavedScreen extends StatefulWidget {
  const SavedScreen({super.key});
  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _Note {
  final String text;
  final int ts; // millisecondsSinceEpoch
  const _Note(this.text, this.ts);

  Map<String, dynamic> toJson() => {'t': text, 'ts': ts};

  static _Note fromJson(Map<String, dynamic> m) => _Note(
        (m['t'] as String?) ?? '',
        (m['ts'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      );
}

class _SavedScreenState extends State<SavedScreen> {
  static const _prefsKey = 'saved_notes';
  static const _maxLen = 4000; // защита от гигантских строк в хранилище

  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<_Note> _notes = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefsKey);
      final list = <_Note>[];
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              list.add(_Note.fromJson(Map<String, dynamic>.from(item)));
            } else if (item is String) {
              // Совместимость со старым форматом — просто список строк.
              list.add(_Note(item, 0));
            }
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _notes = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = jsonEncode(_notes.map((n) => n.toJson()).toList());
      await sp.setString(_prefsKey, raw);
    } catch (_) {
      // Тихо: даже если запись сорвалась, текущий сеанс остаётся рабочим.
    }
  }

  void _add() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final clipped = text.length > _maxLen ? text.substring(0, _maxLen) : text;
    setState(() {
      _notes.insert(
        0,
        _Note(clipped, DateTime.now().millisecondsSinceEpoch),
      );
      _input.clear();
    });
    _save();
    // Прокрутить к свежей заметке (она вверху списка).
    if (_scroll.hasClients) {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut);
    }
  }

  void _remove(int index) {
    if (index < 0 || index >= _notes.length) return;
    final removed = _notes[index];
    setState(() => _notes.removeAt(index));
    _save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Заметка удалена'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: 'Вернуть',
          textColor: GE.primary,
          onPressed: () {
            setState(() {
              final at = index <= _notes.length ? index : _notes.length;
              _notes.insert(at, removed);
            });
            _save();
          },
        ),
      ),
    );
  }

  String _fmtTime(int ts) {
    if (ts <= 0) return '';
    try {
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      final now = DateTime.now();
      final sameDay = dt.year == now.year &&
          dt.month == now.month &&
          dt.day == now.day;
      if (sameDay) return DateFormat('HH:mm').format(dt);
      return DateFormat('dd.MM.yyyy · HH:mm').format(dt);
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(child: _scaffold(context));
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      appBar: GlassAppBar(showBack: true, titleText: 'Избранное'),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: _loading
                  ? const SkeletonTextCardList()
                  : _notes.isEmpty
                      ? _empty()
                      : _list(),
            ),
            _composer(),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      itemCount: _notes.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        if (i == 0) return _hint();
        final idx = i - 1;
        final n = _notes[idx];
        return _NoteTile(
          key: ValueKey('${n.ts}_$idx'),
          text: n.text,
          time: _fmtTime(n.ts),
          onDelete: () => _remove(idx),
          onCopy: () {
            Clipboard.setData(ClipboardData(text: n.text));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Скопировано'),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
        );
      },
    );
  }

  Widget _hint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Text(
        'Заметки видны только тебе и хранятся на этом устройстве. '
        'Смахни заметку влево, чтобы удалить.',
        style: TextStyle(color: GE.sub, fontSize: 11, height: 1.4),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: GlassCard(
          lite: true,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: GE.primary.withValues(alpha: 0.16),
                  border: Border.all(
                      color: GE.primary.withValues(alpha: 0.35), width: 1),
                ),
                child: Icon(Icons.bookmark_outline,
                    color: GE.primary, size: 30),
              ),
              const SizedBox(height: 16),
              Text(
                'Здесь твои сохранённые заметки',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: GE.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Напиши мысль, ссылку или напоминание себе — '
                'оно сохранится на этом устройстве.',
                textAlign: TextAlign.center,
                style: TextStyle(color: GE.sub, fontSize: 12, height: 1.45),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: GlassInput(
              controller: _input,
              hint: 'Заметка себе…',
              icon: Icons.edit_note,
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: 10),
          GlassButton(
            label: 'Добавить',
            icon: Icons.add,
            primary: true,
            onTap: _add,
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
class _NoteTile extends StatelessWidget {
  final String text;
  final String time;
  final VoidCallback onDelete;
  final VoidCallback onCopy;

  const _NoteTile({
    super.key,
    required this.text,
    required this.time,
    required this.onDelete,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: key ?? UniqueKey(),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        decoration: BoxDecoration(
          color: GE.red.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(GE.radiusMd),
          border: Border.all(color: GE.red.withValues(alpha: 0.4)),
        ),
        child: Icon(Icons.delete_outline, color: GE.red, size: 24),
      ),
      child: GlassCard(
        lite: true,
        onTap: onCopy,
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    style: TextStyle(
                        color: GE.text, fontSize: 14, height: 1.4),
                  ),
                  if (time.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      time,
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(Icons.delete_outline, color: GE.sub, size: 18),
              tooltip: 'Удалить',
              visualDensity: VisualDensity.compact,
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
