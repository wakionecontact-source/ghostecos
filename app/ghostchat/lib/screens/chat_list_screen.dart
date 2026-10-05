// ChatListScreen — нативный список диалогов + поиск (юзеры/диалоги/сообщения).
//
// Поиск debounce 500мс. Префикс @ → приоритет юзерам по username, иначе
// диалоги первыми. Сообщения локальные (поиск по тексту в SQL LIKE).
// Тап на юзера/диалог → ChatScreen. Тап на сообщение → ChatScreen с highlightSid.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../services/api_client.dart';
import '../services/chat_repo.dart';
import '../services/db_service.dart';
import '../services/message_receipt_status.dart';
import '../services/room_service.dart';
import '../services/profile_cache.dart';
import '../services/search_service.dart';
import '../services/lan_chat_store.dart';
import '../services/bookmark_store.dart';
import '../services/dialog_settings_store.dart';
import '../services/chat_organization_store.dart';
import '../services/app_security_store.dart';
import '../services/auth_service.dart';
import '../services/contact_service.dart';
import '../services/notification_settings.dart';
import '../services/theme_service.dart';
import '../services/chat_header_settings.dart';
import '../core/local/local_hub.dart';
import '../widgets/glass.dart';
import '../widgets/bot_badge.dart';
import '../widgets/room_dialog_status.dart';
import '../widgets/emoji_text.dart';
import '../widgets/skeleton.dart';
import '../widgets/avatar.dart';
import '../core/local/app_logger.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';
import 'lan_scan_screen.dart';
import 'lan_chat_screen.dart';
import 'bookmark_chat_screen.dart';
import 'support_screen.dart';
import 'rooms_screen.dart';
import 'room_link_preview_screen.dart';
import 'storage_screen.dart';

class ChatListScreen extends StatefulWidget {
  final bool isGuest;
  final String? username;
  final String? displayName;
  const ChatListScreen({
    super.key,
    this.isGuest = false,
    this.username,
    this.displayName,
  });
  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _UnifiedChatEntry {
  final StoredDialog? dialog;
  final RoomSummary? room;

  const _UnifiedChatEntry.dialog(this.dialog) : room = null;
  const _UnifiedChatEntry.room(this.room) : dialog = null;

  String get key => dialog?.username ?? roomDialogKey(room!);
  DateTime get lastAt => dialog != null
      ? dialogTimestamp(dialog!.lastAt)
      : DateTime.fromMillisecondsSinceEpoch((room!.updatedAt ?? 0) * 1000);
}

class _ChatListScreenState extends State<ChatListScreen> {
  // static — переживает пересоздание виджета при каждом возврате на вкладку
  // Чатов, второй раз в рамках сессии SharedPreferences грузить не надо.
  static SharedPreferences? _cachedPrefs;

  // Синхронная инициализация из уже готового ChatRepo/prefs (см.
  // ChatRepo.isInitialized) — если это не первый визит на вкладку в сессии,
  // на самом первом build() уже есть всё нужное, без кадра skeleton.
  late bool _initialized = widget.isGuest || ChatRepo.instance.isInitialized;
  SharedPreferences? _prefs = _cachedPrefs;
  final _api = ApiClient();
  final Map<String, Map<String, dynamic>> _chatProfiles = {};
  Future<void>? _profileWarmInFlight;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;
  Timer? _botStatusTimer;
  SearchOutcome? _searchResults;
  RoomPreview? _roomLinkResult;
  RoomLinkTarget? _roomLinkTarget;
  String? _roomLinkError;
  int _searchGeneration = 0;
  bool _searching = false;
  final Set<String> _selectedChats = {};

  @override
  void initState() {
    super.initState();
    ChatHeaderSettings.instance.modeNotifier.addListener(
      _onChatHeaderTitleChanged,
    );
    ThemeService.instance.detailedDescriptionsNotifier.addListener(
      _onDescriptionsChanged,
    );
    AppSecurityStore.instance.revision.addListener(_onSecurityChanged);
    unawaited(ChatHeaderSettings.instance.load());
    _init();
  }

  void _onChatHeaderTitleChanged() {
    if (mounted) setState(() {});
  }

  void _onDescriptionsChanged() {
    if (mounted) setState(() {});
  }

