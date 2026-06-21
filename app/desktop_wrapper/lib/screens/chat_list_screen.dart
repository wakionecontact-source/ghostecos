// ChatListScreen — нативный список диалогов + поиск (юзеры/диалоги/сообщения).
//
// Поиск debounce 500мс. Префикс @ → приоритет юзерам по username, иначе
// диалоги первыми. Сообщения локальные (поиск по тексту в SQL LIKE).
// Тап на юзера/диалог → ChatScreen. Тап на сообщение → ChatScreen с highlightSid.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../theme.dart';
import '../services/chat_repo.dart';
import '../services/db_service.dart';
import '../services/search_service.dart';
import '../widgets/glass.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});
  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  bool _initialized = false;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;
  List<SearchHit>? _searchResults;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await ChatRepo.instance.init();
    if (mounted) setState(() => _initialized = true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _searchResults = null;
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      final results = await SearchService.instance.search(value);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _searching = false;
      });
    });
  }

  void _clearSearch() {
    _searchCtrl.clear();
    _debounce?.cancel();
    setState(() {
      _searchResults = null;
      _searching = false;
    });
    _searchFocus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return Center(child: CircularProgressIndicator(color: GE.primary));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.shield_outlined, color: GE.primary, size: 22),
              const SizedBox(width: 8),
              Text('Чаты',
                  style: TextStyle(
                      color: GE.text, fontSize: 20, fontWeight: FontWeight.w800)),
              const Spacer(),
              // Кнопка «Новый чат» убрана — поиск ниже сам открывает чат по
              // username (если совпадение точное, можно начать переписку).
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: GlassInput(
            controller: _searchCtrl,
            hint: 'Поиск: @username, имя или текст',
            icon: Icons.search,
            onChanged: _onSearchChanged,
            suffix: _searchCtrl.text.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.close, color: GE.sub, size: 18),
                    onPressed: _clearSearch,
                  )
                : null,
          ),
        ),
        Expanded(
          child: _searchResults != null
              ? _buildSearchResults()
              : _buildDialogs(),
        ),
      ],
    );
  }

  Widget _buildDialogs() {
    return ValueListenableBuilder<List<StoredDialog>>(
      valueListenable: ChatRepo.instance.dialogsNotifier,
      builder: (_, dialogs, _) {
        if (dialogs.isEmpty) return _empty();
        return RefreshIndicator(
          color: GE.primary,
          onRefresh: ChatRepo.instance.fetchPending,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            itemCount: dialogs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (_, i) => _DialogTile(dialogs[i]),
          ),
        );
      },
    );
  }

  Widget _buildSearchResults() {
    if (_searching && (_searchResults?.isEmpty ?? true)) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator(color: GE.primary)),
      );
    }
    final hits = _searchResults ?? [];
    if (hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Ничего не найдено',
              style: TextStyle(color: GE.sub, fontSize: 14)),
        ),
      );
    }
    final dialogsHits = hits.where((h) => h.dialog != null).toList();
    final usersHits = hits.where((h) => h.user != null).toList();
    final msgHits = hits.where((h) => h.message != null).toList();
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [
        if (dialogsHits.isNotEmpty) ...[
          _sectionHeader('Чаты'),
          ...dialogsHits.map((h) => _DialogTile(h.dialog!, onTap: _clearSearch)),
        ],
        if (usersHits.isNotEmpty) ...[
          _sectionHeader('Пользователи'),
          ...usersHits.map((h) => _UserTile(h.user!, onTap: _clearSearch)),
        ],
        if (msgHits.isNotEmpty) ...[
          _sectionHeader('Сообщения'),
          ...msgHits.map((h) => _MessageHitTile(
                h.message!,
                onTap: () {
                  _clearSearch();
                  _openMessage(h.message!);
                },
              )),
        ],
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Text(text.toUpperCase(),
          style: TextStyle(
              color: GE.sub, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
    );
  }

  void _openMessage(StoredMessage m) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(
        peer: m.peer,
        displayName: m.peer,
        highlightSid: m.sid,
      ),
    ));
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: GlassCard(
          lite: true,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline, size: 48, color: GE.primary),
              const SizedBox(height: 14),
              Text('Пока нет чатов',
                  style: TextStyle(color: GE.text, fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('Введи @username сверху, чтобы найти',
                  style: TextStyle(color: GE.sub, fontSize: 13),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              GlassButton(
                label: 'Новый чат',
                icon: Icons.edit_note,
                primary: true,
                onTap: () => _newChatPrompt(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _newChatPrompt(BuildContext context) async {
    final ctrl = TextEditingController();
    final username = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: Text('Новый чат', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: '@username',
            hintStyle: TextStyle(color: GE.sub),
          ),
          style: TextStyle(color: GE.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(
            onPressed: () {
              final u = ctrl.text.trim().replaceFirst('@', '');
              if (u.isNotEmpty) Navigator.pop(ctx, u);
            },
            child: const Text('Открыть'),
          ),
        ],
      ),
    );
    if (username == null || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatScreen(peer: username, displayName: username),
    ));
  }
}

// ────────────────────────────────────────────────────────────────────────
class _DialogTile extends StatelessWidget {
  final StoredDialog d;
  final VoidCallback? onTap;
  const _DialogTile(this.d, {this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(GE.radiusMd),
      onTap: () {
        onTap?.call();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatScreen(peer: d.username, displayName: d.displayName),
        ));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            GestureDetector(
              onTap: d.username.startsWith('g:')
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ProfileScreen(username: d.username),
                      )),
              child: _Avatar(d.displayName, size: 48),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(d.displayName,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: GE.text, fontSize: 15, fontWeight: FontWeight.w600,
                            )),
                      ),
                      Text(_formatTime(d.lastAt),
                          style: TextStyle(color: GE.sub, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(d.lastText.isEmpty ? '—' : d.lastText,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: GE.sub, fontSize: 13)),
                      ),
                      if (d.unread > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: GE.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('${d.unread > 99 ? "99+" : d.unread}',
                              style: const TextStyle(
                                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700,
                              )),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(dynamic at) {
    if (at == null) return '';
    DateTime dt;
    try {
      if (at is int) {
        dt = DateTime.fromMillisecondsSinceEpoch(at * 1000);
      } else {
        dt = DateTime.parse(at.toString());
      }
    } catch (_) { return ''; }
    final now = DateTime.now();
    final local = dt.toLocal();
    if (now.year == local.year && now.month == local.month && now.day == local.day) {
      return DateFormat('HH:mm').format(local);
    }
    final daysAgo = now.difference(local).inDays;
    if (daysAgo < 7) {
      try {
        return DateFormat('E', 'ru').format(local);
      } catch (_) {
        // Локаль ещё не успела инициализироваться — fallback.
        const days = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
        return days[local.weekday - 1];
      }
    }
    return DateFormat('dd.MM').format(local);
  }
}

