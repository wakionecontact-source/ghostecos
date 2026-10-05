import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/local/app_logger.dart';
import '../services/auth_service.dart';
import '../services/chat_repo.dart';
import '../services/contact_service.dart';
import '../services/call_service.dart';
import '../services/search_service.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/glass.dart';
import 'chat_screen.dart';
import 'call_screen.dart';
import 'profile_screen.dart';

typedef ContactUserSearch = Future<List<FoundUser>> Function(String query);
typedef ContactUsernameReader = Future<String?> Function();

class ContactsScreen extends StatefulWidget {
  final bool isGuest;
  final VoidCallback? onRegister;
  final ContactService? service;
  final ContactUserSearch? searchUsers;
  final ContactUsernameReader? currentUsername;

  const ContactsScreen({
    super.key,
    this.isGuest = false,
    this.onRegister,
    this.service,
    this.searchUsers,
    this.currentUsername,
  });

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  late final ContactService _service =
      widget.service ?? ContactService.instance;
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  Timer? _searchDebounce;
  List<GhostContact> _contacts = const [];
  List<FoundUser> _matches = const [];
  String? _loadError;
  String? _searchError;
  String? _busyUsername;
  String _myUsername = '';
  bool _loading = true;
  bool _searching = false;
  int _searchGeneration = 0;