  void _onSecurityChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    // Гость: НИКАКИХ обращений к серверным ChatRepo/поиску — только LAN.
    if (!widget.isGuest) await ChatRepo.instance.init();
    if (!widget.isGuest) unawaited(RoomService.instance.startSessionSync());
    _prefs ??= _cachedPrefs ??= await SharedPreferences.getInstance();
    await DialogSettingsStore.instance.load();
    await ChatOrganizationStore.instance.load(
      account: widget.username ?? await AuthService.username(),
    );
    await _expireArchivedChats();
    if (mounted) setState(() => _initialized = true);
    unawaited(_warmBotBadges());
    unawaited(_warmChatProfiles());
    _botStatusTimer ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_refreshCachedBotStatuses()),
    );
  }

  Future<void> _expireArchivedChats() async {
    final store = ChatOrganizationStore.instance;
    final expired = await store.expireArchived();
    if (expired.isEmpty) return;
    for (final chatId in expired) {
      try {
        if (chatId.startsWith(roomDialogPrefix)) {
          // Room history is server-owned and must not be erased by a local
          // archive policy. The organization entry is still removed.
          continue;
        }
        if (chatId.startsWith(lanDialogPrefix)) {
          await LanChatStore.instance.clearChat(
            chatId.substring(lanDialogPrefix.length),
          );
        } else if (chatId.startsWith(bookmarkDialogPrefix)) {
          await BookmarkStore.instance.clearBookmark(
            chatId.substring(bookmarkDialogPrefix.length),
          );
        } else {
          await ChatRepo.instance.clearChat(chatId);
          if (store.archiveDeleteMode == 'contact') {
            await ContactService.instance.remove(chatId);
          }
        }
      } catch (error) {
        appLog.warn(
          'chat_list',
          'Не удалось очистить просроченный архивный чат $chatId: $error',
        );
      }
    }
  }

  Map<String, dynamic>? _profileForDialog(String username) =>
      _chatProfiles[username] ?? ProfileCache.instance.getProfileSync(username);

  /// Профили собеседников из списка чатов — stale-while-revalidate:
  /// сначала берём сохранённый JSON с диска, затем в фоне обновляем устаревший
  /// профиль через /prof/{username}. Так холодный старт не ждёт сеть и не
  /// теряет имя/аватар после перезапуска приложения.
  Future<void> _warmChatProfiles() {
    if (widget.isGuest) return Future.value();
    final running = _profileWarmInFlight;
    if (running != null) return running;
    late final Future<void> tracked;
    tracked = _warmChatProfilesOnce().whenComplete(() {
      if (identical(_profileWarmInFlight, tracked)) {
        _profileWarmInFlight = null;
      }
    });
    _profileWarmInFlight = tracked;
    return tracked;
  }

  Future<void> _warmChatProfilesOnce() async {
    final peers = ChatRepo.instance.dialogsNotifier.value
        .map((d) => d.username)
        .where(
          (u) =>
              !u.startsWith('g:') &&
              !u.startsWith(roomDialogPrefix) &&
              !u.startsWith(lanDialogPrefix) &&
              !u.startsWith(bookmarkDialogPrefix),
        )
        .toSet()
        .toList();
    final stalePeers = (await Future.wait(
      peers.map((peer) async {
        try {
          final cached = await ProfileCache.instance.getProfile(peer);
          if (cached != null) _chatProfiles[peer] = cached;
          if (cached != null &&
              await ProfileCache.instance.isProfileFresh(peer)) {
            return null;
          }
          return peer;
        } catch (e) {
          appLog.warn(
            'chat_list',
            'Не удалось прочитать кэш профиля @$peer: $e',
          );
          return peer;
        }
      }),
    )).whereType<String>().toList();
    if (mounted) setState(() {});

    await Future.wait(stalePeers.map(_refreshChatProfile));
    if (mounted) setState(() {});
  }

  Future<void> _refreshChatProfile(String peer) async {
    try {
      final raw = await _api.socGet('/prof/${Uri.encodeComponent(peer)}');
      if (raw is Map) {
        final profile = Map<String, dynamic>.from(raw);
        await ProfileCache.instance.setProfile(peer, profile);
        _chatProfiles[peer] = profile;
      }
    } catch (e) {
      appLog.warn('chat_list', 'Не удалось обновить профиль @$peer: $e');
    }
  }

  /// Прогреваем кэш "это бот?" И аватарки для всех диалогов сразу (оба поля
  /// приходят в одном /keys/{username} — см. ChatRepo._loadPeerKeys) —
  /// иначе бейдж/аватарка в списке чатов появлялись только ПОСЛЕ первого
  /// send/receive с этим пиром.
  Future<void> _warmBotBadges() async {
    if (widget.isGuest) return;
    final peers = ChatRepo.instance.dialogsNotifier.value
        .map((d) => d.username)
        .where(
          (u) =>
              !u.startsWith('g:') &&
              !u.startsWith(roomDialogPrefix) &&
              !u.startsWith(lanDialogPrefix) &&
              !u.startsWith(bookmarkDialogPrefix),
        )
        .toList();
    // Параллельно, не по одному — иначе на списке из десятков диалогов
    // аватарки/бейджи "бота" прогревались бы последовательно (медленно,
    // ощущалось как "аватарка грузится только после захода в профиль",
    // хотя на самом деле просто ещё не дошла очередь).
    await Future.wait(
      peers.map((peer) async {
        try {
          await ChatRepo.instance.isPeerBot(peer);
        } catch (e) {
          appLog.warn('chat_list', 'Не удалось прогреть /keys/$peer: $e');
        }
      }),
    );
    if (mounted) setState(() {});
  }

  Future<void> _refreshCachedBotStatuses() async {
    if (widget.isGuest) return;
    final bots = ChatRepo.instance.dialogsNotifier.value
        .map((dialog) => dialog.username)
        .where(ChatRepo.instance.isPeerBotCached)
        .toSet();
    await Future.wait(bots.map(ChatRepo.instance.refreshPeerBotStatus));
  }

  // Перечитать черновики/список при возврате из чата (черновик мог измениться).
  void _refresh() {
    if (mounted) {
      setState(() {});
      unawaited(_warmChatProfiles());
      unawaited(_warmBotBadges());
    }
  }

  void _toggleChatSelection(String username) {
    setState(() {
      if (!_selectedChats.remove(username)) _selectedChats.add(username);
    });
  }

  void _clearChatSelection() {
    if (_selectedChats.isNotEmpty) setState(_selectedChats.clear);
  }

  Future<void> _markSelectedChatsRead() async {
    final selected = List<String>.from(_selectedChats);
    _clearChatSelection();
    for (final username in selected) {
      await _markDialogRead(username, read: true);
    }
  }

  Future<void> _markSelectedChatsUnread() async {
    final selected = List<String>.from(_selectedChats);
    _clearChatSelection();
    for (final username in selected) {
      await _markDialogRead(username, read: false);
    }
  }

  Future<void> _markDialogRead(String username, {required bool read}) async {
    if (username.startsWith(roomDialogPrefix)) return;
    if (username.startsWith(lanDialogPrefix)) {
      final id = username.substring(lanDialogPrefix.length);
      if (read) {
        await LanChatStore.instance.markRead(id);
      } else {
        await LanChatStore.instance.markUnread(id);
      }
    } else if (username.startsWith(bookmarkDialogPrefix)) {
      final id = username.substring(bookmarkDialogPrefix.length);
      if (read) {
        await BookmarkStore.instance.markRead(id);
      } else {
        await BookmarkStore.instance.markUnread(id);
      }
    } else if (read) {
      await ChatRepo.instance.markChatRead(username);
    } else {
      await ChatRepo.instance.markChatUnread(username);
    }
  }

  Future<void> _deleteSelectedChats() async {
    final selected = List<String>.from(_selectedChats);
    _clearChatSelection();
    for (final username in selected) {
      if (username.startsWith(roomDialogPrefix)) continue;
      if (username.startsWith(lanDialogPrefix)) {
        await LanChatStore.instance.clearChat(
          username.substring(lanDialogPrefix.length),
        );
      } else if (username.startsWith(bookmarkDialogPrefix)) {
        await BookmarkStore.instance.clearBookmark(
          username.substring(bookmarkDialogPrefix.length),
        );
      } else {
        await ChatRepo.instance.clearChat(username);
      }
    }
  }

  bool _allSelectedMuted() =>
      _selectedChats.isNotEmpty &&
      _selectedChats.every(NotificationSettings.instance.isMuted);

  bool _allSelectedPinned() =>
      _selectedChats.isNotEmpty &&
      _selectedChats.every(DialogSettingsStore.instance.isPinned);

  bool _allSelectedBlocked() =>
      _selectedChats.isNotEmpty &&
      _selectedChats.every(
        (id) =>
            id.startsWith(lanDialogPrefix) ||
                id.startsWith(bookmarkDialogPrefix)
            ? DialogSettingsStore.instance.isBlocked(id)
            : ChatRepo.instance.isPeerBlocked(id),
      );

  Future<void> _toggleSelectedMute() async {
    final mute = !_allSelectedMuted();
    final selected = List<String>.from(_selectedChats);
    _clearChatSelection();
    for (final username in selected) {
      await NotificationSettings.instance.setMuted(username, mute);
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleSelectedPin() async {
    final pin = !_allSelectedPinned();
    final selected = List<String>.from(_selectedChats);
    _clearChatSelection();
    for (final username in selected) {
      await DialogSettingsStore.instance.setPinned(username, pin);
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleSelectedBlocked() async {
    final block = !_allSelectedBlocked();
    final selected = List<String>.from(_selectedChats);
    _clearChatSelection();
    for (final username in selected) {
      if (username.startsWith(lanDialogPrefix) ||
          username.startsWith(bookmarkDialogPrefix)) {
        await DialogSettingsStore.instance.setBlocked(username, block);
      } else if (block) {
        await ChatRepo.instance.blockPeer(username);
      } else {
        await ChatRepo.instance.unblockPeer(username);
      }
    }
    if (mounted) setState(() {});
  }

  void _showSelectedMore(BuildContext context) {
    final blocked = _allSelectedBlocked();
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
            _selectionMenuRow(
              sheetCtx,
              CupertinoIcons.checkmark,
              'Пометить прочитанными',
              _markSelectedChatsRead,
            ),
            _selectionMenuRow(
              sheetCtx,
              CupertinoIcons.circle,
              'Пометить непрочитанными',
              _markSelectedChatsUnread,
            ),
            _selectionMenuRow(
              sheetCtx,
              blocked ? CupertinoIcons.lock_open : CupertinoIcons.lock,
              blocked ? 'Разблокировать' : 'Заблокировать',
              _toggleSelectedBlocked,
            ),
            _selectionMenuRow(
              sheetCtx,
              CupertinoIcons.tray_arrow_down,
              'Удалить кэш выбранных чатов',
              _openStorageForSelected,
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Future<void> _openStorageForSelected() async {
    final selected = {..._selectedChats};
    _clearChatSelection();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StorageScreen(initialChats: selected)),
    );
  }

  Widget _selectionMenuRow(
    BuildContext sheetCtx,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return PressScale(
      onTap: () {
        Navigator.pop(sheetCtx);
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: GE.primary),
            const SizedBox(width: 14),
            Text(label, style: TextStyle(color: GE.text, fontSize: 15)),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _botStatusTimer?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    ChatHeaderSettings.instance.modeNotifier.removeListener(
      _onChatHeaderTitleChanged,
    );
    ThemeService.instance.detailedDescriptionsNotifier.removeListener(
      _onDescriptionsChanged,
    );
    AppSecurityStore.instance.revision.removeListener(_onSecurityChanged);
    super.dispose();
  }

  void _onSearchChanged(String value) {
    final generation = ++_searchGeneration;
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _searchResults = null;
        _roomLinkResult = null;
        _roomLinkTarget = null;
        _roomLinkError = null;
        _searching = false;
      });
      return;
    }
    final linkTarget = RoomLinkTarget.parse(query);
    setState(() {
      _searchResults = linkTarget == null ? null : const SearchOutcome([]);
      _roomLinkResult = null;
      _roomLinkTarget = linkTarget;
      _roomLinkError = null;
      _searching = true;
    });
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      if (linkTarget != null) {
        await _searchRoomLink(query, linkTarget, generation);
        return;
      }
      final results = await SearchService.instance.search(query);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searchResults = results;
        _searching = false;
      });
    });
  }

  void _clearSearch() {
    _searchGeneration++;
    _searchCtrl.clear();
    _debounce?.cancel();
    setState(() {
      _searchResults = null;
      _roomLinkResult = null;
      _roomLinkTarget = null;
      _roomLinkError = null;
      _searching = false;
    });
    _searchFocus.unfocus();
  }

  Future<void> _searchRoomLink(
    String query,
    RoomLinkTarget target,
    int generation,
  ) async {
    try {
      final preview = target.isInvite
          ? await RoomService.instance.loadInvitePreview(target.token!)
          : await RoomService.instance.loadPublicPreview(target.username!);
      if (!mounted ||
          generation != _searchGeneration ||
          query != _searchCtrl.text.trim()) {
        return;
      }
      setState(() {
        _roomLinkResult = preview;
        _roomLinkError = null;
        _searching = false;
      });
    } catch (error) {
      appLog.warn('chat_list', 'Поиск комнаты по ссылке не удался: $error');
      if (!mounted ||
          generation != _searchGeneration ||
          query != _searchCtrl.text.trim()) {
        return;
      }
      setState(() {
        _roomLinkResult = null;
        _roomLinkError = 'Комната по этой ссылке не найдена';
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Плавный переход skeleton → контент вместо резкой подмены — раньше
    // список чатов "выскакивал" целиком в момент готовности данных.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: !_initialized
          ? const SkeletonDialogList(key: ValueKey('skeleton'))
          : KeyedSubtree(
              key: const ValueKey('content'),
              child: _content(context),
            ),
    );
  }

  Widget _content(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: _selectedChats.isNotEmpty
              ? Row(
                  children: [
                    IconButton(
                      icon: Icon(CupertinoIcons.xmark, color: GE.sub),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      onPressed: _clearChatSelection,
                    ),
                    Text(
                      'Выбрано: ${_selectedChats.length}',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: _allSelectedMuted()
                          ? 'Включить уведомления'
                          : 'Без звука',
                      icon: Icon(
                        _allSelectedMuted()
                            ? CupertinoIcons.bell
                            : CupertinoIcons.bell_slash,
                        color: GE.primary,
                      ),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      onPressed: _toggleSelectedMute,
                    ),
                    IconButton(
                      tooltip: _allSelectedPinned() ? 'Открепить' : 'Закрепить',
                      icon: Icon(
                        _allSelectedPinned()
                            ? CupertinoIcons.pin_fill
                            : CupertinoIcons.pin,
                        color: GE.primary,
                      ),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      onPressed: _toggleSelectedPin,
                    ),
                    IconButton(
                      tooltip: 'Ещё',
                      icon: Icon(CupertinoIcons.ellipsis, color: GE.primary),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      onPressed: () => _showSelectedMore(context),
                    ),
                    IconButton(
                      tooltip: 'Удалить',
                      icon: Icon(CupertinoIcons.trash, color: GE.red),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      onPressed: _deleteSelectedChats,
                    ),
                  ],
                )
              : Row(
                  children: [
                    Icon(
                      CupertinoIcons.chat_bubble_fill,
                      color: GE.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _chatHeaderTitle(),
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    // Кнопка «Новый чат» убрана — поиск ниже сам открывает чат по
                    // username (если совпадение точное, можно начать переписку).
                    GhostIconButton(
                      icon: CupertinoIcons.antenna_radiowaves_left_right,
                      color: GE.sub,
                      tooltip: 'Устройства поблизости',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const LanScanScreen(),
                        ),
                      ),
                    ),
                    // Поддержка — доступна прямо из списка чатов (раньше была спрятана
                    // в настройках), там где юзер и ждёт «связаться с поддержкой».
                    GhostIconButton(
                      icon: Icons.support_agent,
                      color: GE.sub,
                      tooltip: 'Поддержка',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SupportScreen(),
                        ),
                      ),
                    ),
                    GhostIconButton(
                      icon: CupertinoIcons.pencil,
                      color: GE.sub,
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
              hint: 'Поиск пользователей, чатов и сообщений',
              icon: CupertinoIcons.search,
              onChanged: _onSearchChanged,
              suffix: _searchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(CupertinoIcons.xmark, color: GE.sub, size: 18),
                      onPressed: _clearSearch,
                    )
                  : null,
            ),
          ),
        if (!widget.isGuest) _buildFolderStrip(),
        Expanded(
          child: _searchResults != null
              ? _buildSearchResults()
              : _buildDialogs(),
        ),
      ],
    );
  }

  String _chatHeaderTitle() {
    switch (ChatHeaderSettings.instance.modeNotifier.value) {
      case ChatHeaderTitleMode.displayName:
        final name = widget.displayName?.trim();
        return name == null || name.isEmpty ? 'Чаты' : name;
      case ChatHeaderTitleMode.username:
        final username = widget.username?.trim();
        if (username == null || username.isEmpty) return 'Чаты';
        if (widget.isGuest) return username;
        return username.startsWith('@') ? username : '@$username';
      case ChatHeaderTitleMode.chats:
        return 'Чаты';
      case ChatHeaderTitleMode.ghostChat:
        return 'GhostChat';
    }
  }

  Future<void> _createChatFolder() async {
    final controller = TextEditingController();
    try {
      var secure = false;
      String? scenarioId = AppSecurityStore.instance.activeScenarioId;
      final result = await showDialog<({String name, String? scenarioId})>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: GE.bgDeep,
            title: const Text('Новая группа чатов'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: 'Название',
                      hintText: 'Например, Работа',
                    ),
                  ),
                  if (AppSecurityStore.instance.hasPrimaryCode &&
                      AppSecurityStore.instance.scenarios.isNotEmpty)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: secure,
                      title: const Text('Р‘РµР·РѕРїР°СЃРЅР°СЏ РіСЂСѓРїРїР°'),
                      subtitle: const Text(
                        'РќРµ РїРѕРєР°Р·С‹РІР°С‚СЊ РІ РѕР±С‹С‡РЅРѕРј РґРµР¶РёРјРµ',
                      ),
                      onChanged: (value) => setDialogState(() {
                        secure = value == true;
                        if (!secure) scenarioId = null;
                        if (secure && scenarioId == null) {
                          scenarioId =
                              AppSecurityStore.instance.scenarios.first.id;
                        }
                      }),
                    ),
                  if (secure)
                    DropdownButtonFormField<String>(
                    initialValue: scenarioId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Безопасная среда',
                      ),
                      items: [
                        for (final scenario
                            in AppSecurityStore.instance.scenarios)
                          DropdownMenuItem(
                            value: scenario.id,
                            child: Text(scenario.name),
                          ),
                      ],
                      onChanged: (value) =>
                          setDialogState(() => scenarioId = value),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, (
                  name: controller.text,
                  scenarioId: secure ? scenarioId : null,
                )),
                child: const Text('Создать'),
              ),
            ],
          ),
        ),
      );
      if (result == null || result.name.trim().isEmpty) return;
      final parent = ChatOrganizationStore.instance.activeFolder.value;
      await ChatOrganizationStore.instance.createFolder(
        result.name,
        parentId: parent == 'main' || parent == 'archive' ? null : parent,
        securityScenarioId: result.scenarioId,
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _openFolderMenu(ChatOrganizationFolder folder) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: GE.bgDeep,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(CupertinoIcons.pencil, color: GE.primary),
              title: const Text('Переименовать группу'),
              onTap: () => Navigator.pop(sheetContext, 'rename'),
            ),
            ListTile(
              leading: Icon(CupertinoIcons.clock, color: GE.primary),
              title: const Text('История изменений'),
              onTap: () => Navigator.pop(sheetContext, 'history'),
            ),
            ListTile(
              leading: Icon(CupertinoIcons.wand_stars, color: GE.primary),
              title: const Text('Template'),
              onTap: () => Navigator.pop(sheetContext, 'template'),
            ),
            ListTile(
              leading: Icon(CupertinoIcons.trash, color: GE.red),
              title: const Text('Удалить группу'),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'rename') {
      final controller = TextEditingController(text: folder.name);
      try {
        final name = await showDialog<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: GE.bgDeep,
            title: const Text('Переименовать группу'),
            content: TextField(controller: controller, maxLength: 40),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text),
                child: const Text('Сохранить'),
              ),
            ],
          ),
        );
        if (name != null) {
          await ChatOrganizationStore.instance.renameFolder(folder.id, name);
        }
      } finally {
        controller.dispose();
      }
      return;
    }
    if (action == 'template') {
      final current = ChatOrganizationStore.instance.templateFor(folder.id);
      final selected = {...?current?.types};
      var mode = current?.mode ?? 'selected';
      final result = await showDialog<({String mode, Set<String> types})>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            const labels = <String, String>{
              'dm': 'Direct messages',
              'group': 'Groups',
              'channel': 'Channels',
              'bot': 'Bots',
              'bookmark': 'Bookmarks',
              'lan': 'LAN',
            };
            return AlertDialog(
              backgroundColor: GE.bgDeep,
              title: const Text('Folder template'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButton<String>(
                      value: mode,
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(
                          value: 'selected',
                          child: Text('Only selected types'),
                        ),
                        DropdownMenuItem(
                          value: 'all_except',
                          child: Text('All except selected'),
                        ),
                      ],
                      onChanged: (value) =>
                          setDialogState(() => mode = value ?? mode),
                    ),
                    for (final entry in labels.entries)
                      CheckboxListTile(
                        dense: true,
                        value: selected.contains(entry.key),
                        title: Text(entry.value),
                        onChanged: (value) => setDialogState(() {
                          if (value == true) {
                            selected.add(entry.key);
                          } else {
                            selected.remove(entry.key);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, (
                    mode: mode,
                    types: {...selected},
                  )),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        ),
      );
      if (result != null) {
        await ChatOrganizationStore.instance.setTemplate(
          folder.id,
          mode: result.mode,
          types: result.types,
        );
      }
      return;
    }
    if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: GE.bgDeep,
          title: const Text('Удалить группу?'),
          content: const Text(
            'Чаты останутся в общем списке и в других группах.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Удалить'),
            ),
          ],
        ),
      );
      if (ok == true) {
        await ChatOrganizationStore.instance.deleteFolder(folder.id);
      }
      return;
    }
    final history = ChatOrganizationStore.instance.historyFor(folder.id);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: GE.bgDeep,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'История: ${folder.name}',
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(CupertinoIcons.xmark),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: history.isEmpty
                    ? Center(
                        child: Text(
                          'История пока пуста',
                          style: TextStyle(color: GE.sub),
                        ),
                      )
                    : ListView.builder(
                        itemCount: history.length,
                        itemBuilder: (_, index) {
                          final item = history[index];
                          final date = DateTime.fromMillisecondsSinceEpoch(
                            item.at * 1000,
                          ).toLocal();
                          final when =
                              '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
                          return ListTile(
                            leading: Icon(
                              CupertinoIcons.arrow_right,
                              color: GE.primary,
                            ),
                            title: Text(
                              item.chatId,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('${item.action} · $when'),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFolderStrip() {
    return ValueListenableBuilder<int>(
      valueListenable: ChatOrganizationStore.instance.revision,
      builder: (context, _, _) {
        final store = ChatOrganizationStore.instance;
        final active = store.activeFolder.value;
        final folders = <({String id, String label, IconData icon})>[
          (id: 'main', label: 'Все', icon: CupertinoIcons.chat_bubble_2),
          (id: 'archive', label: 'Архив', icon: CupertinoIcons.archivebox),
          for (final folder in store.visibleFolders)
            (id: folder.id, label: folder.name, icon: CupertinoIcons.folder),
        ];
        return SizedBox(
          height: 42,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            scrollDirection: Axis.horizontal,
            itemCount: folders.length + 1,
            separatorBuilder: (_, _) => const SizedBox(width: 7),
            itemBuilder: (context, index) {
              if (index == folders.length) {
                return IconButton(
                  tooltip: 'Новая группа чатов',
                  onPressed: _createChatFolder,
                  icon: Icon(CupertinoIcons.plus, color: GE.primary),
                );
              }
              final item = folders[index];
              final selected = active == item.id;
              final chip = ChoiceChip(
                selected: selected,
                onSelected: (_) => store.select(item.id),
                avatar: Icon(item.icon, size: 15),
                label: Text(item.label),
                labelStyle: TextStyle(
                  color: selected ? Colors.white : GE.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                selectedColor: GE.primary,
                backgroundColor: GE.surface.withValues(alpha: 0.55),
                side: BorderSide(color: GE.border.withValues(alpha: 0.7)),
                showCheckmark: false,
              );
              if (item.id == 'main' || item.id == 'archive') return chip;
              final folder = store.folders.firstWhere(
                (value) => value.id == item.id,
              );
              return GestureDetector(
                onLongPress: () => _openFolderMenu(folder),
                child: chip,
              );
            },
          ),
        );
      },
    );
  }

  // LAN-чаты привязаны к УСТРОЙСТВУ (не к аккаунту, см. LanChatStore),
  // закладки — к аккаунту (см. BookmarkStore) — показываем всё вперемешку
  // с серверными диалогами, отсортированными по времени последнего сообщения
  // ("Избранное" всегда наверху — см. BookmarkStore._reloadDialogs).
  Widget _buildDialogs() {
    return ValueListenableBuilder<int>(
      valueListenable: ChatOrganizationStore.instance.revision,
      builder: (_, _, _) => ValueListenableBuilder<int>(
        valueListenable: RoomService.instance.activityRevision,
        builder: (_, _, _) => ValueListenableBuilder<List<RoomSummary>>(
          valueListenable: RoomService.instance.rooms,
          builder: (_, rooms, _) => _buildDialogsFromSources(rooms),
        ),
      ),
    );
  }

  Widget _buildDialogsFromSources(List<RoomSummary> rooms) {
    return ValueListenableBuilder<List<StoredDialog>>(
      valueListenable: ChatRepo.instance.dialogsNotifier,
      builder: (_, serverDialogs, _) {
        return ValueListenableBuilder<List<StoredDialog>>(
          valueListenable: LanChatStore.instance.dialogsNotifier,
          builder: (_, lanDialogs, _) {
            return ValueListenableBuilder<List<StoredDialog>>(
              valueListenable: BookmarkStore.instance.dialogsNotifier,
              builder: (_, bookmarkDialogs, _) {
                if (serverDialogs.isEmpty &&
                    lanDialogs.isEmpty &&
                    bookmarkDialogs.isEmpty &&
                    rooms.isEmpty) {
                  return _empty();
                }
                final defaultBm = bookmarkDialogs
                    .where(
                      (d) =>
                          d.username ==
                          '$bookmarkDialogPrefix$defaultBookmarkId',
                    )
                    .toList();
                final restBm = bookmarkDialogs
                    .where(
                      (d) =>
                          d.username !=
                          '$bookmarkDialogPrefix$defaultBookmarkId',
                    )
                    .toList();
                final sourceEntries = <_UnifiedChatEntry>[
                  ...serverDialogs.map(_UnifiedChatEntry.dialog),
                  ...lanDialogs.map(_UnifiedChatEntry.dialog),
                  ...defaultBm.map(_UnifiedChatEntry.dialog),
                  ...restBm.map(_UnifiedChatEntry.dialog),
                  ...rooms.map(_UnifiedChatEntry.room),
                ];
                final organization = ChatOrganizationStore.instance;
                if (organization.archiveAnchor == 'activity') {
                  for (final entry in sourceEntries) {
                    if (!organization.isArchived(entry.key)) continue;
                    unawaited(
                      organization.noteActivity(
                        entry.key,
                        entry.lastAt.millisecondsSinceEpoch ~/ 1000,
                      ),
                    );
                  }
                }
                final activeFolder = organization.activeFolder.value;
                final visibleEntries = sourceEntries.where((entry) {
                  final archived = organization.isArchived(entry.key);
                  if (activeFolder == 'archive') return archived;
                  if (archived) return false;
                  if (activeFolder == 'main') {
                    return !organization.isMainHidden(entry.key);
                  }
                  final isBot =
                      entry.dialog != null &&
                      ChatRepo.instance.isPeerBotCached(entry.dialog!.username);
                  return organization.contains(activeFolder, entry.key) ||
                      organization.matchesTemplate(
                        activeFolder,
                        entry.key,
                        isBot: isBot,
                      );
                }).toList();
                final rest = visibleEntries
                  ..sort((a, b) {
                    final pin =
                        (DialogSettingsStore.instance.isPinned(b.key) ? 1 : 0)
                            .compareTo(
                              DialogSettingsStore.instance.isPinned(a.key)
                                  ? 1
                                  : 0,
                            );
                    if (pin != 0) return pin;
                    final aLast = a.room == null
                        ? a.lastAt
                        : RoomService.instance.lastActivityFor(a.room!);
                    final bLast = b.room == null
                        ? b.lastAt
                        : RoomService.instance.lastActivityFor(b.room!);
                    return bLast.compareTo(aLast);
                  });
                final all = <_UnifiedChatEntry>[
                  ...defaultBm.map(_UnifiedChatEntry.dialog),
                  ...rest,
                ];
                final folderRows = activeFolder == 'archive'
                    ? const <ChatOrganizationFolder>[]
                    : organization.visibleFolders
                          .where(
                            (folder) =>
                                folder.parentId ==
                                (activeFolder == 'main' ? null : activeFolder),
                          )
                          .toList(growable: false);
                int folderUnread(ChatOrganizationFolder folder) {
                  var total = 0;
                  for (final entry in sourceEntries) {
                    if (organization.isArchived(entry.key)) continue;
                    final isBot =
                        entry.dialog != null &&
                        ChatRepo.instance.isPeerBotCached(
                          entry.dialog!.username,
                        );
                    if (!organization.contains(folder.id, entry.key) &&
                        !organization.matchesTemplate(
                          folder.id,
                          entry.key,
                          isBot: isBot,
                        )) {
                      continue;
                    }
                    total += entry.dialog?.unread ?? 0;
                  }
                  return total;
                }

                return RefreshIndicator(
                  color: GE.primary,
                  onRefresh: widget.isGuest
                      ? () async {}
                      : ChatRepo.instance.fetchPending,
                  child: ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      8,
                      4,
                      8,
                      120 + MediaQuery.of(context).padding.bottom,
                    ),
                    itemCount: folderRows.length + all.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (_, i) {
                      if (i < folderRows.length) {
                        final folder = folderRows[i];
                        return _ChatFolderTile(
                          folder: folder,
                          unread: folderUnread(folder),
                          onTap: () => organization.select(folder.id),
                          onLongPress: () => _openFolderMenu(folder),
                        );
                      }
                      final entry = all[i - folderRows.length];
                      final room = entry.room;
                      if (room != null) {
                        final key = roomDialogKey(room);
                        return _RoomDialogTile(
                          room,
                          selected: _selectedChats.contains(key),
                          selectionMode: _selectedChats.isNotEmpty,
                          onSelect: () => _toggleChatSelection(key),
                          onReturn: _refresh,
                        );
                      }
                      final d = entry.dialog!;
                      if (d.username.startsWith(bookmarkDialogPrefix)) {
                        return _BookmarkDialogTile(
                          d,
                          selected: _selectedChats.contains(d.username),
                          selectionMode: _selectedChats.isNotEmpty,
                          onSelect: () => _toggleChatSelection(d.username),
                          onReturn: _refresh,
                        );
                      }
                      if (d.username.startsWith(lanDialogPrefix)) {
                        return _LanDialogTile(
                          d,
                          selected: _selectedChats.contains(d.username),
                          selectionMode: _selectedChats.isNotEmpty,
                          onSelect: () => _toggleChatSelection(d.username),
                          onReturn: _refresh,
                        );
                      }
                      return _DialogTile(
                        d,
                        profile: _profileForDialog(d.username),
                        prefs: _prefs,
                        selected: _selectedChats.contains(d.username),
                        selectionMode: _selectedChats.isNotEmpty,
                        onSelect: () => _toggleChatSelection(d.username),
                        onReturn: _refresh,
                      );
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

  void _openCreateMenu(BuildContext context) =>
      showNewChatMenu(context, isGuest: widget.isGuest);

  Widget _buildSearchResults() {
    if (_searching && (_searchResults?.hits.isEmpty ?? true)) {
      // Скелетон вместо спиннера — тот же паттерн, что и у основного списка
      // чатов, вместо голого "крутилка по центру".
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: SkeletonRowList(count: 4, avatarSize: 44),
      );
    }
    final linkTarget = _roomLinkTarget;
    if (linkTarget != null) {
      final preview = _roomLinkResult;
      if (preview != null) {
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          children: [
            _sectionHeader(linkTarget.isInvite ? 'Приглашение' : 'Комната'),
            _RoomLinkSearchTile(
              preview: preview,
              onTap: () {
                _clearSearch();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RoomLinkPreviewScreen(target: linkTarget),
                  ),
                );
              },
            ),
          ],
        );
      }
      if (_roomLinkError != null) {
        return _searchEmptyMessage(_roomLinkError!);
      }
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
                remoteFailed
                    ? 'Не удалось выполнить поиск — проверь соединение'
                    : 'Ничего не найдено',
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

  Widget _searchEmptyMessage(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: GE.sub, fontSize: 14),
        ),
      ),
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
        builder: (_) => ChatScreen(
          peer: m.peer,
          displayName: m.peer,
          isBot: ChatRepo.instance.isPeerBotCached(m.peer),
          highlightSid: m.sid,
        ),
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
                Icon(
                  CupertinoIcons.antenna_radiowaves_left_right,
                  size: 48,
                  color: GE.primary,
                ),
                const SizedBox(height: 14),
                Text(
                  'Пока нет чатов поблизости',
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
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
                  icon: CupertinoIcons.antenna_radiowaves_left_right,
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
              Icon(CupertinoIcons.chat_bubble, size: 48, color: GE.primary),
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
              if (ThemeService.instance.showDetailedDescriptions) ...[
                Text(
                  'Введи @username сверху, чтобы найти',
                  style: TextStyle(color: GE.sub, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
              GlassButton(
                label: 'Новый чат',
                icon: CupertinoIcons.square_pencil,
                primary: true,
                onTap: () => newChatPrompt(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Меню "новый чат" — top-level, чтобы вызывать не только с карандаша в
// шапке списка, но и с плавающей кнопки нижнего бара (main_shell.dart). ────
void showNewChatMenu(BuildContext context, {required bool isGuest}) {
  showGlassSheet<void>(
    context,
    height: 260,
    child: SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          _createMenuRow(
            icon: CupertinoIcons.square_pencil,
            label: 'Чат',
            enabled: !isGuest,
            subtitle: isGuest ? 'Недоступно гостю' : null,
            onTap: () {
              Navigator.pop(context);
              newChatPrompt(context);
            },
          ),
          _createMenuRow(
            icon: CupertinoIcons.bookmark,
            label: 'Закладка',
            enabled: true,
            onTap: () {
              Navigator.pop(context);
              _createBookmarkPrompt(context);
            },
          ),
          _createMenuRow(
            icon: CupertinoIcons.antenna_radiowaves_left_right,
            label: 'Создать канал или группу',
            enabled: !isGuest,
            subtitle: isGuest ? 'Недоступно гостю' : null,
            onTap: () {
              Navigator.pop(context);
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const RoomsScreen()));
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
          Icon(
            icon,
            size: 20,
            color: enabled ? GE.primary : GE.sub.withValues(alpha: 0.4),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: enabled ? GE.text : GE.sub.withValues(alpha: 0.4),
                    fontSize: 15,
                  ),
                ),
                if (subtitle != null &&
                    ThemeService.instance.showDetailedDescriptions)
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: GE.sub.withValues(alpha: 0.6),
                      fontSize: 12,
                    ),
                  ),
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
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('Создать'),
        ),
      ],
    ),
  );
  if (name == null || name.isEmpty) return;
  final id = await BookmarkStore.instance.createBookmark(name);
  if (!context.mounted) return;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          BookmarkChatScreen(bookmarkId: id, name: name, isDefault: false),
    ),
  );
}

/// Диалог "@username" → открыть/начать чат. Top-level — переиспользуется
/// пустым состоянием списка чатов И плавающей кнопкой нижнего бара.
Future<void> newChatPrompt(BuildContext context) async {
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
  if (username == null || !context.mounted) return;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ChatScreen(peer: username, displayName: username),
    ),
  );
}

// ────────────────────────────────────────────────────────────────────────
class _ChatFolderTile extends StatelessWidget {
  final ChatOrganizationFolder folder;
  final int unread;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ChatFolderTile({
    required this.folder,
    required this.unread,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onLongPress,
      child: GlassCard(
        lite: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: GE.primary.withValues(alpha: 0.16),
              ),
              child: Icon(CupertinoIcons.folder_fill, color: GE.primary),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GE.text,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    unread > 0
                        ? '$unread непрочитанных'
                        : 'Группа чатов · открыть список',
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (unread > 0)
              Container(
                constraints: const BoxConstraints(minWidth: 24),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: GE.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            const SizedBox(width: 5),
            Icon(CupertinoIcons.chevron_right, color: GE.sub, size: 16),
          ],
        ),
      ),
    );
  }
}

class _RoomDialogTile extends StatelessWidget {
  final RoomSummary room;
  final bool selected;
  final bool selectionMode;
  final VoidCallback? onSelect;
  final VoidCallback? onReturn;

  const _RoomDialogTile(
    this.room, {
    this.selected = false,
    this.selectionMode = false,
    this.onSelect,
    this.onReturn,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = room.isChannel
        ? '#'
        : (room.title.isNotEmpty ? room.title[0].toUpperCase() : '?');
    final cachedMessage = RoomService.instance.lastMessageFor(room);
    final cachedIsCurrent =
        cachedMessage != null &&
        (room.lastMessageId == null || cachedMessage.id >= room.lastMessageId!);
    final lastMessage = cachedIsCurrent && cachedMessage.text.trim().isNotEmpty
        ? cachedMessage.text.trim()
        : room.lastMessageText?.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: GlassCard(
        lite: true,
        isListSection: true,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        radius: 20,
        child: PressScale(
          onLongPress:
              onSelect ??
              () => showChatOrganizationSheet(
                context,
                roomDialogKey(room),
                title: room.title,
                onChanged: onReturn,
              ),
          onTap: () async {
            if (selectionMode && onSelect != null) {
              onSelect!();
              return;
            }
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => RoomChatScreen(room: room)),
            );
            onReturn?.call();
          },
          child: DecoratedBox(
            decoration: selected
                ? BoxDecoration(
                    color: GE.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(GE.radiusSm),
                  )
                : const BoxDecoration(),
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      GhostAvatar(
                        avatarUrl: room.avatarUrl,
                        fallbackText: fallback,
                        fallbackIcon: room.isChannel
                            ? CupertinoIcons.antenna_radiowaves_left_right
                            : CupertinoIcons.person_3_fill,
                        size: 48,
                        fallbackColors: [GE.primary2, GE.primary],
                      ),
                      Positioned(
                        left: -2,
                        bottom: -2,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: GE.bgDeep,
                            shape: BoxShape.circle,
                            border: Border.all(color: GE.bg, width: 2),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            room.isChannel
                                ? CupertinoIcons.antenna_radiowaves_left_right
                                : CupertinoIcons.person_3_fill,
                            size: 10,
                            color: GE.primary,
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
                              room.title,
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
                      const SizedBox(height: 3),
                      Text(
                        lastMessage == null || lastMessage.isEmpty
                            ? 'Нет сообщений'
                            : lastMessage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: GE.sub, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                _RoomLastMessageStatus(room),
                if (selected) ...[
                  const SizedBox(width: 8),
                  Icon(
                    CupertinoIcons.checkmark_circle_fill,
                    color: GE.primary,
                    size: 21,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
const double _lastMessageStatusIconSize = 15;

class _RoomLastMessageStatus extends StatelessWidget {
  final RoomSummary room;
  const _RoomLastMessageStatus(this.room);

  @override
  Widget build(BuildContext context) {
    final meta = roomDialogMetaFor(
      room,
      RoomService.instance.lastMessageFor(room),
    );
    return RoomDialogStatus(
      meta: meta,
      timeLabel: _formatDialogTime(
        meta.timestampSeconds == null ? null : meta.timestampSeconds! * 1000,
      ),
    );
  }
}

class _DialogTile extends StatelessWidget {
  final StoredDialog d;
  final Map<String, dynamic>? profile;
  final VoidCallback? onTap;
  final SharedPreferences? prefs;
  final VoidCallback? onReturn;
  final bool selected;
  final bool selectionMode;
  final VoidCallback? onSelect;
  const _DialogTile(
    this.d, {
    this.profile,
    this.onTap,
    this.prefs,
    this.onReturn,
    this.selected = false,
    this.selectionMode = false,
    this.onSelect,
  });

  String get _displayName {
    final cached = profile?['display_name'];
    return cached is String && cached.trim().isNotEmpty
        ? cached.trim()
        : d.displayName;
  }

  String? get _avatarUrl {
    if (_isBot) {
      final current = ChatRepo.instance.getPeerAvatarCached(d.username);
      if (current != null && current.trim().isNotEmpty) return current;
    }
    final cached = profile?['avatar_url'];
    return cached is String && cached.trim().isNotEmpty ? cached : null;
  }

  bool get _isBot =>
      profile?['is_bot'] == true ||
      ChatRepo.instance.isPeerBotCached(d.username);

  bool get _isPinned => DialogSettingsStore.instance.isPinned(d.username);
  bool get _isMuted => NotificationSettings.instance.isMuted(d.username);

  // Превью последнего сообщения ИЛИ черновика (как в TG: «Черновик: …» красным).
  Widget _preview() {
    final draft = (prefs?.getString('chat_draft_${d.username}') ?? '').trim();
    if (draft.isNotEmpty) {
      final draftStyle = TextStyle(color: GE.text, fontSize: 13);
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
            ...EmojiText.packSpans(
              draft,
              draftStyle,
              (draftStyle.fontSize ?? 13) * 1.2,
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final text = d.lastText.isEmpty ? '—' : d.lastText;
    if (!d.lastFromMe) {
      return EmojiText(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: GE.sub, fontSize: 13),
      );
    }
    return Row(
      children: [
        Expanded(
          child: EmojiText(
            'Вы: $text',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: GE.sub, fontSize: 13),
          ),
        ),
      ],
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
                  _Avatar(_displayName, size: 36),
                  const SizedBox(width: 12),
                  Expanded(
                    child: EmojiText(
                      _displayName,
                      allowFormatting: false,
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
            _menuRow(
              Icons.done_all,
              'Отметить прочитанным',
              GE.primary,
              () async {
                Navigator.pop(sheetCtx);
                await ChatRepo.instance.markChatRead(d.username);
                onReturn?.call();
              },
            ),
            if (!isGroup)
              _menuRow(CupertinoIcons.person, 'Профиль', GE.primary, () {
                final nav = Navigator.of(context);
                Navigator.pop(sheetCtx);
                nav.push(
                  MaterialPageRoute(
                    builder: (_) => ProfileScreen(username: d.username),
                  ),
                );
              }),
            _menuRow(
              ChatOrganizationStore.instance.isArchived(d.username)
                  ? CupertinoIcons.archivebox
                  : CupertinoIcons.archivebox,
              ChatOrganizationStore.instance.isArchived(d.username)
                  ? 'Вернуть из архива'
                  : 'В архив',
              GE.primary,
              () async {
                Navigator.pop(sheetCtx);
                await ChatOrganizationStore.instance.setArchived(
                  d.username,
                  !ChatOrganizationStore.instance.isArchived(d.username),
                );
                onReturn?.call();
              },
            ),
            if (ChatOrganizationStore.instance.visibleFolders.isNotEmpty)
              _menuRow(
                CupertinoIcons.folder,
                'Добавить в группу чатов',
                GE.primary,
                () {
                  Navigator.pop(sheetCtx);
                  unawaited(
                    showChatOrganizationSheet(
                      context,
                      d.username,
                      title: _displayName,
                      onChanged: onReturn,
                    ),
                  );
                },
              ),
            _menuRow(
              CupertinoIcons.trash,
              'Очистить историю',
              GE.red,
              () async {
                Navigator.pop(sheetCtx);
                final ok = await _confirmClear(context);
                if (ok) {
                  await ChatRepo.instance.clearChat(d.username);
                  onReturn?.call();
                }
              },
            ),
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
              style: TextStyle(color: danger ? GE.red : GE.text, fontSize: 15),
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
          'Сообщения чата с $_displayName удалятся с этого устройства. '
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
    // Диалог — отдельная bounded-поверхность. Lite-режим намеренно не
    // запускает BackdropFilter на каждом элементе длинного списка, но оставляет
    // постоянную подложку и точный радиус, поэтому карточки не мигают при
    // переработке sliver во время прокрутки.
    final hasUnread = d.unread > 0;
    final pinned = _isPinned;
    final muted = _isMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: GlassCard(
        lite: true,
        isListSection: true,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        radius: 20,
        child: PressScale(
          onLongPress: onSelect ?? () => _showMenu(context),
          onTap: () async {
            if (selectionMode && onSelect != null) {
              onSelect!();
              return;
            }
            onTap?.call();
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChatScreen(
                  peer: d.username,
                  displayName: _displayName,
                  isBot: _isBot,
                ),
              ),
            );
            onReturn?.call(); // черновик мог измениться — обновим список
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected
                  ? GE.primary.withValues(alpha: 0.14)
                  : hasUnread
                  ? GE.primary.withValues(alpha: 0.055)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: Border(
                left: BorderSide(
                  color: hasUnread ? GE.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 3, 4, 3),
              child: Row(
                children: [
                  PressScale(
                    onTap: d.username.startsWith('g:')
                        ? null
                        : () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  ProfileScreen(username: d.username),
                            ),
                          ),
                    child: d.username.startsWith('g:')
                        ? _Avatar(_displayName, size: 52)
                        : Stack(
                            children: [
                              _Avatar(
                                _displayName,
                                size: 52,
                                avatarUrl:
                                    _avatarUrl ??
                                    ChatRepo.instance.getPeerAvatarCached(
                                      d.username,
                                    ),
                              ),
                              if (_isBot)
                                const Positioned(
                                  left: -2,
                                  bottom: -2,
                                  child: BotBadge(size: 20),
                                ),
                              if (_isBot)
                                Positioned(
                                  right: -1,
                                  bottom: -1,
                                  child: ValueListenableBuilder<String?>(
                                    valueListenable: ChatRepo.instance
                                        .watchBotStatus(d.username),
                                    builder: (_, status, _) => Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: status == 'online'
                                            ? GE.green
                                            : GE.sub.withValues(alpha: 0.42),
                                        border: Border.all(
                                          color: GE.bg,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              if (!_isBot)
                                Positioned(
                                  right: -1,
                                  bottom: -1,
                                  child: ValueListenableBuilder<bool>(
                                    valueListenable: ChatRepo.instance
                                        .watchPresence(d.username),
                                    // Кружок всегда виден (не только когда онлайн) —
                                    // офлайн тускло-серый, иначе статус пропадал
                                    // целиком и было непонятно, в сети человек или нет.
                                    builder: (_, online, _) => Container(
                                      width: 13,
                                      height: 13,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: online
                                            ? GE.green
                                            : GE.sub.withValues(alpha: 0.35),
                                        border: Border.all(
                                          color: GE.bg,
                                          width: 2,
                                        ),
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
                            if (profile?['is_official'] == true) ...[
                              const OfficialBadge(size: 16),
                              const SizedBox(width: 5),
                            ],
                            Expanded(
                              child: EmojiText(
                                _displayName,
                                allowFormatting: false,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: GE.text,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (pinned)
                              Padding(
                                padding: const EdgeInsets.only(left: 5),
                                child: Icon(
                                  CupertinoIcons.pin_fill,
                                  size: 12,
                                  color: GE.primary,
                                ),
                              ),
                            if (muted)
                              Padding(
                                padding: const EdgeInsets.only(left: 5),
                                child: Icon(
                                  CupertinoIcons.bell_slash_fill,
                                  size: 13,
                                  color: GE.sub,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Expanded(child: _preview()),
                            if (hasUnread) ...[
                              const SizedBox(width: 6),
                              Container(
                                alignment: Alignment.center,
                                constraints: const BoxConstraints(
                                  minHeight: 22,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [GE.primary2, GE.primary],
                                  ),
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
                            if (selected) ...[
                              const SizedBox(width: 6),
                              Icon(
                                CupertinoIcons.checkmark_circle_fill,
                                color: GE.primary,
                                size: 20,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _formatDialogTime(d.lastAt),
                        style: TextStyle(color: GE.sub, fontSize: 11),
                      ),
                      if (d.lastFromMe) ...[
                        const SizedBox(height: 2),
                        Builder(
                          builder: (_) {
                            final status = messageReceiptStatus(
                              pending: d.lastMessagePending,
                              delivered: d.lastMessageDelivered,
                              read: d.lastMessageRead,
                            );
                            return Icon(
                              messageReceiptIcon(status),
                              size: _lastMessageStatusIconSize,
                              color: switch (status) {
                                MessageReceiptStatus.sending => GE.sub,
                                MessageReceiptStatus.read => GE.blue,
                                MessageReceiptStatus.delivered => GE.primary,
                                MessageReceiptStatus.saved => GE.sub.withValues(
                                  alpha: 0.7,
                                ),
                              },
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatDialogTime(dynamic at) {
  if (at == null) return '';
  final dt = dialogTimestamp(at);
  if (dt.millisecondsSinceEpoch <= 0) return '';
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
  final bool selected;
  final bool selectionMode;
  final VoidCallback? onSelect;
  final VoidCallback? onReturn;
  const _LanDialogTile(
    this.d, {
    this.selected = false,
    this.selectionMode = false,
    this.onSelect,
    this.onReturn,
  });

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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: GlassCard(
        lite: true,
        isListSection: true,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        radius: 20,
        child: PressScale(
          onLongPress:
              onSelect ??
              () => showChatOrganizationSheet(
                context,
                d.username,
                title: d.displayName,
                onChanged: onReturn,
              ),
          onTap: () async {
            if (selectionMode && onSelect != null) {
              onSelect!();
              return;
            }
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LanChatScreen(
                  deviceId: _deviceId,
                  displayName: d.displayName,
                ),
              ),
            );
            onReturn?.call();
          },
          child: DecoratedBox(
            decoration: selected
                ? BoxDecoration(
                    color: GE.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(GE.radiusSm),
                  )
                : const BoxDecoration(),
            child: Row(
              children: [
                Stack(
                  children: [
                    _Avatar(
                      d.displayName,
                      size: 48,
                      icon: CupertinoIcons.antenna_radiowaves_left_right,
                      colors: [GE.green, GE.blue],
                    ),
                    // Бейдж типа — слева-снизу.
                    Positioned(
                      left: -1,
                      bottom: -1,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: GE.bg,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          CupertinoIcons.antenna_radiowaves_left_right,
                          size: 13,
                          color: GE.primary,
                        ),
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
                              color: online
                                  ? GE.green
                                  : GE.sub.withValues(alpha: 0.35),
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
                            child: EmojiText(
                              d.displayName,
                              allowFormatting: false,
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
                          Expanded(
                            child: EmojiText(
                              d.lastText.isEmpty
                                  ? 'Устройство поблизости'
                                  : d.lastText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: GE.sub, fontSize: 13),
                            ),
                          ),
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
        ),
      ),
    );
  }
}

// ─── Закладка: локальная запись, привязана к аккаунту (или гость) ────────
class _BookmarkDialogTile extends StatelessWidget {
  final StoredDialog d;
  final bool selected;
  final bool selectionMode;
  final VoidCallback? onSelect;
  final VoidCallback? onReturn;
  const _BookmarkDialogTile(
    this.d, {
    this.selected = false,
    this.selectionMode = false,
    this.onSelect,
    this.onReturn,
  });

  String get _id => d.username.substring(bookmarkDialogPrefix.length);
  bool get _isDefault => _id == defaultBookmarkId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: GlassCard(
        lite: true,
        isListSection: true,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        radius: 20,
        child: PressScale(
          onLongPress:
              onSelect ??
              () => showChatOrganizationSheet(
                context,
                d.username,
                title: d.displayName,
                onChanged: onReturn,
              ),
          onTap: () async {
            if (selectionMode && onSelect != null) {
              onSelect!();
              return;
            }
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => BookmarkChatScreen(
                  bookmarkId: _id,
                  name: d.displayName,
                  isDefault: _isDefault,
                ),
              ),
            );
            onReturn?.call();
          },
          child: DecoratedBox(
            decoration: selected
                ? BoxDecoration(
                    color: GE.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(GE.radiusSm),
                  )
                : const BoxDecoration(),
            child: Row(
              children: [
                Stack(
                  children: [
                    _Avatar(
                      d.displayName,
                      size: 48,
                      icon: _isDefault
                          ? CupertinoIcons.star_fill
                          : CupertinoIcons.bookmark_fill,
                      colors: _isDefault
                          ? [GE.yellow, GE.primary2]
                          : [GE.primary2, GE.primary],
                    ),
                    Positioned(
                      left: -1,
                      bottom: -1,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: GE.bg,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isDefault
                              ? CupertinoIcons.star_fill
                              : CupertinoIcons.bookmark_fill,
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
                            child: EmojiText(
                              d.displayName,
                              allowFormatting: false,
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
                          Expanded(
                            child: EmojiText(
                              d.lastText.isEmpty
                                  ? 'Личные заметки'
                                  : d.lastText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: GE.sub, fontSize: 13),
                            ),
                          ),
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
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
class _RoomLinkSearchTile extends StatelessWidget {
  final RoomPreview preview;
  final VoidCallback onTap;

  const _RoomLinkSearchTile({required this.preview, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final room = preview.room;
    final fallback = room.isChannel
        ? '#'
        : (room.title.isEmpty ? '?' : room.title.substring(0, 1).toUpperCase());
    final type = room.isChannel ? 'Канал' : 'Группа';
    final access = room.isPublic ? 'публичная' : 'приватная';
    return PressScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            GhostAvatar(
              avatarUrl: room.avatarUrl,
              fallbackText: fallback,
              fallbackIcon: room.isChannel
                  ? CupertinoIcons.antenna_radiowaves_left_right
                  : CupertinoIcons.person_3_fill,
              fallbackColors: [GE.primary2, GE.primary],
              size: 48,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (room.username?.isNotEmpty == true)
                        '@${room.username}',
                      '$type · $access',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, color: GE.primary, size: 18),
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
            _Avatar(u.displayName, size: 44, avatarUrl: u.avatarUrl),
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
            Icon(CupertinoIcons.chat_bubble, color: GE.primary, size: 18),
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
  // Реальная аватарка юзера (см. ChatRepo.getPeerAvatarCached) — если есть,
  // рендерится через GhostAvatar (с диск-кэшем), иначе как раньше градиент+
  // инициал. Для icon-режима (Избранное/LAN) игнорируется — там своя иконка.
  final String? avatarUrl;
  const _Avatar(
    this.name, {
    this.size = 44,
    this.icon,
    this.colors,
    this.avatarUrl,
  });
  @override
  Widget build(BuildContext context) {
    if (icon == null && avatarUrl != null) {
      return GhostAvatar(
        avatarUrl: avatarUrl,
        fallbackText: name,
        size: size,
        fallbackColors: colors,
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ghostAvatarCornerRadius(size)),
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

Future<void> showChatOrganizationSheet(
  BuildContext context,
  String chatId, {
  required String title,
  VoidCallback? onChanged,
}) async {
  final store = ChatOrganizationStore.instance;
  final result = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: GE.bgDeep,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: GE.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          ListTile(
            leading: Icon(CupertinoIcons.archivebox, color: GE.primary),
            title: Text(
              store.isArchived(chatId) ? 'Вернуть из архива' : 'В архив',
            ),
            onTap: () => Navigator.pop(sheetContext, 'archive'),
          ),
          if (store.hasCustomFolder(chatId))
            ListTile(
              leading: Icon(
                store.isMainHidden(chatId)
                    ? CupertinoIcons.eye
                    : CupertinoIcons.eye_slash,
                color: GE.primary,
              ),
              title: Text(
                store.isMainHidden(chatId)
                    ? 'Показывать в списке «Все»'
                    : 'Скрыть из списка «Все»',
              ),
              subtitle: const Text('Чат останется в выбранных группах'),
              onTap: () => Navigator.pop(sheetContext, 'main_visibility'),
            ),
          for (final folder in store.visibleFolders)
            ListTile(
              leading: Icon(
                store.contains(folder.id, chatId)
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.folder,
                color: store.contains(folder.id, chatId) ? GE.primary : GE.sub,
              ),
              title: Text(folder.name),
              subtitle: Text(
                store.contains(folder.id, chatId)
                    ? 'Убрать из группы'
                    : 'Добавить в группу',
                style: TextStyle(color: GE.sub, fontSize: 11),
              ),
              onTap: () => Navigator.pop(sheetContext, folder.id),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (result == null) return;
  if (result == 'archive') {
    await store.setArchived(chatId, !store.isArchived(chatId));
  } else if (result == 'main_visibility') {
    await store.setMainHidden(chatId, !store.isMainHidden(chatId));
  } else {
    await store.setInFolder(result, chatId, !store.contains(result, chatId));
  }
  onChanged?.call();
}
