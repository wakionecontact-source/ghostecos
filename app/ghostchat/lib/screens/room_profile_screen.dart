import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../mesh_background.dart';
import '../services/room_service.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/glass.dart';
import '../widgets/profile_banner.dart';
import '../widgets/toast_overlay.dart';
import 'room_edit_screen.dart';

class RoomProfileScreen extends StatefulWidget {
  final RoomSummary room;

  const RoomProfileScreen({super.key, required this.room});

  @override
  State<RoomProfileScreen> createState() => _RoomProfileScreenState();
}

class _RoomProfileScreenState extends State<RoomProfileScreen> {
  final _service = RoomService.instance;
  late RoomSummary _room;
  bool _loading = true;
  bool _saving = false;
  bool _avatarBusy = false;
  bool _linkBusy = false;
  bool _requestsBusy = false;
  RoomInviteLink? _inviteLink;
  int _pendingRequests = 0;
  String? _error;

  bool get _isOwner => _room.role == 'owner';
  bool get _canManage => _room.canManage;
  bool get _canChangeAvatar => (_room.isGroup || _room.isChannel) && _isOwner;
  bool _canShowPreviewField(String field) =>
      _room.isPublic ||
      _room.role != null ||
      _room.previewFields.contains(field);

  @override
  void initState() {
    super.initState();
    _room = widget.room;
    _loadRoom();
  }

  Future<void> _loadRoom() async {
    try {
      final fresh = await _service.loadRoom(_room);
      if (!mounted) return;
      setState(() {
        _room = fresh;
        _loading = false;
        _error = null;
      });
      if (fresh.isPrivate && fresh.canManage) {
        try {
          final links = await _service.listInviteLinks(fresh);
          if (mounted && links.isNotEmpty) {
            setState(
              () => _inviteLink = links.firstWhere(
                (link) => link.link.isNotEmpty,
              ),
            );
          }
        } catch (_) {
          // The profile itself remains usable when invite links are unavailable.
        }
      }
      if (fresh.canManage) {
        try {
          final requests = await _service.loadJoinRequests(fresh);
          if (mounted) setState(() => _pendingRequests = requests.length);
        } catch (_) {
          // Moderation data is optional; do not make the profile unusable.
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _pickAvatar() async {
    if (!_canChangeAvatar || _avatarBusy) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 90,
    );
    if (picked == null || !mounted) return;

    setState(() => _avatarBusy = true);
    try {
      final updated = await _service.uploadRoomAvatar(
        _room,
        bytes: await picked.readAsBytes(),
        filename: picked.name.isEmpty ? 'avatar.jpg' : picked.name,
        mime: _mimeFor(picked.name),
      );
      if (!mounted) return;
      setState(() {
        _room = updated;
        _avatarBusy = false;
      });
      toast.show('Аватарка обновлена');
    } catch (error) {
      if (!mounted) return;
      setState(() => _avatarBusy = false);
      toast.show('Не удалось загрузить аватарку: $error');
    }
  }

  String _mimeFor(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  String? get _publicRoomLink {
    final username = _room.username?.trim();
    if (!_room.isPublic) return null;
    if (_room.isChannel) {
      if (username == null || username.isEmpty) return null;
      return '${GE.baseUrl}/c/$username';
    }
    // Keep group links compatible with legacy groups that were shared by id.
    // The v2 public preview accepts both ids and usernames during migration.
    final groupRef = _room.id > 0 ? _room.id.toString() : username;
    if (groupRef == null || groupRef.isEmpty) return null;
    return '${GE.baseUrl}/g/$groupRef';
  }

  String? get _roomLink {
    final publicLink = _publicRoomLink;
    if (publicLink != null) return publicLink;
    final privatePath = _inviteLink?.link;
    if (privatePath == null || privatePath.isEmpty) return null;
    return privatePath.startsWith('http')
        ? privatePath
        : '${GE.baseUrl}$privatePath';
  }

  Future<void> _copyRoomLink() async {
    if (_linkBusy || (!_room.isPublic && !_room.canManage)) return;
    setState(() => _linkBusy = true);
    try {
      if (_roomLink == null && _room.isPrivate) {
        _inviteLink = await _service.createInviteLink(_room);
      }
      final link = _roomLink;
      if (link == null || link.isEmpty) {
        toast.show('Ссылка пока недоступна');
        return;
      }
      await Clipboard.setData(ClipboardData(text: link));
      toast.show('Ссылка скопирована');
    } catch (error) {
      toast.show('Не удалось получить ссылку: $error');
    } finally {
      if (mounted) setState(() => _linkBusy = false);
    }
  }

  Future<void> _openMembers() async {
    if (_loading) return;
    try {
      final members = await _service.loadMembers(_room);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) => FractionallySizedBox(
          heightFactor: 0.78,
          child: _RoomMembersSheet(room: _room, members: members),
        ),
      );
    } catch (error) {
      if (mounted) toast.show('Не удалось загрузить участников: $error');
    }
  }

  Future<void> _openJoinRequests() async {
    if (!_room.canManage || _requestsBusy) return;
    setState(() => _requestsBusy = true);
    try {
      final requests = await _service.loadJoinRequests(_room);
      if (!mounted) return;
      final changed = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (_) => FractionallySizedBox(
          heightFactor: 0.78,
          child: _RoomJoinRequestsSheet(
            room: _room,
            requests: requests,
            onReview: (requestId, accept) async {
              await _service.reviewJoinRequest(
                _room,
                requestId,
                accept: accept,
              );
            },
          ),
        ),
      );
      if (mounted && changed == true) {
        final fresh = await _service.loadRoom(_room);
        setState(() {
          _room = fresh;
          _pendingRequests = 0;
        });
      }
    } catch (error) {
      if (mounted) toast.show('Не удалось загрузить заявки: $error');
    } finally {
      if (mounted) setState(() => _requestsBusy = false);
    }
  }

  Future<void> _openInviteSettings() async {
    if (!_room.canManage || _linkBusy) return;
    final result = await showModalBottomSheet<_InviteSettingsResult>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _InviteSettingsSheet(room: _room, current: _inviteLink),
    );
    if (result == null || !mounted) return;
    setState(() => _linkBusy = true);
    try {
      if (result.revoke) {
        await _service.revokeInviteLinks(_room);
        setState(() => _inviteLink = null);
        toast.show('Приглашения отозваны');
      } else {
        final link = await _service.createInviteLink(
          _room,
          expiresHours: result.expiresHours,
          maxUses: result.maxUses,
          requestJoin: result.requestJoin,
        );
        setState(() => _inviteLink = link);
        await Clipboard.setData(
          ClipboardData(text: '${GE.baseUrl}${link.link}'),
        );
        toast.show('Ссылка создана и скопирована');
      }
    } catch (error) {
      toast.show('Не удалось изменить приглашение: $error');
    } finally {
      if (mounted) setState(() => _linkBusy = false);
    }
  }

