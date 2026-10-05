import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'package:file_selector/file_selector.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../mesh_background.dart';
import '../services/auth_service.dart';
import '../services/chat_repo.dart';
import '../services/performance_service.dart';
import '../services/room_service.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/chat_composer.dart';
import '../widgets/emoji_picker.dart';
import '../widgets/emoji_text.dart';
import '../widgets/empty_chat_state.dart';
import '../widgets/glass.dart';
import '../widgets/marquee_text.dart';
import 'room_profile_screen.dart';

class RoomsScreen extends StatefulWidget {
  const RoomsScreen({super.key});

  @override
  State<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends State<RoomsScreen> {
  final _service = RoomService.instance;
  final _searchController = TextEditingController();
  Timer? _searchTimer;
  List<RoomSearchResult> _searchResults = const [];
  bool _searching = false;
  bool _loading = false;
  String? _error;
  String _roomFilter = 'all';

  @override
  void initState() {
    super.initState();
    _loadMine();
  }

  Future<void> _loadMine() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      await _service.loadMy();
      if (!mounted) return;
      setState(() => _error = null);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openRoom(RoomSummary room) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => RoomChatScreen(room: room)));
    if (mounted) await _loadMine();
  }

  List<RoomSummary> _filteredRooms(List<RoomSummary> rooms) {
    if (_roomFilter == 'all') return rooms;
    return rooms.where((room) => room.roomType == _roomFilter).toList();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchTimer?.cancel();
    if (value.trim().length < 2) {
      setState(() => _searchResults = const []);
      return;
    }
    _searchTimer = Timer(const Duration(milliseconds: 350), _search);
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.length < 2) return;
    setState(() => _searching = true);
    try {
      final results = await _service.searchRooms(query);
      if (!mounted || query != _searchController.text.trim()) return;
      setState(() => _searchResults = results);
    } catch (error) {
      if (mounted) _message('Поиск не удался: $error');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _openSearchResult(RoomSearchResult result) async {
    if (result.isMember) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => RoomChatScreen(room: result.room)),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      final response = await _service.requestJoin(result.room);
      if (!mounted) return;
      final status = response['status']?.toString();
      _message(status == 'requested' ? 'Заявка отправлена' : 'Вы вступили');
      await _search();
    } catch (error) {
      if (mounted) _message('Не удалось вступить: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Refresh owner roles before showing the counters. The backend remains
      // authoritative if another device creates a room at the same time.
      await _service.loadMy();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted) return;
    final draft = await _showCreateDialog(
      channelCount: _service.ownedChannelCount,
      groupCount: _service.ownedGroupCount,
    );
    if (draft == null || !mounted) return;
    if (draft.title.length < 2) {
      _message('Название должно быть не короче 2 символов');
      return;
    }
    if (draft.username.length < 3) {
      _message(
        draft.type == 'channel'
            ? 'Username канала должен быть не короче 3 символов'
            : 'Username группы должен быть не короче 3 символов',
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (draft.type == 'channel') {
        await _service.createChannel(
          username: draft.username,
          title: draft.title,
          about: draft.about,
          visibility: draft.visibility,
          historyMode: draft.historyMode,
        );
      } else {
        await _service.createGroup(
          username: draft.username,
          title: draft.title,
          about: draft.about,
          visibility: draft.visibility,
          historyMode: draft.historyMode,
        );
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
      });
      _message(draft.type == 'channel' ? 'Канал создан' : 'Группа создана');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _join() async {
    final draft = await _showJoinDialog();
    if (draft == null || !mounted) return;
    if (draft.value.length < 3) {
      _message(
        draft.type == 'channel'
            ? 'Username канала должен быть не короче 3 символов'
            : 'Укажите username группы',
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (draft.type == 'channel') {
        await _service.joinChannel(draft.value);
      } else {
        await _service.joinGroup(draft.value);
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
      });
      _message('Вы вступили');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<_RoomDraft?> _showCreateDialog({
    required int channelCount,
    required int groupCount,
  }) async {
    final username = TextEditingController();
    final title = TextEditingController();
    final about = TextEditingController();
    try {
      return await showDialog<_RoomDraft>(
        context: context,
        builder: (dialogContext) {
          var type = 'channel';
          var visibility = 'private';
          var historyMode = 'new_only';
          int countForType() => type == 'channel' ? channelCount : groupCount;
          int limitForType() => RoomLimits.limitFor(type);
          bool atLimit() => countForType() >= limitForType();
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              backgroundColor: GE.bgDeep,
              title: const Text('Новая комната'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: type,
                      decoration: const InputDecoration(labelText: 'Тип'),
                      items: [
                        DropdownMenuItem(
                          value: 'channel',
                          child: Text(
                            'Канал · $channelCount/${RoomLimits.channelsPerUser}',
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'group',
                          child: Text(
                            'Группа · $groupCount/${RoomLimits.groupsPerUser}',
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) setDialogState(() => type = value);
                      },
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Создано вами: ${countForType()}/${limitForType()}',
                        style: TextStyle(color: GE.sub, fontSize: 12),
                      ),
                    ),
                    if (atLimit()) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          type == 'channel'
                              ? 'Лимит каналов достигнут'
                              : 'Лимит групп достигнут',
                          style: TextStyle(color: GE.red, fontSize: 12),
                        ),
                      ),
                    ],
                    TextField(
                      controller: title,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Название'),
                    ),
                    TextField(
                      controller: username,
                      decoration: InputDecoration(
                        labelText: type == 'channel'
                            ? 'Username канала'
                            : 'Username группы',
                        prefixText: '@',
                      ),
                    ),
                    TextField(
                      controller: about,
                      maxLines: 2,
                      decoration: const InputDecoration(labelText: 'Описание'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: visibility,
                      decoration: const InputDecoration(labelText: 'Доступ'),
                      items: const [
                        DropdownMenuItem(
                          value: 'private',
                          child: Text('Приватная · E2EE'),
                        ),
                        DropdownMenuItem(
                          value: 'public',
                          child: Text('Публичная'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => visibility = value);
                        }
                      },
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: historyMode,
                      decoration: const InputDecoration(
                        labelText: 'История для новых участников',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'new_only',
                          child: Text('Только новые сообщения'),
                        ),
                        DropdownMenuItem(
                          value: 'all',
                          child: Text('Вся история'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => historyMode = value);
                        }
                      },
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
                  onPressed: atLimit()
                      ? null
                      : () => Navigator.pop(
                          dialogContext,
                          _RoomDraft(
                            type: type,
                            username: username.text.trim().replaceFirst(
                              '@',
                              '',
                            ),
                            title: title.text.trim(),
                            about: about.text.trim(),
                            visibility: visibility,
                            historyMode: historyMode,
                          ),
                        ),
                  child: const Text('Создать'),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      username.dispose();
      title.dispose();
      about.dispose();
    }
  }

  Future<_JoinDraft?> _showJoinDialog() async {
    final value = TextEditingController();
    try {
      return await showDialog<_JoinDraft>(
        context: context,
        builder: (dialogContext) {
          var type = 'channel';
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              backgroundColor: GE.bgDeep,
              title: const Text('Вступить'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    items: const [
                      DropdownMenuItem(value: 'channel', child: Text('Канал')),
                      DropdownMenuItem(value: 'group', child: Text('Группа')),
                    ],
                    onChanged: (next) {
                      if (next != null) setDialogState(() => type = next);
                    },
                  ),
                  TextField(
                    controller: value,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: type == 'channel'
                          ? 'Username канала'
                          : 'Username публичной группы',
                      prefixText: '@',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    dialogContext,
                    _JoinDraft(
                      type: type,
                      value: value.text.trim().replaceFirst('@', ''),
                    ),
                  ),
                  child: const Text('Вступить'),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      value.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          titleText: 'Каналы и группы',
          showBack: true,
          actions: [
            IconButton(
              tooltip: 'Вступить',
              onPressed: _loading ? null : _join,
              icon: const Icon(CupertinoIcons.person_add),
            ),
            IconButton(
              tooltip: 'Создать',
              onPressed: _loading ? null : _create,
              icon: const Icon(CupertinoIcons.add),
            ),
          ],
        ),
        body: RefreshIndicator(
          color: GE.primary,
          onRefresh: _loadMine,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Text(
                'Общайтесь в группах и следите за публикациями каналов в одном месте.',
                style: TextStyle(color: GE.sub, height: 1.35),
              ),
              const SizedBox(height: 18),
              ValueListenableBuilder<List<RoomSummary>>(
                valueListenable: _service.rooms,
                builder: (context, rooms, _) => _MyRoomsSection(
                  rooms: _filteredRooms(rooms),
                  totalRooms: rooms.length,
                  filter: _roomFilter,
                  onFilterChanged: (filter) {
                    setState(() => _roomFilter = filter);
                  },
                  onOpen: _openRoom,
                  onCreate: _loading ? null : _create,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Найти комнату',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              GlassCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    icon: Icon(CupertinoIcons.search, color: GE.primary),
                    hintText: 'Название, username или ссылка',
                    border: InputBorder.none,
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                ),
              ),
              if (_searchController.text.trim().length >= 2) ...[
                const SizedBox(height: 10),
                if (_searchResults.isEmpty && !_searching)
                  Text('Ничего не найдено', style: TextStyle(color: GE.sub)),
                for (final result in _searchResults) ...[
                  _RoomSearchTile(
                    result: result,
                    onTap: _loading ? null : () => _openSearchResult(result),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
              const SizedBox(height: 18),
              _RoomActionCard(
                icon: CupertinoIcons.add_circled,
                title: 'Создать канал или группу',
                subtitle: 'Новая комната появится в общем списке чатов',
                onTap: _loading ? null : _create,
              ),
              const SizedBox(height: 10),
              _RoomActionCard(
                icon: CupertinoIcons.person_add,
                title: 'Вступить по username или ссылке',
                subtitle:
                    'Можно найти публичную комнату или открыть приглашение',
                onTap: _loading ? null : _join,
              ),
              if (_loading) ...[
                const SizedBox(height: 18),
                const Center(child: CircularProgressIndicator()),
              ],
              if (_error != null) ...[
                const SizedBox(height: 14),
                Text(_error!, style: TextStyle(color: GE.red, fontSize: 12.5)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MyRoomsSection extends StatelessWidget {
  final List<RoomSummary> rooms;
  final int totalRooms;
  final String filter;
  final ValueChanged<String> onFilterChanged;
  final ValueChanged<RoomSummary> onOpen;
  final VoidCallback? onCreate;

  const _MyRoomsSection({
    required this.rooms,
    required this.totalRooms,
    required this.filter,
    required this.onFilterChanged,
    required this.onOpen,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Мои комнаты',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Text('$totalRooms', style: TextStyle(color: GE.sub, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _RoomFilterChip(
                label: 'Все',
                selected: filter == 'all',
                onTap: () => onFilterChanged('all'),
              ),
              const SizedBox(width: 8),
              _RoomFilterChip(
                label: 'Каналы',
                icon: CupertinoIcons.antenna_radiowaves_left_right,
                selected: filter == 'channel',
                onTap: () => onFilterChanged('channel'),
              ),
              const SizedBox(width: 8),
              _RoomFilterChip(
                label: 'Группы',
                icon: CupertinoIcons.person_3_fill,
                selected: filter == 'group',
                onTap: () => onFilterChanged('group'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (rooms.isEmpty)
          GlassCard(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            child: Column(
              children: [
                Icon(
                  totalRooms == 0
                      ? CupertinoIcons.square_stack_3d_up
                      : CupertinoIcons.slider_horizontal_3,
                  color: GE.primary,
                  size: 30,
                ),
                const SizedBox(height: 10),
                Text(
                  totalRooms == 0
                      ? 'Здесь появятся ваши каналы и группы'
                      : 'В этом фильтре пока пусто',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GE.text, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 5),
                Text(
                  totalRooms == 0
                      ? 'Создайте комнату или найдите публичную по ссылке.'
                      : 'Попробуйте выбрать другой тип комнаты.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GE.sub, fontSize: 12.5),
                ),
                if (totalRooms == 0 && onCreate != null) ...[
                  const SizedBox(height: 14),
                  GlassButton(
                    label: 'Создать комнату',
                    icon: CupertinoIcons.add,
                    primary: true,
                    onTap: onCreate,
                  ),
                ],
              ],
            ),
          )
        else
          Column(
            children: [
              for (final room in rooms) ...[
                _MyRoomTile(room: room, onTap: () => onOpen(room)),
                const SizedBox(height: 8),
              ],
            ],
          ),
      ],
    );
  }
}

class _RoomFilterChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _RoomFilterChip({
    required this.label,
    this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? GE.primary.withValues(alpha: 0.18)
              : GE.surface.withValues(alpha: 0.56),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected
                ? GE.primary.withValues(alpha: 0.55)
                : GE.border.withValues(alpha: 0.6),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: selected ? GE.primary : GE.sub),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: selected ? GE.text : GE.sub,
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MyRoomTile extends StatelessWidget {
  final RoomSummary room;
  final VoidCallback onTap;

  const _MyRoomTile({required this.room, required this.onTap});

  String get _roleLabel => switch (room.role) {
    'owner' => 'Владелец',
    'admin' => 'Администратор',
    _ => 'Участник',
  };

  @override
  Widget build(BuildContext context) {
    final fallback = room.isChannel
        ? '#'
        : (room.title.isEmpty ? '?' : room.title.substring(0, 1).toUpperCase());
    final handle = room.username?.trim();
    final subtitle = [
      if (handle != null && handle.isNotEmpty) '@$handle',
      room.isChannel ? 'Канал' : 'Группа',
      '${room.membersCount} участников',
    ].join(' · ');
    return GlassCard(
      lite: true,
      isListSection: true,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      radius: 20,
      child: PressScale(
        onTap: onTap,
        child: Row(
          children: [
            GhostAvatar(
              avatarUrl: room.avatarUrl,
              fallbackText: fallback,
              fallbackIcon: room.isChannel
                  ? CupertinoIcons.antenna_radiowaves_left_right
                  : CupertinoIcons.person_3_fill,
              size: 50,
              fallbackColors: room.isChannel
                  ? [GE.primary2, GE.primary]
                  : [GE.primary, GE.primary2],
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
                      Icon(
                        room.isPublic
                            ? CupertinoIcons.globe
                            : CupertinoIcons.lock_fill,
                        color: GE.sub,
                        size: 13,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    _roleLabel,
                    style: TextStyle(color: GE.primary, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(CupertinoIcons.chevron_right, color: GE.sub, size: 18),
          ],
        ),
      ),
    );
  }
}

class _RoomSearchTile extends StatelessWidget {
  final RoomSearchResult result;
  final VoidCallback? onTap;

  const _RoomSearchTile({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final room = result.room;
    return GlassCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        enabled: onTap != null,
        leading: GhostAvatar(
          avatarUrl: room.avatarUrl,
          fallbackText: room.title,
          fallbackIcon: room.isChannel
              ? CupertinoIcons.antenna_radiowaves_left_right
              : CupertinoIcons.person_3_fill,
          size: 44,
        ),
        title: Text(room.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '@${room.username ?? 'без username'} · ${room.isPublic ? 'публичная' : 'приватная'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Icon(
          result.isMember
              ? CupertinoIcons.chevron_right
              : CupertinoIcons.person_add,
          color: GE.primary,
        ),
        onTap: onTap,
      ),
    );
  }
}

class _RoomActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _RoomActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        enabled: onTap != null,
        leading: Icon(icon, color: GE.primary),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(CupertinoIcons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class RoomChatScreen extends StatefulWidget {
  final RoomSummary room;
  const RoomChatScreen({super.key, required this.room});

  @override
  State<RoomChatScreen> createState() => _RoomChatScreenState();
}

class _RoomChatScreenState extends State<RoomChatScreen> {
  static const double _emojiPanelH = 300;
  static const int _bottomAnchorMaxMsgs = 40;

  final _service = RoomService.instance;
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  final _sendBtnKey = GlobalKey();
  Timer? _poller;
  StreamSubscription<RoomEvent>? _roomEventSub;
  List<RoomMessage> _messages = const [];
  List<RoomPinnedMessage> _pinnedMessages = const [];
  Set<int> _pinnedIds = const {};
  final Set<int> _readReceiptSent = {};
  String? _me;
  String? _error;
  bool _loading = true;
  bool _sending = false;
  bool _refreshing = false;
  bool _emojiOpen = false;
  bool _pinnedBottom = true;
  late RoomSummary _room;

  bool get _readOnly => _room.isChannel && !_room.canManage;

  @override
  void initState() {
    super.initState();
    _room = widget.room;
    _scroll.addListener(_onScroll);
    _open();
    _roomEventSub = _service.onRoomEvent.listen((event) {
      if (event.roomType == _room.roomType && event.roomId == _room.id) {
        unawaited(_refreshAndPins());
      }
    });
    // WS is the fast path. Keep a low-frequency recovery check for messages
    // that arrived while Android suspended the socket.
    _poller = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final fromBottom =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    _pinnedBottom = fromBottom < 100;
  }

  Future<void> _open() async {
    _me = await AuthService.username();
    await _refresh(initial: true);
    await _loadPins();
  }

  Future<void> _loadPins() async {
    try {
      final pins = await _service.loadPinnedMessages(_room);
      if (!mounted) return;
      final localById = {for (final message in _messages) message.id: message};
      final enriched = pins
          .map((pin) {
            final local = localById[pin.messageId];
            if (pin.text.isNotEmpty || local == null) return pin;
            return RoomPinnedMessage(
              messageId: pin.messageId,
              text: local.text,
              senderUsername: pin.senderUsername.isEmpty
                  ? local.senderUsername
                  : pin.senderUsername,
              senderDisplayName: pin.senderDisplayName.isEmpty
                  ? local.senderDisplayName
                  : pin.senderDisplayName,
              senderAvatarUrl: pin.senderAvatarUrl ?? local.senderAvatarUrl,
              createdAt: pin.createdAt == 0 ? local.createdAt : pin.createdAt,
              pinnedAt: pin.pinnedAt,
              notify: pin.notify,
            );
          })
          .toList(growable: false);
      setState(() {
        _pinnedMessages = enriched;
        _pinnedIds = enriched.map((pin) => pin.messageId).toSet();
      });
    } catch (_) {
      // Pin metadata should never prevent the room from opening.
    }
  }

  Future<void> _refreshAndPins() async {
    await _refresh();
    await _loadPins();
  }

  Future<void> _refresh({bool initial = false}) async {
    if (!mounted && !initial) return;
    if (_refreshing) return;
    _refreshing = true;
    try {
      if (initial) {
        final saved = await _service.loadCachedMessages(_room);
        if (!mounted) return;
        setState(() {
          _messages = saved;
          _loading = false;
          _error = null;
        });
        if (saved.isNotEmpty) _scrollToBottom(animate: false);
      }

      final previousCount = _messages.length;
      await _service.syncRoomMessages(_room);
      final cached = await _service.loadCachedMessages(_room);
      if (!mounted) return;
      final changed =
          cached.length != _messages.length ||
          initial ||
          cached.asMap().entries.any((entry) {
            final old = _messages[entry.key];
            final next = entry.value;
            return old.id != next.id ||
                old.pending != next.pending ||
                old.sendFailed != next.sendFailed;
          });
      setState(() {
        if (changed) _messages = cached;
        _loading = false;
        _error = null;
      });
      if (initial || (_pinnedBottom && cached.length > previousCount)) {
        _scrollToBottom(animate: !initial);
      }

      final unreadIds = cached
          .where(
            (message) =>
                !message.fromMe && !_readReceiptSent.contains(message.id),
          )
          .map((message) => message.id)
          .toList(growable: false);
      if (unreadIds.isNotEmpty) {
        _readReceiptSent.addAll(unreadIds);
        try {
          await _service.markRoomMessagesRead(_room, unreadIds);
        } catch (_) {
          _readReceiptSent.removeAll(unreadIds);
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _messages.isEmpty ? error.toString() : null;
      });
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _addMember() async {
    final username = await _showAddMemberDialog();
    if (username == null || !mounted) return;
    try {
      final response = await _service.addMember(_room, username);
      if (!mounted) return;
      if (response['status'] == 'blocked') {
        final sendLink = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: GE.bgDeep,
            title: const Text('Добавление заблокировано'),
            content: Text(
              '@$username запретил добавление в ${_room.isChannel ? 'каналы' : 'группы'} или вы не у него в контактах. Отправить персональную ссылку на 3 дня?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Не отправлять'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Отправить ссылку'),
              ),
            ],
          ),
        );
        if (sendLink == true) {
          final link = await _service.createInviteLink(
            _room,
            usernames: [username],
          );
          await Clipboard.setData(
            ClipboardData(text: '${GE.baseUrl}${link.link}'),
          );
          if (mounted) _message('Персональная ссылка скопирована');
        } else if (mounted) {
          _message('Пользователь не добавлен');
        }
      } else if (mounted) {
        _message('Участник добавлен');
      }
    } catch (error) {
      if (mounted) _message('Не удалось добавить участника: $error');
    }
  }

  Future<void> _openRoomProfile() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final updated = await Navigator.of(context).push<RoomSummary>(
      MaterialPageRoute(builder: (_) => RoomProfileScreen(room: _room)),
    );
    if (updated != null && mounted) {
      setState(() => _room = updated);
    }
  }

  Future<String?> _showAddMemberDialog() async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: GE.bgDeep,
          title: const Text('Добавить участника'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Username пользователя',
              prefixText: '@',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                controller.text.trim().replaceFirst('@', ''),
              ),
              child: const Text('Добавить'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _send() async {
    if (_readOnly || _sending) return;
    final text = _composer.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await _service.sendText(_room, text);
      _composer.clear();
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (!animate) {
        _scroll.jumpTo(target);
        return;
      }
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _toggleEmoji() {
    if (_readOnly) return;
    setState(() => _emojiOpen = !_emojiOpen);
    if (_emojiOpen) FocusManager.instance.primaryFocus?.unfocus();
  }

  void _insertEmoji(String emoji) {
    final value = _composer.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final text = value.text.replaceRange(start, end, emoji);
    _composer.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  Future<void> _openAttachSheet() async {
    if (_readOnly || _sending) return;
    try {
      final files = await openFiles();
      if (files.isEmpty || !mounted) return;
      final selected = files.take(5).toList(growable: false);
      if (files.length > selected.length) {
        _message('За одну отправку можно выбрать не более 5 вложений');
      }
      final caption = await _attachmentCaption();
      if (caption == null) return;
      for (final file in selected) {
        final bytes = await file.readAsBytes();
        await _service.sendAttachment(
          _room,
          bytes: Uint8List.fromList(bytes),
          mime: _mimeForName(file.name),
          fileName: file.name,
          caption: caption,
        );
      }
      if (mounted) _message('Вложения поставлены в очередь отправки');
    } catch (error) {
      if (mounted) _message('Не удалось отправить вложение: $error');
    }
  }

  Future<String?> _attachmentCaption() async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: GE.bgDeep,
          title: const Text('Подпись к вложениям'),
          content: TextField(
            controller: controller,
            maxLines: 3,
            maxLength: 4000,
            decoration: const InputDecoration(hintText: 'Необязательно'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Отправить'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  String _mimeForName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return 'application/octet-stream';
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _forwardMessage(RoomMessage message) async {
    final target = await _showForwardPicker();
    if (target == null || !mounted) return;
    try {
      if (target.room != null) {
        await _service.sendText(
          target.room!,
          message.text,
          forwardedFrom: message.senderUsername,
        );
      } else {
        await ChatRepo.instance.sendDmText(
          target.username!,
          message.text,
          forwardedFrom: message.senderUsername,
        );
      }
      if (mounted) _message('Переслано в __DART_INTERP__{target.label}');
    } catch (error) {
      if (mounted) _message('Не переслалось: $error');
    }
  }

  Future<RoomForwardTarget?> _showForwardPicker() async {
    final dialogs = ChatRepo.instance.dialogsNotifier.value
        .where((d) => d.username != roomDialogKey(_room))
        .where((d) => !d.username.startsWith('g:'))
        .toList();
    var rooms = RoomService.instance.rooms.value;
    if (rooms.isEmpty) {
      try {
        rooms = await _service.loadMy();
      } catch (_) {}
    }
    if (!mounted) return null;
    rooms = rooms
        .where((room) => roomDialogKey(room) != roomDialogKey(_room))
        .toList(growable: false);
    return showModalBottomSheet<RoomForwardTarget>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            radius: GE.radiusLg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Переслать кому?',
                      style: TextStyle(
                        color: GE.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                for (final dialog in dialogs)
                  _ForwardTargetTile(
                    label: '@${dialog.username}',
                    icon: CupertinoIcons.person,
                    onTap: () => Navigator.pop(
                      ctx,
                      RoomForwardTarget.user(dialog.username),
                    ),
                  ),
                for (final room in rooms)
                  _ForwardTargetTile(
                    label: room.title,
                    icon: room.isChannel
                        ? CupertinoIcons.antenna_radiowaves_left_right
                        : CupertinoIcons.person_3_fill,
                    avatarUrl: room.avatarUrl,
                    fallbackText: room.isChannel
                        ? '#'
                        : (room.title.isNotEmpty ? room.title[0] : '?'),
                    onTap: () =>
                        Navigator.pop(ctx, RoomForwardTarget.room(room)),
                  ),
                if (dialogs.isEmpty && rooms.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'Нет других чатов',
                      style: TextStyle(color: GE.sub),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: GE.primary.withValues(alpha: 0.17),
            width: 0.7,
          ),
        ),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            GE.bgDeep.withValues(alpha: 0.70),
            GE.bgDeep.withValues(alpha: 0.40),
            GE.bgDeep.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.6, 1.0],
        ),
      ),
      child: _RoomChatHeader(
        room: _room,
        canManage: _room.canManage,
        onBack: () {
          FocusManager.instance.primaryFocus?.unfocus();
          Navigator.of(context).maybePop();
        },
        onProfileTap: _openRoomProfile,
        onAddMember: _addMember,
        onRefresh: () => _refresh(initial: true),
        refreshEnabled: !_loading,
      ),
    );
    if (PerformanceService.instance.reducedEffects) return surface;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 9, sigmaY: 9),
        child: surface,
      ),
    );
  }

  Widget _messagesView() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_messages.isEmpty) {
      return EmptyChatState(
        icon: _room.isChannel
            ? CupertinoIcons.antenna_radiowaves_left_right
            : CupertinoIcons.person_3_fill,
        title: 'Сообщений пока нет',
        subtitle: _room.isChannel
            ? 'Публикации канала появятся здесь'
            : 'Начните разговор с участниками группы',
      );
    }

    final bottomAnchor = _messages.length <= _bottomAnchorMaxMsgs;
    final list = ListView.builder(
      shrinkWrap: bottomAnchor,
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      itemCount: _messages.length,
      itemBuilder: (_, index) {
        final message = _messages[index];
        final prevSame =
            index > 0 &&
            _messages[index - 1].senderUsername == message.senderUsername;
        return GestureDetector(
          onLongPress: () => _showMessageActions(message),
          child: _RoomMessageBubble(
            message: message,
            room: _room,
            myUsername: _me,
            prevSame: prevSame,
            showAuthor: true,
            showAvatar: _room.isGroup,
          ),
        );
      },
    );
    return bottomAnchor
        ? Align(alignment: Alignment.bottomCenter, child: list)
        : list;
  }

  Future<void> _showMessageActions(RoomMessage message) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            radius: GE.radiusLg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(CupertinoIcons.arrowshape_turn_up_right),
                  title: const Text('Переслать'),
                  onTap: () => Navigator.pop(context, 'forward'),
                ),
                if (_room.canManage) ...[
                  ListTile(
                    leading: Icon(
                      _pinnedIds.contains(message.id)
                          ? CupertinoIcons.pin_slash
                          : CupertinoIcons.pin,
                      color: GE.primary,
                    ),
                    title: Text(
                      _pinnedIds.contains(message.id)
                          ? 'Снять закрепление'
                          : 'Закрепить сообщение',
                    ),
                    onTap: () => Navigator.pop(
                      context,
                      _pinnedIds.contains(message.id) ? 'unpin' : 'pin',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'forward') {
      await _forwardMessage(message);
      return;
    }
    try {
      if (action == 'unpin') {
        await _service.unpinMessage(_room, message.id);
      } else {
        final notify = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: GE.bgDeep,
            title: const Text('Закрепить сообщение?'),
            content: const Text('Уведомить участников комнаты?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Без уведомления'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Закрепить'),
              ),
            ],
          ),
        );
        if (notify == null) return;
        await _service.pinMessage(_room, message.id, notify: notify);
      }
      await _loadPins();
      if (mounted) {
        _message(
          action == 'unpin' ? 'Закрепление снято' : 'Сообщение закреплено',
        );
      }
    } catch (error) {
      if (mounted) _message('Не удалось изменить закрепление: $error');
    }
  }

  Future<void> _openPins() async {
    if (_pinnedMessages.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.72,
        child: _RoomPinnedSheet(
          pins: _pinnedMessages,
          onTap: (messageId) {
            Navigator.of(context).pop();
            final index = _messages.indexWhere((item) => item.id == messageId);
            if (index < 0 || !_scroll.hasClients) return;
            final target = (index * 76.0).clamp(
              0.0,
              _scroll.position.maxScrollExtent,
            );
            _scroll.animateTo(
              target,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _poller?.cancel();
    _roomEventSub?.cancel();
    _composer.dispose();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final headerHeight = topInset + 60;
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        extendBodyBehindAppBar: true,
        appBar: PreferredSize(
          preferredSize: Size.fromHeight(headerHeight),
          child: _header(),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.only(top: headerHeight),
                child: Column(
                  children: [
                    if (_error != null)
                      MaterialBanner(
                        content: Text(
                          _error!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        actions: [
                          TextButton(
                            onPressed: _refresh,
                            child: const Text('Повторить'),
                          ),
                        ],
                      ),
                    if (_pinnedMessages.isNotEmpty)
                      _RoomPinnedBar(
                        pin: _pinnedMessages.first,
                        count: _pinnedMessages.length,
                        onTap: _openPins,
                      ),
                    Expanded(child: _messagesView()),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: _emojiOpen ? _emojiPanelH : 0,
              child: SafeArea(
                top: false,
                bottom: !_emojiOpen,
                child: ChatComposer(
                  controller: _composer,
                  emojiOpen: _emojiOpen,
                  sending: _sending,
                  enabled: !_readOnly,
                  sendKey: _sendBtnKey,
                  hint: _readOnly
                      ? 'Только чтение — публикуют админы'
                      : 'Сообщение',
                  onAttach: _openAttachSheet,
                  onToggleEmoji: _toggleEmoji,
                  onSend: _send,
                  onFieldTap: () {
                    if (_emojiOpen) setState(() => _emojiOpen = false);
                  },
                ),
              ),
            ),
            if (_emojiOpen)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _emojiPanelH,
                child: EmojiPicker(onPick: _insertEmoji),
              ),
          ],
        ),
      ),
    );
  }
}

class _RoomChatHeader extends StatelessWidget {
  final RoomSummary room;
  final bool canManage;
  final VoidCallback onBack;
  final VoidCallback onProfileTap;
  final VoidCallback onAddMember;
  final VoidCallback onRefresh;
  final bool refreshEnabled;

  const _RoomChatHeader({
    required this.room,
    required this.canManage,
    required this.onBack,
    required this.onProfileTap,
    required this.onAddMember,
    required this.onRefresh,
    required this.refreshEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = room.isChannel
        ? '#'
        : (room.title.isNotEmpty ? room.title[0].toUpperCase() : '?');
    final subtitle = room.username?.isNotEmpty == true
        ? '@${room.username}'
        : '${room.membersCount} участников';

    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 60,
        child: Row(
          children: [
            InkWell(
              onTap: onBack,
              borderRadius: BorderRadius.circular(12),
              child: const SizedBox(
                width: 56,
                height: 60,
                child: Center(child: Icon(CupertinoIcons.chevron_back)),
              ),
            ),
            Expanded(
              child: InkWell(
                onTap: onProfileTap,
                borderRadius: BorderRadius.circular(14),
                child: Row(
                  children: [
                    GhostAvatar(
                      avatarUrl: room.avatarUrl,
                      fallbackText: fallback,
                      fallbackIcon: room.isChannel
                          ? CupertinoIcons.antenna_radiowaves_left_right
                          : CupertinoIcons.person_3_fill,
                      size: 32,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          MarqueeText(
                            text: room.title,
                            style: TextStyle(
                              color: GE.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              shadows: const [
                                Shadow(color: Color(0xCC000000), blurRadius: 5),
                              ],
                            ),
                          ),
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: GE.sub,
                              fontSize: 11,
                              shadows: const [
                                Shadow(color: Color(0xCC000000), blurRadius: 5),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (canManage)
              IconButton(
                tooltip: 'Добавить участника',
                onPressed: onAddMember,
                icon: const Icon(CupertinoIcons.person_add),
              ),
            IconButton(
              tooltip: 'Обновить',
              onPressed: refreshEnabled ? onRefresh : null,
              icon: const Icon(CupertinoIcons.refresh),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomMessageBubble extends StatelessWidget {
  final RoomMessage message;
  final RoomSummary room;
  final String? myUsername;
  final bool prevSame;
  final bool showAuthor;
  final bool showAvatar;

  const _RoomMessageBubble({
    required this.message,
    required this.room,
    required this.myUsername,
    required this.prevSame,
    required this.showAuthor,
    required this.showAvatar,
  });

  @override
  Widget build(BuildContext context) {
    final mine = message.senderUsername == myUsername;
    final textColor = mine ? Colors.white : GE.text;
    final avatarLabel = message.senderDisplayName.isNotEmpty
        ? message.senderDisplayName
        : message.senderUsername;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showAuthor && !mine && message.senderUsername.isNotEmpty)
          Text(
            '@${message.senderUsername}',
            style: TextStyle(
              color: mine ? Colors.white : GE.primary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        if (message.senderDisplayName.isNotEmpty &&
            message.senderDisplayName != message.senderUsername &&
            !mine)
          Text(
            message.senderDisplayName,
            style: TextStyle(
              color: textColor.withValues(alpha: 0.72),
              fontSize: 11,
            ),
          ),
        if (message.forwardedFrom != null &&
            message.forwardedFrom!.isNotEmpty) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.share,
                size: 11,
                color: textColor.withValues(alpha: 0.65),
              ),
              const SizedBox(width: 4),
              Text(
                '@${message.forwardedFrom}',
                style: TextStyle(
                  color: textColor.withValues(alpha: 0.75),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
        ],
        if (message.attachment != null)
          _RoomAttachmentTile(room: room, attachment: message.attachment!),
        if (message.text.isNotEmpty)
          EmojiText(
            message.text,
            style: TextStyle(color: textColor, fontSize: 15, height: 1.35),
          ),
        const SizedBox(height: 2),
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatRoomTime(message.createdAt),
                style: TextStyle(
                  color: textColor.withValues(alpha: 0.65),
                  fontSize: 10,
                ),
              ),
              if (message.pending) ...[
                const SizedBox(width: 4),
                Icon(
                  CupertinoIcons.clock,
                  size: 11,
                  color: textColor.withValues(alpha: 0.65),
                ),
              ],
              if (message.sendFailed) ...[
                const SizedBox(width: 4),
                Icon(
                  CupertinoIcons.exclamationmark_circle,
                  size: 11,
                  color: GE.red,
                ),
              ],
            ],
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        const avatarSize = 30.0;
        const avatarGap = 8.0;
        final rowWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width - 24;
        final maxBubbleWidth =
            (rowWidth - (showAvatar ? avatarSize + avatarGap : 0))
                .clamp(1.0, 600.0)
                .toDouble();
        final bubble = Flexible(
          child: Align(
            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxBubbleWidth),
              child: Container(
                margin: EdgeInsets.only(top: prevSame ? 1 : 5, bottom: 1),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  gradient: mine
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [GE.primary2, GE.primary],
                        )
                      : null,
                  color: mine ? null : GE.surface,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(mine ? 16 : 6),
                    bottomRight: Radius.circular(mine ? 6 : 16),
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: mine ? 0.16 : 0.07),
                    width: 0.7,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: IntrinsicWidth(child: content),
              ),
            ),
          ),
        );
        final avatar = Padding(
          padding: EdgeInsets.only(top: prevSame ? 1 : 5),
          child: GhostAvatar(
            avatarUrl: message.senderAvatarUrl,
            fallbackText: avatarLabel,
            size: avatarSize,
            fallbackColors: mine
                ? [GE.primary2, GE.primary]
                : [GE.surface, GE.primary2],
          ),
        );
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: showAvatar
                ? (mine
                      ? [bubble, const SizedBox(width: avatarGap), avatar]
                      : [avatar, const SizedBox(width: avatarGap), bubble])
                : [bubble],
          ),
        );
      },
    );
  }
}

class _RoomAttachmentTile extends StatefulWidget {
  final RoomSummary room;
  final Map<String, dynamic> attachment;

  const _RoomAttachmentTile({required this.room, required this.attachment});

  @override
  State<_RoomAttachmentTile> createState() => _RoomAttachmentTileState();
}

class _RoomAttachmentTileState extends State<_RoomAttachmentTile> {
  bool _busy = false;
  bool _expired = false;

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await RoomService.instance.downloadAttachment(
        widget.room,
        widget.attachment,
      );
      final directory = await getTemporaryDirectory();
      final rawName = widget.attachment['file_name']?.toString() ?? 'file';
      final safeName = rawName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final file = File(
        '${directory.path}${Platform.pathSeparator}ghost_room_$safeName',
      );
      await file.writeAsBytes(bytes, flush: true);
      await OpenFilex.open(
        file.path,
        type: widget.attachment['mime']?.toString(),
      );
    } catch (error) {
      if (mounted) {
        if (error.toString().contains('удал') ||
            error.toString().contains('срок')) {
          setState(() => _expired = true);
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Вложение недоступно: $error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.attachment['file_name']?.toString() ?? 'Файл';
    final mime = widget.attachment['mime']?.toString() ?? '';
    final size = widget.attachment['size'];
    final title = _expired ? 'Тут был файл, но он удален' : name;
    final sizeText = size is num
        ? size >= 1024 * 1024
              ? '${(size / (1024 * 1024)).toStringAsFixed(1)} МБ'
              : '${(size / 1024).ceil()} КБ'
        : '';
    final icon = _expired
        ? CupertinoIcons.trash
        : mime.startsWith('image/')
        ? CupertinoIcons.photo
        : mime.startsWith('video/')
        ? CupertinoIcons.play_rectangle
        : mime.startsWith('audio/')
        ? CupertinoIcons.waveform
        : CupertinoIcons.doc;
    return InkWell(
      onTap: _open,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 5),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: GE.primary, size: 24),
            const SizedBox(width: 9),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (sizeText.isNotEmpty)
                    Text(
                      sizeText,
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _expired
                ? Icon(CupertinoIcons.xmark_circle, color: GE.sub)
                : _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(CupertinoIcons.arrow_down_circle, color: GE.primary),
          ],
        ),
      ),
    );
  }
}

String _formatRoomTime(int seconds) {
  final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  final hh = date.hour.toString().padLeft(2, '0');
  final mm = date.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

class _ForwardTargetTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final String? avatarUrl;
  final String? fallbackText;
  final VoidCallback onTap;

  const _ForwardTargetTile({
    required this.label,
    required this.icon,
    this.avatarUrl,
    this.fallbackText,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            GhostAvatar(
              avatarUrl: avatarUrl,
              fallbackText: fallbackText ?? label,
              fallbackIcon: icon,
              size: 32,
              fallbackColors: [GE.primary2, GE.primary],
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: GE.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomPinnedBar extends StatelessWidget {
  final RoomPinnedMessage pin;
  final int count;
  final VoidCallback onTap;

  const _RoomPinnedBar({
    required this.pin,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = pin.text.isEmpty ? 'Закреплённое сообщение' : pin.text;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        decoration: BoxDecoration(
          color: GE.bgDeep.withValues(alpha: 0.68),
          border: Border(
            bottom: BorderSide(color: GE.primary.withValues(alpha: 0.16)),
          ),
        ),
        child: Row(
          children: [
            Icon(CupertinoIcons.pin_fill, color: GE.primary, size: 17),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    count > 1
                        ? 'Закреплено сообщений: $count'
                        : 'Закреплённое сообщение',
                    style: TextStyle(
                      color: GE.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.text, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            Icon(CupertinoIcons.chevron_right, color: GE.sub, size: 16),
          ],
        ),
      ),
    );
  }
}

class _RoomPinnedSheet extends StatelessWidget {
  final List<RoomPinnedMessage> pins;
  final ValueChanged<int> onTap;

  const _RoomPinnedSheet({required this.pins, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: GE.bgDeep,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: GE.border.withValues(alpha: 0.8)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: GE.sub.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Закреплённые сообщения',
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(CupertinoIcons.xmark),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
                  itemCount: pins.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 7),
                  itemBuilder: (context, index) {
                    final pin = pins[index];
                    final author = pin.senderDisplayName.isNotEmpty
                        ? pin.senderDisplayName
                        : '@${pin.senderUsername}';
                    return GlassCard(
                      lite: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: InkWell(
                        onTap: () => onTap(pin.messageId),
                        borderRadius: BorderRadius.circular(GE.radiusMd),
                        child: Row(
                          children: [
                            Icon(
                              CupertinoIcons.pin_fill,
                              color: GE.primary,
                              size: 17,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    author,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: GE.primary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    pin.text.isEmpty
                                        ? 'Сообщение доступно после расшифровки'
                                        : pin.text,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: GE.text,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              CupertinoIcons.chevron_right,
                              color: GE.sub,
                              size: 16,
                            ),
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
      ),
    );
  }
}

class _RoomDraft {
  final String type;
  final String username;
  final String title;
  final String about;
  final String visibility;
  final String historyMode;

  const _RoomDraft({
    required this.type,
    required this.username,
    required this.title,
    required this.about,
    required this.visibility,
    required this.historyMode,
  });
}

class _JoinDraft {
  final String type;
  final String value;
  const _JoinDraft({required this.type, required this.value});
}
