import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../mesh_background.dart';
import '../services/room_service.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/glass.dart';
import '../widgets/profile_banner.dart';
import '../widgets/toast_overlay.dart';

/// Full-screen room editor. It deliberately follows the profile editor flow:
/// the banner and the existing avatar are edited in the same preview, while
/// identity/access fields stay below it.
class RoomEditScreen extends StatefulWidget {
  final RoomSummary room;

  const RoomEditScreen({super.key, required this.room});

  @override
  State<RoomEditScreen> createState() => _RoomEditScreenState();
}

class _RoomEditScreenState extends State<RoomEditScreen> {
  final _service = RoomService.instance;
  late RoomSummary _room;
  late final TextEditingController _username;
  late final TextEditingController _title;
  late final TextEditingController _about;
  late final TextEditingController _rules;
  late final TextEditingController _board;
  late final TextEditingController _joinPassword;
  late String _visibility;
  late String _historyMode;
  late String _joinMode;
  late Set<String> _previewFields;
  late bool _showPinnedPreview;
  bool _saving = false;
  bool _avatarBusy = false;

  bool get _canChangeAvatar =>
      (_room.isGroup || _room.isChannel) && _room.role == 'owner';

  @override
  void initState() {
    super.initState();
    _room = widget.room;
    _username = TextEditingController(text: _room.username ?? '');
    _title = TextEditingController(text: _room.title);
    _about = TextEditingController(text: _room.about);
    _rules = TextEditingController(text: _room.rules);
    _board = TextEditingController(text: _room.boardText);
    _joinPassword = TextEditingController();
    _visibility = _room.visibility;
    _historyMode = _room.historyMode;
    _joinMode = _room.joinMode;
    _previewFields = Set.of(_room.previewFields);
    _showPinnedPreview = _room.showPinnedPreview;
  }

  @override
  void dispose() {
    _username.dispose();
    _title.dispose();
    _about.dispose();
    _rules.dispose();
    _board.dispose();
    _joinPassword.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final username = _username.text.trim().replaceFirst('@', '');
    final title = _title.text.trim();
    if (_room.role == 'owner' && username.length < 3) {
      toast.show('Username должен быть не короче 3 символов');
      return;
    }
    if (title.length < 2) {
      toast.show('Название должно быть не короче 2 символов');
      return;
    }
    if (_visibility == 'private' && _joinMode == 'password') {
      final password = _joinPassword.text;
      if (password.isNotEmpty && password.length < 8) {
        toast.show('Пароль комнаты должен содержать минимум 8 символов');
        return;
      }
      if (!_room.hasJoinPassword && password.isEmpty) {
        toast.show('Задайте пароль для входа в комнату');
        return;
      }
    }
    setState(() => _saving = true);
    try {
      final updated = await _service.updateRoom(
        _room,
        username: _room.role == 'owner' ? username : null,
        title: title,
        about: _about.text.trim(),
        visibility: _visibility,
        historyMode: _historyMode,
        rules: _rules.text.trim(),
        boardText: _board.text.trim(),
        previewFields: _previewFields,
        showPinnedPreview: _room.role == 'owner' ? _showPinnedPreview : null,
        joinMode: _joinMode,
        joinPassword:
            _visibility == 'private' &&
                _joinMode == 'password' &&
                _joinPassword.text.isNotEmpty
            ? _joinPassword.text
            : null,
      );
      if (!mounted) return;
      setState(() {
        _room = updated;
        _saving = false;
        _joinPassword.clear();
      });
      toast.show('Сохранено');
      Navigator.of(context).pop(updated);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast.show('Не удалось сохранить: $error');
    }
  }