  Future<void> _editRoom() async {
    if (!_isOwner || _saving) return;
    final title = TextEditingController(text: _room.title);
    final about = TextEditingController(text: _room.about);
    final username = TextEditingController(text: _room.username ?? '');
    try {
      final values = await showDialog<Map<String, String>>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: GE.bgDeep,
          title: Text(
            _room.isChannel ? 'Редактировать канал' : 'Редактировать группу',
            style: TextStyle(color: GE.text),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: username,
                  style: TextStyle(color: GE.text),
                  decoration: InputDecoration(
                    labelText: _room.isChannel
                        ? 'Username канала'
                        : 'Username группы',
                    prefixText: '@',
                  ),
                ),
                TextField(
                  controller: title,
                  autofocus: false,
                  style: TextStyle(color: GE.text),
                  decoration: const InputDecoration(labelText: 'Название'),
                ),
                TextField(
                  controller: about,
                  minLines: 2,
                  maxLines: 5,
                  style: TextStyle(color: GE.text),
                  decoration: const InputDecoration(labelText: 'Описание'),
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
              onPressed: () => Navigator.pop(dialogContext, {
                'username': username.text.trim().replaceFirst('@', ''),
                'title': title.text.trim(),
                'about': about.text.trim(),
              }),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      );
      if (values == null || !mounted) return;
      if (values['title']!.length < 2) {
        toast.show('Название должно быть не короче 2 символов');
        return;
      }
      if (values['username']!.length < 3) {
        toast.show('Username должен быть не короче 3 символов');
        return;
      }

      setState(() => _saving = true);
      final updated = await _service.updateRoom(
        _room,
        username: values['username'],
        title: values['title'],
        about: values['about'],
      );
      if (!mounted) return;
      setState(() {
        _room = updated;
        _saving = false;
      });
      toast.show('Сохранено');
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast.show('Не удалось сохранить: $error');
    }
  }

