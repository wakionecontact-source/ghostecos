import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/channel_service.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/glass.dart';

class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({super.key});

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  final _service = ChannelService.instance;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _service.loadMy();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _create() async {
    final draft = await _showCreateDialog();
    if (draft == null || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _service.create(
        username: draft.username,
        title: draft.title,
        about: draft.about,
        visibility: draft.visibility,
        historyMode: draft.historyMode,
      );
      if (!mounted) return;
      setState(() => _loading = false);
      _message('Канал создан');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _join() async {
    final username = await _showJoinDialog();
    if (username == null || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _service.join(username);
      if (!mounted) return;
      setState(() => _loading = false);
      _message('Вы вступили в канал');
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

  Future<_ChannelDraft?> _showCreateDialog() async {
    final username = TextEditingController();
    final title = TextEditingController();
    final about = TextEditingController();
    try {
      return await showDialog<_ChannelDraft>(
        context: context,
        builder: (dialogContext) {
          var visibility = 'private';
          var historyMode = 'new_only';
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              backgroundColor: GE.bgDeep,
              title: const Text('Новый канал'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: title,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Название'),
                    ),
                    TextField(
                      controller: username,
                      decoration: const InputDecoration(
                        labelText: 'Username канала',
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
                          child: Text('Приватный · E2EE'),
                        ),
                        DropdownMenuItem(
                          value: 'public',
                          child: Text('Публичный'),
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
                  onPressed: () {
                    Navigator.pop(
                      dialogContext,
                      _ChannelDraft(
                        username: username.text.trim().replaceFirst('@', ''),
                        title: title.text.trim(),
                        about: about.text.trim(),
                        visibility: visibility,
                        historyMode: historyMode,
                      ),
                    );
                  },
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

  Future<String?> _showJoinDialog() async {
    final username = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: GE.bgDeep,
          title: const Text('Вступить в канал'),
          content: TextField(
            controller: username,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Username канала',
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
                username.text.trim().replaceFirst('@', ''),
              ),
              child: const Text('Вступить'),
            ),
          ],
        ),
      );
    } finally {
      username.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GE.bg,
      appBar: AppBar(
        title: const Text('Каналы'),
        actions: [
          IconButton(
            tooltip: 'Вступить по username',
            onPressed: _loading ? null : _join,
            icon: const Icon(CupertinoIcons.person_add),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loading ? null : _create,
        child: const Icon(CupertinoIcons.add),
      ),
      body: ValueListenableBuilder<List<ChannelSummary>>(
        valueListenable: _service.myChannels,
        builder: (context, channels, _) {
          if (_loading && channels.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_error != null && channels.isEmpty) {
            return _ErrorState(message: _error!, onRetry: _load);
          }
          if (channels.isEmpty) {
            return Center(
              child: Text('Каналов пока нет', style: TextStyle(color: GE.sub)),
            );
          }
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
              itemCount: channels.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) => _ChannelTile(channels[index]),
            ),
          );
        },
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final ChannelSummary channel;
  const _ChannelTile(this.channel);

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          GhostAvatar(
            avatarUrl: channel.avatarUrl,
            fallbackText: channel.title.isNotEmpty ? channel.title[0] : '#',
            fallbackIcon: channel.isPublic
                ? CupertinoIcons.antenna_radiowaves_left_right
                : CupertinoIcons.lock,
            size: 46,
            fallbackColors: [GE.primary2, GE.primary],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  channel.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: GE.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '@${channel.username} · ${channel.isPublic ? 'публичный' : 'приватный'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: GE.sub, fontSize: 13),
                ),
                if (channel.about.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    channel.about,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          Text(
            channel.role == 'owner'
                ? 'Владелец'
                : channel.role == 'admin'
                ? 'Админ'
                : 'Участник',
            style: TextStyle(color: GE.sub, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.cloud_download, color: GE.sub),
            const SizedBox(height: 10),
            Text(
              'Не удалось загрузить каналы',
              textAlign: TextAlign.center,
              style: TextStyle(color: GE.text, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 5),
            Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: GE.sub, fontSize: 12),
            ),
            const SizedBox(height: 14),
            TextButton(onPressed: onRetry, child: const Text('Повторить')),
          ],
        ),
      ),
    );
  }
}

class _ChannelDraft {
  final String username;
  final String title;
  final String about;
  final String visibility;
  final String historyMode;

  const _ChannelDraft({
    required this.username,
    required this.title,
    required this.about,
    required this.visibility,
    required this.historyMode,
  });
}