  bool get _hasQuery => _query.text.trim().replaceFirst('@', '').isNotEmpty;

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQueryChanged);
    if (!widget.isGuest) {
      unawaited(_loadContacts());
      unawaited(_loadIdentity());
    }
  }

  Future<void> _loadIdentity() async {
    final readUsername = widget.currentUsername ?? AuthService.username;
    final username = await readUsername();
    if (mounted && username != null) {
      setState(() => _myUsername = username.toLowerCase());
    }
  }

  Future<void> _loadContacts() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    // Render the last known list first. The network refresh below is allowed
    // to fail silently; ContactService keeps failed writes in its outbox.
    try {
      final cached = await _service.loadCached();
      if (mounted && cached.isNotEmpty) {
        setState(() {
          _contacts = cached;
          _loading = false;
        });
      }
    } catch (_) {}
    try {
      final contacts = await _service.list();
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _loading = false;
      });
    } catch (error, stack) {
      appLog.warn('contacts', 'Не удалось загрузить контакты: $error');
      appLog.debug('contacts', '$stack');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = _contacts.isEmpty
            ? 'Контакты появятся после первого подключения к сети.'
            : null;
      });
    }
  }

  void _onQueryChanged() {
    _searchDebounce?.cancel();
    final query = _query.text.trim().replaceFirst(RegExp(r'^@'), '');
    final generation = ++_searchGeneration;
    setState(() {
      _matches = const [];
      _searchError = null;
      _searching = query.length >= 2;
    });
    if (query.length < 2) {
      setState(() => _searching = false);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 320), () {
      unawaited(_runSearch(query, generation));
    });
  }

  Future<void> _runSearch(String query, int generation) async {
    try {
      final search = widget.searchUsers ?? SearchService.instance.searchUsers;
      final matches = await search(query);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _matches = matches
            .where((user) => user.username.toLowerCase() != _myUsername)
            .toList(growable: false);
        _searching = false;
      });
    } catch (error) {
      if (!mounted || generation != _searchGeneration) return;
      appLog.warn('contacts', 'Поиск контактов не удался: $error');
      setState(() {
        _searching = false;
        _searchError = 'Не получилось выполнить поиск. Попробуй ещё раз.';
      });
    }
  }

  Future<void> _addContact(FoundUser user) async {
    if (_busyUsername != null) return;
    if (user.isBot) {
      _showMessage('Ботов нельзя добавлять в контакты');
      return;
    }
    setState(() => _busyUsername = user.username);
    try {
      final contact = await _service.add(
        username: user.username,
        displayName: user.displayName,
        avatarUrl: user.avatarUrl,
      );
      if (!mounted) return;
      setState(() {
        _contacts =
            [
              ..._contacts.where(
                (item) =>
                    item.username.toLowerCase() !=
                    contact.username.toLowerCase(),
              ),
              contact,
            ]..sort(
              (a, b) => a.displayName.toLowerCase().compareTo(
                b.displayName.toLowerCase(),
              ),
            );
      });
      _showMessage(
        '${contact.displayName} теперь в контактах. Синхронизация выполнится автоматически.',
      );
    } catch (error) {
      if (!mounted) return;
      appLog.warn('contacts', 'Не удалось добавить ${user.username}: $error');
      _showMessage(
        'Не удалось добавить контакт. Проверь соединение и попробуй ещё раз.',
      );
    } finally {
      if (mounted) setState(() => _busyUsername = null);
    }
  }

  Future<void> _removeContact(GhostContact contact) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Убрать из контактов?', style: TextStyle(color: GE.text)),
        content: Text(
          '${contact.displayName} останется в чатах, но исчезнет из этого списка.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Оставить', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Убрать', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (remove != true) return;
    try {
      await _service.remove(contact.username);
      if (!mounted) return;
      setState(() {
        _contacts = _contacts
            .where((item) => item.username != contact.username)
            .toList(growable: false);
      });
      _showMessage('Контакт убран. Переписка сохранена.');
    } catch (error) {
      if (mounted) _showMessage('Не удалось убрать контакт. Попробуй ещё раз.');
      appLog.warn('contacts', 'Не удалось убрать ${contact.username}: $error');
    }
  }

  void _openChat(String username, String displayName) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(peer: username, displayName: displayName),
      ),
    );
  }

  void _openProfile(String username) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(username: username),
      ),
    );
  }

  Future<void> _callContact(GhostContact contact) async {
    try {
      await CallService.instance.startOutgoing(
        peer: contact.username,
        video: false,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CallScreen(
            peer: contact.username,
            displayName: contact.displayName,
          ),
        ),
      );
    } catch (error) {
      if (mounted) _showMessage('Не удалось начать звонок: $error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  bool _isContact(String username) => _contacts.any(
    (contact) => contact.username.toLowerCase() == username.toLowerCase(),
  );

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _query.removeListener(_onQueryChanged);
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isGuest) return _guestContent();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _loadContacts,
          color: GE.primary,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  22,
                  20,
                  150 + MediaQuery.of(context).padding.bottom,
                ),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _pageHeader(),
                          const SizedBox(height: 18),
                          _searchField(),
                          if (_hasQuery) ...[
                            const SizedBox(height: 14),
                            _searchResults(),
                          ] else ...[
                            const SizedBox(height: 22),
                            _contactsHeading(),
                            const SizedBox(height: 10),
                            _contactList(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _guestContent() => Scaffold(
    backgroundColor: Colors.transparent,
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: GlassCard(
              glow: true,
              padding: const EdgeInsets.all(26),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _iconOrb(CupertinoIcons.person_2_fill, size: 64),
                  const SizedBox(height: 18),
                  Text(
                    'Твой круг общения',
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Войди в GhostChat, чтобы добавлять людей, находить их по нику и быстро открывать личные чаты.',
                    style: TextStyle(color: GE.sub, height: 1.45),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  GlassButton(
                    label: 'Создать аккаунт',
                    icon: CupertinoIcons.arrow_right,
                    primary: true,
                    fullWidth: true,
                    onTap: widget.onRegister,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _pageHeader() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(CupertinoIcons.person_2_fill, size: 18, color: GE.primary),
                const SizedBox(width: 8),
                Text(
                  'Контакты',
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Контакты и новые собеседники в одном месте.',
              style: TextStyle(color: GE.sub, fontSize: 13),
            ),
          ],
        ),
      ),
      const SizedBox(width: 12),
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'Обновить контакты',
            visualDensity: VisualDensity.compact,
            onPressed: _loading ? null : () => unawaited(_loadContacts()),
            icon: Icon(CupertinoIcons.arrow_2_circlepath, color: GE.sub),
          ),
          if (!_loading)
            Text(
              '${_contacts.length} контактов',
              style: TextStyle(color: GE.muted, fontSize: 10),
            ),
        ],
      ),
    ],
  );

  Widget _searchField() => DecoratedBox(
    decoration: BoxDecoration(
      color: GE.glassFill.withValues(alpha: 0.66),
      borderRadius: BorderRadius.circular(GE.radiusMd),
      border: Border.all(color: GE.glassBorder),
    ),
    child: TextField(
      controller: _query,
      focusNode: _queryFocus,
      textInputAction: TextInputAction.search,
      onSubmitted: (value) {
        final query = value.trim().replaceFirst(RegExp(r'^@'), '');
        if (query.length >= 2) {
          _searchDebounce?.cancel();
          unawaited(_runSearch(query, ++_searchGeneration));
        }
      },
      style: TextStyle(color: GE.text),
      cursorColor: GE.primary,
      decoration: InputDecoration(
        hintText: 'Найти человека по имени или @нику',
        hintStyle: TextStyle(
          color: GE.sub.withValues(alpha: 0.85),
          fontSize: 13,
        ),
        prefixIcon: Icon(CupertinoIcons.search, color: GE.sub, size: 20),
        suffixIcon: _query.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Очистить поиск',
                onPressed: _query.clear,
                icon: Icon(CupertinoIcons.xmark_circle_fill, color: GE.sub),
              ),
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
      ),
    ),
  );

  Widget _contactsHeading() => Row(
    children: [
      Expanded(
        child: Text(
          'МОИ КОНТАКТЫ',
          style: TextStyle(
            color: GE.sub,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),
      ),
      if (!_loading && _contacts.isNotEmpty)
        Text(
          'потяни вниз для обновления',
          style: TextStyle(color: GE.muted, fontSize: 10),
        ),
    ],
  );

  Widget _contactList() {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 30),
        child: Center(child: CircularProgressIndicator(color: GE.primary)),
      );
    }
    if (_loadError != null) {
      return _noticeCard(
        icon: CupertinoIcons.wifi_exclamationmark,
        title: 'Не удалось обновить круг',
        message: _loadError!,
        action: 'Повторить',
        onAction: () => unawaited(_loadContacts()),
      );
    }
    if (_contacts.isEmpty) {
      return _noticeCard(
        icon: CupertinoIcons.person_2,
        title: 'Пока здесь тихо',
        message:
            'Найди знакомого по @нику — контакты будут собраны здесь, а переписки останутся в списке чатов.',
        action: 'Найти человека',
        onAction: () => _queryFocus.requestFocus(),
      );
    }
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Column(
        children: [
          for (final contact in _contacts) ...[
            _ContactTile(
              contact: contact,
              cachedAvatar: ChatRepo.instance.getPeerAvatarCached(
                contact.username,
              ),
              onProfile: () => _openProfile(contact.username),
              onMessage: () => _openChat(contact.username, contact.displayName),
              onCall: () => unawaited(_callContact(contact)),
              onRemove: () => unawaited(_removeContact(contact)),
            ),
            if (contact != _contacts.last)
              Padding(
                padding: const EdgeInsets.only(left: 58),
                child: Divider(
                  height: 1,
                  color: GE.border.withValues(alpha: 0.8),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _searchResults() {
    if (_searching) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(child: CircularProgressIndicator(color: GE.primary)),
      );
    }
    if (_searchError != null) {
      return _noticeCard(
        icon: CupertinoIcons.wifi_exclamationmark,
        title: 'Поиск не ответил',
        message: _searchError!,
        action: 'Повторить',
        onAction: () => _onQueryChanged(),
      );
    }
    if (_matches.isEmpty) {
      return _noticeCard(
        icon: CupertinoIcons.person_2,
        title: 'Пока никого не нашли',
        message: 'Проверь написание имени или попробуй точный @ник.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 9),
          child: Text(
            'РЕЗУЛЬТАТЫ ПОИСКА',
            style: TextStyle(
              color: GE.sub,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
        ),
        GlassCard(
          isListSection: true,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Column(
            children: [
              for (final user in _matches) ...[
                _SearchUserTile(
                  user: user,
                  alreadyAdded: _isContact(user.username),
                  loading: _busyUsername == user.username,
                  onAdd: () => unawaited(_addContact(user)),
                  onOpen: () => _openProfile(user.username),
                ),
                if (user != _matches.last)
                  Padding(
                    padding: const EdgeInsets.only(left: 58),
                    child: Divider(
                      height: 1,
                      color: GE.border.withValues(alpha: 0.8),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _noticeCard({
    required IconData icon,
    required String title,
    required String message,
    String? action,
    VoidCallback? onAction,
  }) => GlassCard(
    lite: true,
    padding: const EdgeInsets.all(20),
    child: Column(
      children: [
        _iconOrb(icon, size: 52),
        const SizedBox(height: 13),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(color: GE.text, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: GE.sub, fontSize: 12, height: 1.4),
        ),
        if (action != null && onAction != null) ...[
          const SizedBox(height: 14),
          GlassButton(label: action, onTap: onAction),
        ],
      ],
    ),
  );

  Widget _iconOrb(IconData icon, {double size = 48}) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: GE.primary.withValues(alpha: 0.14),
      border: Border.all(color: GE.primary.withValues(alpha: 0.28)),
      boxShadow: [
        BoxShadow(
          color: GE.primary.withValues(alpha: 0.12),
          blurRadius: 20,
          spreadRadius: 1,
        ),
      ],
    ),
    child: Icon(icon, size: size * 0.48, color: GE.primary),
  );
}

class _ContactTile extends StatelessWidget {
  final GhostContact contact;
  final String? cachedAvatar;
  final VoidCallback onProfile;
  final VoidCallback onMessage;
  final VoidCallback onCall;
  final VoidCallback onRemove;

  const _ContactTile({
    required this.contact,
    required this.cachedAvatar,
    required this.onProfile,
    required this.onMessage,
    required this.onCall,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        PressScale(
          onTap: onProfile,
          child: GhostAvatar(
            avatarUrl: contact.avatarUrl ?? cachedAvatar,
            fallbackText: contact.displayName,
            size: 46,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: PressScale(
            onTap: onProfile,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.displayName,
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
                    '@${contact.username}  ·  В контактах',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Позвонить',
          onPressed: onCall,
          style: IconButton.styleFrom(
            backgroundColor: GE.green.withValues(alpha: 0.12),
            foregroundColor: GE.green,
            visualDensity: VisualDensity.compact,
          ),
          icon: const Icon(CupertinoIcons.phone_fill, size: 18),
        ),
        IconButton(
          tooltip: 'Написать',
          onPressed: onMessage,
          style: IconButton.styleFrom(
            backgroundColor: GE.primary.withValues(alpha: 0.12),
            foregroundColor: GE.primary,
            visualDensity: VisualDensity.compact,
          ),
          icon: const Icon(CupertinoIcons.chat_bubble_text, size: 19),
        ),
        PopupMenuButton<String>(
          tooltip: 'Действия с контактом',
          icon: Icon(CupertinoIcons.ellipsis, color: GE.sub),
          color: GE.bgDeep,
          onSelected: (_) => onRemove(),
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'remove',
              child: Text(
                'Убрать из контактов',
                style: TextStyle(color: GE.red),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _SearchUserTile extends StatelessWidget {
  final FoundUser user;
  final bool alreadyAdded;
  final bool loading;
  final VoidCallback onAdd;
  final VoidCallback onOpen;

  const _SearchUserTile({
    required this.user,
    required this.alreadyAdded,
    required this.loading,
    required this.onAdd,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        PressScale(
          onTap: onOpen,
          child: GhostAvatar(
            avatarUrl:
                user.avatarUrl ??
                ChatRepo.instance.getPeerAvatarCached(user.username),
            fallbackText: user.displayName,
            size: 46,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: PressScale(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.displayName,
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
                    '@${user.username}${user.isBot
                        ? ' · бот'
                        : user.isGuest
                        ? ' · гость'
                        : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (alreadyAdded)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.checkmark_circle_fill,
                color: GE.green,
                size: 18,
              ),
              const SizedBox(width: 5),
              Text('Добавлен', style: TextStyle(color: GE.green, fontSize: 11)),
            ],
          )
        else if (user.isBot)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.lock, color: GE.muted, size: 17),
              const SizedBox(width: 5),
              Text(
                'Только чат',
                style: TextStyle(color: GE.muted, fontSize: 11),
              ),
            ],
          )
        else
          IconButton(
            tooltip: 'Добавить в контакты',
            onPressed: loading ? null : onAdd,
            icon: loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: GE.primary,
                    ),
                  )
                : Icon(CupertinoIcons.person_add, color: GE.primary),
          ),
      ],
    ),
  );
}
