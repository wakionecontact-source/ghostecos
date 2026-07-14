// ChatListScreen — нативный список диалогов + поиск (юзеры/диалоги/сообщения).
//
// Поиск debounce 500мс. Префикс @ → приоритет юзерам по username, иначе
// диалоги первыми. Сообщения локальные (поиск по тексту в SQL LIKE).
// Тап на юзера/диалог → ChatScreen. Тап на сообщение → ChatScreen с highlightSid.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../services/chat_repo.dart';
import '../services/db_service.dart';
import '../services/search_service.dart';
import '../services/lan_chat_store.dart';
import '../services/bookmark_store.dart';
import '../core/local/local_hub.dart';
import '../widgets/glass.dart';
import '../widgets/emoji_text.dart';
import '../widgets/skeleton.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';
import 'lan_scan_screen.dart';
import 'lan_chat_screen.dart';
import 'bookmark_chat_screen.dart';

class ChatListScreen extends StatefulWidget {
  final bool isGuest;
  const ChatListScreen({super.key, this.isGuest = false});
  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  bool _initialized = false;
  SharedPreferences? _prefs;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;
  SearchOutcome? _searchResults;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Гость: НИКАКИХ обращений к серверным ChatRepo/поиску — только LAN.
    if (!widget.isGuest) await ChatRepo.instance.init();
    _prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _initialized = true);
  }

  // Перечитать черновики/список при возврате из чата (черновик мог измениться).
  void _refresh() {
    if (mounted) setState(() {});
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
      return const SkeletonDialogList();
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.shield_outlined, color: GE.primary, size: 22),
              const SizedBox(width: 8),
              Text(
                'Чаты',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              // Кнопка «Новый чат» убрана — поиск ниже сам открывает чат по
              // username (если совпадение точное, можно начать переписку).
              IconButton(
                icon: Icon(Icons.wifi_tethering_rounded, color: GE.sub),
                tooltip: 'Устройства поблизости',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LanScanScreen()),
                ),
              ),
              IconButton(
                icon: Icon(Icons.edit_outlined, color: GE.sub),
                tooltip: 'Новое',
                onPressed: () => _openCreateMenu(context),
              ),
            ],
          ),
        ),
        // Гость: поиска нет вообще — он всегда бьёт в серверный SearchService.
        if (widget.isGuest) const SizedBox(height: 4),
        if (!widget.isGuest)
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

  // LAN-чаты привязаны к УСТРОЙСТВУ (не к аккаунту, см. LanChatStore),
  // закладки — к аккаунту (см. BookmarkStore) — показываем всё вперемешку
  // с серверными диалогами, отсортированными по времени последнего сообщения
  // ("Избранное" всегда наверху — см. BookmarkStore._reloadDialogs).
  Widget _buildDialogs() {
    return ValueListenableBuilder<List<StoredDialog>>(
      valueListenable: ChatRepo.instance.dialogsNotifier,
      builder: (_, serverDialogs, _) {
        return ValueListenableBuilder<List<StoredDialog>>(
          valueListenable: LanChatStore.instance.dialogsNotifier,
          builder: (_, lanDialogs, _) {
            return ValueListenableBuilder<List<StoredDialog>>(
              valueListenable: BookmarkStore.instance.dialogsNotifier,
              builder: (_, bookmarkDialogs, _) {
                if (serverDialogs.isEmpty && lanDialogs.isEmpty && bookmarkDialogs.isEmpty) {
                  return _empty();
                }
                final defaultBm = bookmarkDialogs
                    .where((d) => d.username == '$bookmarkDialogPrefix$defaultBookmarkId')
                    .toList();
                final restBm = bookmarkDialogs
                    .where((d) => d.username != '$bookmarkDialogPrefix$defaultBookmarkId')
                    .toList();
                final rest = [...serverDialogs, ...lanDialogs, ...restBm]
                  ..sort((a, b) => _dialogTime(b).compareTo(_dialogTime(a)));
                final all = [...defaultBm, ...rest];
                return RefreshIndicator(
                  color: GE.primary,
                  onRefresh: widget.isGuest
                      ? () async {}
                      : ChatRepo.instance.fetchPending,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: all.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (_, i) {
                      final d = all[i];
                      if (d.username.startsWith(bookmarkDialogPrefix)) {
                        return _BookmarkDialogTile(d);
                      }
                      if (d.username.startsWith(lanDialogPrefix)) {
                        return _LanDialogTile(d);
                      }
                      return _DialogTile(d, prefs: _prefs, onReturn: _refresh);
                    },
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _openCreateMenu(BuildContext context) {
    showGlassSheet<void>(
      context,
      height: 200,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            _createMenuRow(
              icon: Icons.edit_note,
              label: 'Чат',
              enabled: !widget.isGuest,
              subtitle: widget.isGuest ? 'Недоступно гостю' : null,
              onTap: () {
                Navigator.pop(context);
                _newChatPrompt(context);
              },
            ),
            _createMenuRow(
              icon: Icons.bookmark_add_outlined,
              label: 'Закладка',
              enabled: true,
              onTap: () {
                Navigator.pop(context);
                _createBookmarkPrompt(context);
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _createMenuRow({
    required IconData icon,
    required String label,
    required bool enabled,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return PressScale(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: enabled ? GE.primary : GE.sub.withValues(alpha: 0.4)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: TextStyle(color: enabled ? GE.text : GE.sub.withValues(alpha: 0.4), fontSize: 15)),
                  if (subtitle != null)
                    Text(subtitle, style: TextStyle(color: GE.sub.withValues(alpha: 0.6), fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createBookmarkPrompt(BuildContext context) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Новая закладка', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Название',
            hintStyle: TextStyle(color: GE.sub),
          ),
          style: TextStyle(color: GE.text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final id = await BookmarkStore.instance.createBookmark(name);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BookmarkChatScreen(bookmarkId: id, name: name, isDefault: false),
      ),
    );
  }

  DateTime _dialogTime(StoredDialog d) {
    final at = d.lastAt;
    if (at == null) return DateTime.fromMillisecondsSinceEpoch(0);
    try {
      if (at is int) return DateTime.fromMillisecondsSinceEpoch(at * 1000);
      return DateTime.parse(at.toString());
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  Widget _buildSearchResults() {
    if (_searching && (_searchResults?.hits.isEmpty ?? true)) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator(color: GE.primary)),
      );
    }
    final outcome = _searchResults;
    final hits = outcome?.hits ?? const <SearchHit>[];
    if (hits.isEmpty) {
      // Различаем "сеть отвалилась" и "юзера правда нет" — раньше оба
      // случая молча схлопывались в одно и то же сообщение.
      final remoteFailed = outcome?.remoteFailed ?? false;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (remoteFailed) ...[
                Icon(Icons.cloud_off_outlined, color: GE.sub, size: 28),
                const SizedBox(height: 8),
              ],
              Text(
                remoteFailed ? 'Не удалось выполнить поиск — проверь соединение' : 'Ничего не найдено',
                textAlign: TextAlign.center,
                style: TextStyle(color: GE.sub, fontSize: 14),
              ),
            ],
          ),
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
          ...dialogsHits.map(
            (h) => _DialogTile(h.dialog!, onTap: _clearSearch),
          ),
        ],
        if (usersHits.isNotEmpty) ...[
          _sectionHeader('Пользователи'),
          ...usersHits.map((h) => _UserTile(h.user!, onTap: _clearSearch)),
        ],
        if (msgHits.isNotEmpty) ...[
          _sectionHeader('Сообщения'),
          ...msgHits.map(
            (h) => _MessageHitTile(
              h.message!,
              onTap: () {
                _clearSearch();
                _openMessage(h.message!);
              },
            ),
          ),
        ],
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: GE.sub,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  void _openMessage(StoredMessage m) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(peer: m.peer, displayName: m.peer, highlightSid: m.sid),
      ),
    );
  }

  Widget _empty() {
    // Гость: НИКАКОГО пути к серверному ChatScreen (даже без ввода юзернейма
    // руками) — только устройства поблизости через LanScanScreen.
    if (widget.isGuest) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: GlassCard(
            lite: true,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi_tethering_rounded, size: 48, color: GE.primary),
                const SizedBox(height: 14),
                Text(
                  'Пока нет чатов поблизости',
                  style: TextStyle(color: GE.text, fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  'Найдите устройство рядом по Wi-Fi/Bluetooth — гостю доступны только они',
                  style: TextStyle(color: GE.sub, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                GlassButton(
                  label: 'Найти устройства',
                  icon: Icons.wifi_tethering_rounded,
                  primary: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LanScanScreen()),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
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
              Text(
                'Пока нет чатов',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Введи @username сверху, чтобы найти',
                style: TextStyle(color: GE.sub, fontSize: 13),
                textAlign: TextAlign.center,
              ),
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
        backgroundColor: GE.bgDeep,
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
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(peer: username, displayName: username),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
class _DialogTile extends StatelessWidget {
  final StoredDialog d;
  final VoidCallback? onTap;
  final SharedPreferences? prefs;
  final VoidCallback? onReturn;
  const _DialogTile(this.d, {this.onTap, this.prefs, this.onReturn});

  // Превью последнего сообщения ИЛИ черновика (как в TG: «Черновик: …» красным).
  Widget _preview() {
    final draft = (prefs?.getString('chat_draft_${d.username}') ?? '').trim();
    if (draft.isNotEmpty) {
      return Text.rich(
        TextSpan(
          children: [
            const TextSpan(
              text: 'Черновик: ',
              style: TextStyle(
                color: Colors.red,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: draft,
              style: TextStyle(color: GE.text, fontSize: 13),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    return EmojiText(
      d.lastText.isEmpty ? '—' : d.lastText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: GE.sub, fontSize: 13),
    );
  }

  // Долгое нажатие на диалог → меню действий (как в TG).
  void _showMenu(BuildContext context) {
    final isGroup = d.username.startsWith('g:');
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: GE.bgDeep,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  _Avatar(d.displayName, size: 36),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      d.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: GE.glassBorder),
            _menuRow(Icons.done_all, 'Отметить прочитанным', GE.primary, () async {
              Navigator.pop(sheetCtx);
              await ChatRepo.instance.markChatRead(d.username);
              onReturn?.call();
            }),
            if (!isGroup)
              _menuRow(Icons.person_outline, 'Профиль', GE.primary, () {
                final nav = Navigator.of(context);
                Navigator.pop(sheetCtx);
                nav.push(MaterialPageRoute(
                  builder: (_) => ProfileScreen(username: d.username),
                ));
              }),
            _menuRow(Icons.delete_outline, 'Очистить историю', GE.red, () async {
              Navigator.pop(sheetCtx);
              final ok = await _confirmClear(context);
              if (ok) {
                await ChatRepo.instance.clearChat(d.username);
                onReturn?.call();
              }
            }),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _menuRow(
    IconData icon,
    String label,
    Color iconColor,
    VoidCallback onTap,
  ) {
    final danger = iconColor == GE.red;
    return PressScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color: danger ? GE.red : GE.text,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Очистить историю?', style: TextStyle(color: GE.text)),
        content: Text(
          'Сообщения чата с ${d.displayName} удалятся с этого устройства. '
          'Отменить нельзя.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text('Очистить', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onLongPress: () => _showMenu(context),
      onTap: () async {
        onTap?.call();
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                ChatScreen(peer: d.username, displayName: d.displayName),
          ),
        );
        onReturn?.call(); // черновик мог измениться — обновим список
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            GestureDetector(
              onTap: d.username.startsWith('g:')
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ProfileScreen(username: d.username),
                      ),
                    ),
              child: d.username.startsWith('g:')
                  ? _Avatar(d.displayName, size: 48)
                  : Stack(
                      children: [
                        _Avatar(d.displayName, size: 48),
                        Positioned(
                          right: -1,
                          bottom: -1,
                          child: ValueListenableBuilder<bool>(
                            valueListenable:
                                ChatRepo.instance.watchPresence(d.username),
                            // Кружок всегда виден (не только когда онлайн) —
                            // офлайн тускло-серый, иначе статус пропадал
                            // целиком и было непонятно, в сети человек или нет.
                            builder: (_, online, _) => Container(
                              width: 13,
                              height: 13,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: online ? GE.green : GE.sub.withValues(alpha: 0.35),
                                border: Border.all(color: GE.bg, width: 2),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          d.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        _formatDialogTime(d.lastAt),
                        style: TextStyle(color: GE.sub, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(child: _preview()),
                      if (d.unread > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: GE.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${d.unread > 99 ? "99+" : d.unread}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
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

}

String _formatDialogTime(dynamic at) {
  if (at == null) return '';
  DateTime dt;
  try {
    if (at is int) {
      dt = DateTime.fromMillisecondsSinceEpoch(at * 1000);
    } else {
      final p = DateTime.parse(at.toString());
      // created_at — наивная UTC-строка (без 'Z'); помечаем UTC, чтобы toLocal
      // ниже дал верное местное время (а не уехало на −3ч).
      dt = p.isUtc
          ? p
          : DateTime.utc(
              p.year,
              p.month,
              p.day,
              p.hour,
              p.minute,
              p.second,
              p.millisecond,
            );
    }
  } catch (_) {
    return '';
  }
  final now = DateTime.now();
  final local = dt.toLocal();
  if (now.year == local.year &&
      now.month == local.month &&
      now.day == local.day) {
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

// ─── LAN-диалог: привязан к устройству, не к аккаунту ────────────────────
class _LanDialogTile extends StatelessWidget {
  final StoredDialog d;
  const _LanDialogTile(this.d);

  String get _deviceId => d.username.substring(lanDialogPrefix.length);

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Очистить историю?', style: TextStyle(color: GE.text)),
        content: Text(
          'Переписка с ${d.displayName} по LAN удалится с этого устройства. '
          'Отменить нельзя.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text('Очистить', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (ok == true) await LanChatStore.instance.clearChat(_deviceId);
  }

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onLongPress: () => _confirmClear(context),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => LanChatScreen(deviceId: _deviceId, displayName: d.displayName),
      )),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Stack(
              children: [
                _Avatar(
                  d.displayName,
                  size: 48,
                  icon: Icons.wifi_tethering_rounded,
                  colors: [GE.green, GE.blue],
                ),
                // Бейдж типа — слева-снизу.
                Positioned(
                  left: -1,
                  bottom: -1,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(color: GE.bg, shape: BoxShape.circle),
                    child: Icon(Icons.wifi_tethering_rounded, size: 13, color: GE.primary),
                  ),
                ),
                // Статус "в сети" — справа-снизу, как у обычных чатов. Кружок
                // всегда виден (не только при онлайне), офлайн — тускло-серый.
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: StreamBuilder<MapEntry<String, bool>>(
                    stream: localHub.onOnlineChanged,
                    builder: (_, _) {
                      final online = localHub.isOnline(_deviceId);
                      return Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: online ? GE.green : GE.sub.withValues(alpha: 0.35),
                          border: Border.all(color: GE.bg, width: 2),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Статус "в сети" теперь на аватарке (справа-снизу),
                      // как у обычных чатов — здесь отдельного дота не нужно.
                      Expanded(
                        child: Text(
                          d.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: GE.text, fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(_formatDialogTime(d.lastAt), style: TextStyle(color: GE.sub, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: EmojiText(
                          d.lastText.isEmpty ? 'Устройство поблизости' : d.lastText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: GE.sub, fontSize: 13),
                        ),
                      ),
                      if (d.unread > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(color: GE.primary, borderRadius: BorderRadius.circular(10)),
                          child: Text('${d.unread > 99 ? "99+" : d.unread}',
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
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
}

// ─── Закладка: локальная запись, привязана к аккаунту (или гость) ────────
class _BookmarkDialogTile extends StatelessWidget {
  final StoredDialog d;
  const _BookmarkDialogTile(this.d);

  String get _id => d.username.substring(bookmarkDialogPrefix.length);
  bool get _isDefault => _id == defaultBookmarkId;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BookmarkChatScreen(bookmarkId: _id, name: d.displayName, isDefault: _isDefault),
      )),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Stack(
              children: [
                _Avatar(
                  d.displayName,
                  size: 48,
                  icon: _isDefault ? Icons.star_rounded : Icons.bookmark_rounded,
                  colors: _isDefault
                      ? [GE.yellow, GE.primary2]
                      : [GE.primary2, GE.primary],
                ),
                Positioned(
                  left: -1,
                  bottom: -1,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(color: GE.bg, shape: BoxShape.circle),
                    child: Icon(
                      _isDefault ? Icons.star_rounded : Icons.bookmark_rounded,
                      size: 13,
                      color: GE.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          d.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: GE.text, fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(_formatDialogTime(d.lastAt), style: TextStyle(color: GE.sub, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  EmojiText(
                    d.lastText.isEmpty ? 'Личные заметки' : d.lastText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.sub, fontSize: 13),
                  ),
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
class _UserTile extends StatelessWidget {
  final FoundUser u;
  final VoidCallback? onTap;
  const _UserTile(this.u, {this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: () {
        onTap?.call();
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                ChatScreen(peer: u.username, displayName: u.displayName),
          ),
        );
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
                  Text(
                    u.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '@${u.username}${u.isGuest ? " · гость" : ""}',
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
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
    return PressScale(
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          m.peer,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (m.fromMe)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            'вы',
                            style: TextStyle(color: GE.sub, fontSize: 10),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    m.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.sub, fontSize: 13),
                  ),
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
  // Особые типы чатов (Избранное/Закладка/LAN) получают свою иконку и
  // градиент вместо инициала — отличимы от обычного контакта с первого
  // взгляда, а не только по мелкому бейджику в углу.
  final IconData? icon;
  final List<Color>? colors;
  const _Avatar(this.name, {this.size = 44, this.icon, this.colors});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: colors ?? [GE.primary2, GE.primary]),
      ),
      alignment: Alignment.center,
      child: icon != null
          ? Icon(icon, color: Colors.white, size: size * 0.46)
          : Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: size * 0.4,
              ),
            ),
    );
  }
}