  Future<void> _changeType() async {
    if (_saving || !_room.canManage) return;
    final target = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: const Text('Тип комнаты'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              value: 'channel',
              groupValue: _room.roomType,
              title: const Text('Канал'),
              subtitle: const Text('Публикации от владельца и админов'),
              onChanged: (value) => Navigator.pop(dialogContext, value),
            ),
            RadioListTile<String>(
              value: 'group',
              groupValue: _room.roomType,
              title: const Text('Группа'),
              subtitle: const Text('Общий чат участников'),
              onChanged: (value) => Navigator.pop(dialogContext, value),
            ),
          ],
        ),
      ),
    );
    if (target == null || target == _room.roomType || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: const Text('Изменить тип?'),
        content: const Text(
          'Участники, сообщения и ссылки будут перенесены. Старый тип станет недоступен.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Изменить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final updated = await _service.convertRoom(_room, target);
      if (!mounted) return;
      setState(() {
        _room = updated;
        _saving = false;
      });
      toast.show(
        target == 'channel' ? 'Теперь это канал' : 'Теперь это группа',
      );
      Navigator.of(context).pop(updated);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast.show('Не удалось изменить тип: $error');
    }
  }

  Future<void> _editBanner() async {
    if (_saving) return;
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
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast.show('Не удалось сохранить баннер: $error');
    }
  }

  Future<void> _pickAvatar() async {
    if (!_canChangeAvatar || _saving || _avatarBusy) return;
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

  @override
  Widget build(BuildContext context) {
    final fallback = _room.isGroup && _room.title.isNotEmpty
        ? _room.title[0].toUpperCase()
        : '#';
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          leading: IconButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            icon: const Icon(CupertinoIcons.chevron_back),
          ),
          titleText: _room.isChannel ? 'Редакция канала' : 'Редакция группы',
          actions: [
            TextButton(
              onPressed: _saving ? null : _save,
              child: const Text('Готово'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
          children: [
            GlassCard(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 18),
              child: Column(
                children: [
                  ProfileBannerHeader(
                    banner: _room.banner,
                    avatar: GestureDetector(
                      onTap: _canChangeAvatar ? _pickAvatar : null,
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          GhostAvatar(
                            avatarUrl: _room.avatarUrl,
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
                                          color: GE.text,
                                        ),
                                      )
                                    : const Icon(
                                        CupertinoIcons.camera_fill,
                                        color: GE.text,
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
                          _title.text,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '@${_username.text}',
                          style: TextStyle(color: GE.primary, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: _saving ? null : _editBanner,
                    icon: const Icon(CupertinoIcons.paintbrush),
                    label: Text(
                      _room.banner == null
                          ? 'Добавить баннер'
                          : 'Изменить баннер',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlassCard(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: Column(
                children: [
                  TextField(
                    controller: _title,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Название'),
                  ),
                  if (_room.role == 'owner')
                    TextField(
                      controller: _username,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        prefixText: '@',
                      ),
                    ),
                  TextField(
                    controller: _about,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'Описание'),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _visibility,
                    decoration: const InputDecoration(labelText: 'Доступ'),
                    items: const [
                      DropdownMenuItem(
                        value: 'public',
                        child: Text('Публичная'),
                      ),
                      DropdownMenuItem(
                        value: 'private',
                        child: Text('Приватная'),
                      ),
                    ],
                    onChanged: _room.isChannel
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() {
                                if (value == 'public') {
                                  _joinMode = 'open';
                                } else if (_visibility == 'public') {
                                  _joinMode = 'request';
                                }
                                _visibility = value;
                              });
                            }
                          },
                  ),
                  if (_room.isChannel)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 8),
                        child: Text(
                          'Тип доступа канала нельзя изменить после создания.',
                          style: TextStyle(color: GE.sub, fontSize: 12),
                        ),
                      ),
                    ),
                  DropdownButtonFormField<String>(
                    initialValue: _historyMode,
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
                      if (value != null) setState(() => _historyMode = value);
                    },
                  ),
                  if (_visibility == 'private') ...[
                    DropdownButtonFormField<String>(
                      initialValue: _joinMode,
                      decoration: const InputDecoration(
                        labelText: 'Как вступают в комнату',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'open',
                          child: Text('Вступить сразу'),
                        ),
                        DropdownMenuItem(
                          value: 'request',
                          child: Text('Сначала заявка'),
                        ),
                        DropdownMenuItem(
                          value: 'password',
                          child: Text('По паролю'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _joinMode = value);
                      },
                    ),
                    if (_joinMode == 'password')
                      TextField(
                        controller: _joinPassword,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        maxLength: 128,
                        decoration: InputDecoration(
                          labelText: _room.hasJoinPassword
                              ? 'Новый пароль комнаты'
                              : 'Пароль комнаты',
                          helperText: _room.hasJoinPassword
                              ? 'Оставьте пустым, чтобы не менять пароль'
                              : 'Не менее 8 символов',
                        ),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            GlassCard(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: TextField(
                controller: _rules,
                maxLength: 2000,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Правила комнаты',
                  helperText:
                      'Для приватной комнаты видимость настраивается ниже.',
                ),
              ),
            ),
            const SizedBox(height: 12),
            GlassCard(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _board,
                    maxLength: 2000,
                    minLines: 3,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      labelText: 'Доска комнаты',
                      helperText:
                          'Необязательная текстовая витрина, видимая всем.',
                    ),
                  ),
                  Text(
                    'Если оставить поле пустым, доски у комнаты не будет.',
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (_visibility == 'private') ...[
              const SizedBox(height: 12),
              GlassCard(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Что видно до вступления',
                      style: TextStyle(
                        color: GE.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Доска комнаты остаётся видимой всегда. Эти переключатели управляют остальными полями профиля.',
                      style: TextStyle(
                        color: GE.sub,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    for (final field in const <(String, String)>[
                      ('about', 'Описание'),
                      ('avatar', 'Аватар'),
                      ('banner', 'Баннер'),
                      ('members_count', 'Количество участников'),
                      ('history', 'Режим истории'),
                      ('rules', 'Правила'),
                      ('username', 'Username комнаты'),
                    ])
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(field.$2),
                        value: _previewFields.contains(field.$1),
                        onChanged: _saving
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  _previewFields.add(field.$1);
                                } else {
                                  _previewFields.remove(field.$1);
                                }
                              }),
                      ),
                    if (_room.role == 'owner')
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('Показывать закрепы до вступления'),
                        subtitle: const Text(
                          'Текст приватных закрепов станет виден всем. Чтобы открыть текст уже закреплённых сообщений, закрепите их повторно после включения.',
                        ),
                        value: _showPinnedPreview,
                        onChanged: _saving
                            ? null
                            : (value) => setState(
                                () => _showPinnedPreview = value ?? false,
                              ),
                      ),
                  ],
                ),
              ),
            ],
            if (_room.role == 'owner') ...[
              const SizedBox(height: 12),
              GlassCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _room.isChannel
                        ? CupertinoIcons.person_3_fill
                        : CupertinoIcons.antenna_radiowaves_left_right,
                    color: GE.primary,
                  ),
                  title: const Text('Тип комнаты'),
                  subtitle: Text(
                    _room.isChannel ? 'Канал' : 'Группа',
                    style: TextStyle(color: GE.sub),
                  ),
                  trailing: const Icon(CupertinoIcons.chevron_right),
                  onTap: _saving ? null : _changeType,
                ),
              ),
            ],
            if (_saving)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        ),
      ),
    );
  }
}