  Future<void> _openEditor() async {
    if (!_canManage || _saving) return;
    final updated = await Navigator.of(context).push<RoomSummary>(
      MaterialPageRoute(builder: (_) => RoomEditScreen(room: _room)),
    );
    if (updated != null && mounted) setState(() => _room = updated);
  }

  Future<void> _editBanner() async {
    if (!_canManage || _saving) return;
    final result = await showProfileBannerEditor(
      context,
      initial: _room.banner,
    );
    if (result == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final updated = await _service.updateRoom(
        _room,
        banner: result.clear ? null : result.config!.toJson(),
        clearBanner: result.clear,
      );
      if (!mounted) return;
      setState(() {
        _room = updated;
        _saving = false;
      });
      toast.show(result.clear ? 'Баннер убран' : 'Баннер сохранён');
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast.show('Не удалось сохранить баннер: $error');
    }
  }

  void _close() => Navigator.of(context).pop(_room);

  @override
  Widget build(BuildContext context) {
    final fallback = _room.isChannel
        ? '#'
        : (_room.title.isNotEmpty ? _room.title[0].toUpperCase() : '?');
    final subtitle =
        _canShowPreviewField('username') && _room.username?.isNotEmpty == true
        ? '@${_room.username}'
        : _canShowPreviewField('members_count')
        ? '${_room.membersCount} участников'
        : (_room.isChannel ? 'Канал' : 'Группа');

    return PopScope<RoomSummary>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: MeshBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: GlassAppBar(
            leading: IconButton(
              onPressed: _close,
              icon: const Icon(CupertinoIcons.chevron_back),
            ),
            titleText: _room.isChannel ? 'Профиль канала' : 'Профиль группы',
            actions: [
              if (_canManage)
                IconButton(
                  tooltip: 'Изменить баннер',
                  onPressed: _saving ? null : _editBanner,
                  icon: const Icon(CupertinoIcons.paintbrush),
                ),
              if (_canManage)
                IconButton(
                  tooltip: 'Редактировать',
                  onPressed: _saving ? null : _openEditor,
                  icon: const Icon(CupertinoIcons.pencil),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
            children: [
              ProfileBannerHeader(
                banner: _canShowPreviewField('banner') ? _room.banner : null,
                avatar: GestureDetector(
                  onTap: _canChangeAvatar ? _pickAvatar : null,
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      GhostAvatar(
                        avatarUrl: _canShowPreviewField('avatar')
                            ? _room.avatarUrl
                            : null,
                        fallbackText: fallback,
                        fallbackIcon: _room.isChannel
                            ? CupertinoIcons.antenna_radiowaves_left_right
                            : CupertinoIcons.person_3_fill,
                        size: 104,
                      ),
                      if (_canChangeAvatar)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: GE.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: GE.bgDeep, width: 3),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(7),
                            child: _avatarBusy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    CupertinoIcons.camera_fill,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                          ),
                        ),
                    ],
                  ),
                ),
                avatarSize: 104,
                bannerHeight: 104,
                identity: Column(
                  children: [
                    Text(
                      _room.title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(color: GE.primary, fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Не удалось обновить профиль: $_error',
                    style: TextStyle(color: GE.red, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 20),
              _RoomActionRow(
                room: _room,
                linkBusy: _linkBusy,
                onLink: _copyRoomLink,
                onMembers: _openMembers,
                onManage: _canManage ? _openEditor : null,
              ),
              if (_room.boardText.trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                GlassCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Доска комнаты',
                        style: TextStyle(
                          color: GE.text,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _room.boardText,
                        style: TextStyle(color: GE.text, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (_room.isPublic || _room.canManage)
                GlassCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 13,
                  ),
                  child: InkWell(
                    onTap: _linkBusy
                        ? null
                        : (_room.isPrivate && _room.canManage
                              ? _openInviteSettings
                              : _copyRoomLink),
                    borderRadius: BorderRadius.circular(GE.radiusMd),
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.link, color: GE.primary, size: 21),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Ссылка на ${_room.isChannel ? 'канал' : 'группу'}',
                                style: TextStyle(color: GE.text, fontSize: 14),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _roomLink ?? 'Создать ссылку-приглашение',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: GE.sub, fontSize: 12),
                              ),
                              if (_room.isPrivate && _room.canManage) ...[
                                const SizedBox(height: 3),
                                Text(
                                  _inviteLink?.requestJoin == true
                                      ? 'Сначала заявка на вступление'
                                      : 'Нажмите, чтобы настроить ссылку',
                                  style: TextStyle(
                                    color: GE.primary.withValues(alpha: 0.8),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        _linkBusy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                CupertinoIcons.doc_on_clipboard,
                                color: GE.sub,
                              ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              if (_room.canManage) ...[
                GlassCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      CupertinoIcons.person_badge_plus,
                      color: GE.primary,
                    ),
                    title: const Text('Заявки на вступление'),
                    subtitle: Text(
                      _pendingRequests == 0
                          ? 'Новых заявок нет'
                          : 'Ожидают решения: $_pendingRequests',
                      style: TextStyle(color: GE.sub, fontSize: 12),
                    ),
                    trailing: _requestsBusy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(CupertinoIcons.chevron_right),
                    onTap: _requestsBusy ? null : _openJoinRequests,
                  ),
                ),
                const SizedBox(height: 16),
              ],
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    if (_canShowPreviewField('members_count'))
                      _RoomProfileRow(
                        icon: CupertinoIcons.person_2,
                        label: 'Участники',
                        value: '${_room.membersCount}',
                      ),
                    _RoomProfileRow(
                      icon: _room.isPublic
                          ? CupertinoIcons.globe
                          : CupertinoIcons.lock,
                      label: 'Доступ',
                      value: _room.isPublic ? 'Публичная' : 'Приватная',
                    ),
                    if (_canShowPreviewField('history'))
                      _RoomProfileRow(
                        icon: CupertinoIcons.clock,
                        label: 'История',
                        value: _room.historyMode == 'all'
                            ? 'Вся история'
                            : 'Только новые сообщения',
                      ),
                  ],
                ),
              ),
              if (_canShowPreviewField('about') && _room.about.isNotEmpty) ...[
                const SizedBox(height: 16),
                GlassCard(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _room.about,
                    style: TextStyle(color: GE.text, height: 1.4),
                  ),
                ),
              ],
              if (_canShowPreviewField('rules') &&
                  _room.rules.trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                GlassCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Правила комнаты',
                        style: TextStyle(
                          color: GE.text,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _room.rules,
                        style: TextStyle(color: GE.text, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
              if (_isOwner) ...[
                const SizedBox(height: 16),
                GlassButton(
                  label: _saving ? 'Сохраняю…' : 'Редактировать',
                  icon: CupertinoIcons.pencil,
                  primary: true,
                  fullWidth: true,
                  onTap: _saving ? null : _editRoom,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomProfileRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _RoomProfileRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
    child: Row(
      children: [
        Icon(icon, color: GE.primary, size: 20),
        const SizedBox(width: 14),
        Expanded(
          child: Text(label, style: TextStyle(color: GE.sub, fontSize: 13)),
        ),
        Text(
          value,
          style: TextStyle(
            color: GE.text,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _RoomActionRow extends StatelessWidget {
  final RoomSummary room;
  final bool linkBusy;
  final VoidCallback onLink;
  final VoidCallback onMembers;
  final VoidCallback? onManage;

  const _RoomActionRow({
    required this.room,
    required this.linkBusy,
    required this.onLink,
    required this.onMembers,
    required this.onManage,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _RoomAction(
          icon: CupertinoIcons.link,
          label: linkBusy ? '...' : 'Ссылка',
          onTap: onLink,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _RoomAction(
          icon: CupertinoIcons.person_2,
          label: 'Участники',
          onTap: onMembers,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _RoomAction(
          icon: CupertinoIcons.slider_horizontal_3,
          label: 'Управление',
          onTap: onManage,
        ),
      ),
    ],
  );
}

class _RoomAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _RoomAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GlassCard(
    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(GE.radiusMd),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: onTap == null ? GE.sub : GE.primary, size: 20),
          const SizedBox(height: 5),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: GE.text, fontSize: 11),
          ),
        ],
      ),
    ),
  );
}

class _RoomMembersSheet extends StatelessWidget {
  final RoomSummary room;
  final List<Map<String, dynamic>> members;

  const _RoomMembersSheet({required this.room, required this.members});

  String _text(Map<String, dynamic> member, String key) =>
      member[key]?.toString().trim() ?? '';

  String _roleLabel(String role) => switch (role) {
    'owner' => 'Владелец',
    'admin' => 'Администратор',
    _ => 'Участник',
  };

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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Участники',
                            style: TextStyle(
                              color: GE.text,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${members.length} · ${room.isChannel ? 'подписчиков' : 'участников'}',
                            style: TextStyle(color: GE.sub, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(CupertinoIcons.xmark),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: members.isEmpty
                    ? Center(
                        child: Text(
                          'Участники пока не отображаются',
                          style: TextStyle(color: GE.sub),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                        itemCount: members.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 4),
                        itemBuilder: (context, index) {
                          final member = members[index];
                          final username = _text(member, 'username');
                          final displayName = _text(member, 'display_name');
                          final name = displayName.isNotEmpty
                              ? displayName
                              : (username.isNotEmpty
                                    ? '@$username'
                                    : 'Пользователь');
                          final role = _text(member, 'role');
                          return GlassCard(
                            lite: true,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 9,
                            ),
                            child: Row(
                              children: [
                                GhostAvatar(
                                  avatarUrl: null,
                                  fallbackText: name,
                                  fallbackIcon: CupertinoIcons.person_fill,
                                  size: 42,
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: GE.text,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (username.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          '@$username',
                                          style: TextStyle(
                                            color: GE.sub,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                if (role.isNotEmpty)
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: role == 'owner'
                                          ? GE.primary.withValues(alpha: 0.18)
                                          : GE.surface.withValues(alpha: 0.8),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 5,
                                      ),
                                      child: Text(
                                        _roleLabel(role),
                                        style: TextStyle(
                                          color: role == 'owner'
                                              ? GE.primary
                                              : GE.sub,
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
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

class _RoomJoinRequestsSheet extends StatefulWidget {
  final RoomSummary room;
  final List<Map<String, dynamic>> requests;
  final Future<void> Function(int requestId, bool accept) onReview;

  const _RoomJoinRequestsSheet({
    required this.room,
    required this.requests,
    required this.onReview,
  });

  @override
  State<_RoomJoinRequestsSheet> createState() => _RoomJoinRequestsSheetState();
}

class _RoomJoinRequestsSheetState extends State<_RoomJoinRequestsSheet> {
  late final List<Map<String, dynamic>> _requests = [...widget.requests];
  final Set<int> _busy = {};
  bool _changed = false;

  String _value(Map<String, dynamic> item, String key) =>
      item[key]?.toString().trim() ?? '';

  Future<void> _review(int requestId, bool accept) async {
    if (_busy.contains(requestId)) return;
    setState(() => _busy.add(requestId));
    try {
      await widget.onReview(requestId, accept);
      if (!mounted) return;
      setState(() {
        _requests.removeWhere((item) {
          final raw = item['id'];
          final id = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 0;
          return id == requestId;
        });
        _busy.remove(requestId);
        _changed = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy.remove(requestId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось обработать заявку: $error')),
      );
    }
  }

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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Заявки на вступление',
                            style: TextStyle(
                              color: GE.text,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${_requests.length} ожидают решения',
                            style: TextStyle(color: GE.sub, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(_changed),
                      icon: const Icon(CupertinoIcons.xmark),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _requests.isEmpty
                    ? Center(
                        child: Text(
                          'Новых заявок нет',
                          style: TextStyle(color: GE.sub),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                        itemCount: _requests.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final item = _requests[index];
                          final rawId = item['id'];
                          final id = rawId is num
                              ? rawId.toInt()
                              : int.tryParse('$rawId') ?? 0;
                          final username = _value(item, 'username');
                          final name = _value(item, 'display_name');
                          final title = name.isNotEmpty
                              ? name
                              : (username.isNotEmpty
                                    ? '@$username'
                                    : 'Пользователь');
                          final busy = _busy.contains(id);
                          return GlassCard(
                            lite: true,
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                GhostAvatar(
                                  avatarUrl: item['avatar_url']?.toString(),
                                  fallbackText: title,
                                  fallbackIcon: CupertinoIcons.person_fill,
                                  size: 44,
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: GE.text,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (username.isNotEmpty)
                                        Text(
                                          '@$username',
                                          style: TextStyle(
                                            color: GE.sub,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (busy)
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                else ...[
                                  IconButton(
                                    tooltip: 'Отклонить',
                                    onPressed: id <= 0
                                        ? null
                                        : () => _review(id, false),
                                    icon: Icon(
                                      CupertinoIcons.xmark_circle,
                                      color: GE.red,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Принять',
                                    onPressed: id <= 0
                                        ? null
                                        : () => _review(id, true),
                                    icon: Icon(
                                      CupertinoIcons.checkmark_circle_fill,
                                      color: GE.primary,
                                    ),
                                  ),
                                ],
                              ],
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

class _InviteSettingsResult {
  final bool revoke;
  final bool requestJoin;
  final int? expiresHours;
  final int? maxUses;

  const _InviteSettingsResult({
    this.revoke = false,
    this.requestJoin = false,
    this.expiresHours,
    this.maxUses,
  });
}

class _InviteSettingsSheet extends StatefulWidget {
  final RoomSummary room;
  final RoomInviteLink? current;

  const _InviteSettingsSheet({required this.room, required this.current});

  @override
  State<_InviteSettingsSheet> createState() => _InviteSettingsSheetState();
}

class _InviteSettingsSheetState extends State<_InviteSettingsSheet> {
  late bool _requestJoin = widget.current?.requestJoin ?? false;
  String _expiration = '3';
  String _uses = 'unlimited';

  int? get _expiresHours => switch (_expiration) {
    '1' => 1,
    '24' => 24,
    '72' => 72,
    '168' => 168,
    _ => null,
  };

  int? get _maxUses => switch (_uses) {
    '1' => 1,
    '10' => 10,
    '100' => 100,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final current = widget.current;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          18,
          16,
          18,
          18 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        decoration: BoxDecoration(
          color: GE.bgDeep,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: GE.border.withValues(alpha: 0.8)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: GE.sub.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Настройки приглашения',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              if (current != null)
                Text(
                  current.permanent
                      ? 'Публичная ссылка действует постоянно.'
                      : 'Новая ссылка автоматически отменит предыдущую.',
                  style: TextStyle(color: GE.sub, fontSize: 12.5),
                ),
              if (!widget.room.isPublic) ...[
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _requestJoin,
                  onChanged: (value) => setState(() => _requestJoin = value),
                  title: const Text('Сначала заявка на вступление'),
                  subtitle: const Text(
                    'Участник попадёт в комнату после одобрения',
                  ),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _expiration,
                  decoration: const InputDecoration(labelText: 'Срок действия'),
                  items: const [
                    DropdownMenuItem(value: '1', child: Text('1 час')),
                    DropdownMenuItem(value: '24', child: Text('24 часа')),
                    DropdownMenuItem(value: '72', child: Text('3 дня')),
                    DropdownMenuItem(value: '168', child: Text('7 дней')),
                    DropdownMenuItem(value: 'never', child: Text('Бессрочно')),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _expiration = value);
                  },
                ),
                DropdownButtonFormField<String>(
                  initialValue: _uses,
                  decoration: const InputDecoration(
                    labelText: 'Лимит использований',
                  ),
                  items: const [
                    DropdownMenuItem(value: '1', child: Text('1 раз')),
                    DropdownMenuItem(value: '10', child: Text('10 раз')),
                    DropdownMenuItem(value: '100', child: Text('100 раз')),
                    DropdownMenuItem(
                      value: 'unlimited',
                      child: Text('Без лимита'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _uses = value);
                  },
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  if (current != null && !current.permanent)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(
                          context,
                          const _InviteSettingsResult(revoke: true),
                        ),
                        icon: const Icon(CupertinoIcons.trash),
                        label: const Text('Отозвать'),
                      ),
                    ),
                  if (current != null && !current.permanent)
                    const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(
                        context,
                        _InviteSettingsResult(
                          requestJoin: _requestJoin,
                          expiresHours: _expiresHours,
                          maxUses: _maxUses,
                        ),
                      ),
                      icon: const Icon(CupertinoIcons.link),
                      label: Text(
                        current == null ? 'Создать' : 'Перевыпустить',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