// ────────────────────────────────────────────────────────────────────────
class _UserTile extends StatelessWidget {
  final FoundUser u;
  final VoidCallback? onTap;
  const _UserTile(this.u, {this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(GE.radiusMd),
      onTap: () {
        onTap?.call();
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatScreen(peer: u.username, displayName: u.displayName),
        ));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            _Avatar(u.displayName, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(u.displayName,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: GE.text, fontSize: 14, fontWeight: FontWeight.w600)),
                  Text('@${u.username}${u.isGuest ? " · гость" : ""}',
                      style: TextStyle(color: GE.sub, fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.chat_bubble_outline, color: GE.primary, size: 18),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
class _MessageHitTile extends StatelessWidget {
  final StoredMessage m;
  final VoidCallback onTap;
  const _MessageHitTile(this.m, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(GE.radiusMd),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            _Avatar(m.peer, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(m.peer,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: GE.text, fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    if (m.fromMe)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text('вы',
                            style: TextStyle(color: GE.sub, fontSize: 10)),
                      ),
                  ]),
                  const SizedBox(height: 2),
                  Text(m.text,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: GE.sub, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
class _Avatar extends StatelessWidget {
  final String name;
  final double size;
  const _Avatar(this.name, {this.size = 44});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
      ),
      alignment: Alignment.center,
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: TextStyle(
          color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.4,
        ),
      ),
    );
  }
}
