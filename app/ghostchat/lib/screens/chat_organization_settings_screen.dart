import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../mesh_background.dart';
import '../services/auth_service.dart';
import '../services/chat_organization_store.dart';
import '../theme.dart';
import '../widgets/glass.dart';

class ChatOrganizationSettingsScreen extends StatefulWidget {
  const ChatOrganizationSettingsScreen({super.key});

  @override
  State<ChatOrganizationSettingsScreen> createState() =>
      _ChatOrganizationSettingsScreenState();
}

class _ChatOrganizationSettingsScreenState
    extends State<ChatOrganizationSettingsScreen> {
  final _store = ChatOrganizationStore.instance;
  bool _autoDelete = true;
  int? _days = 5;
  String _anchor = 'archived_at';
  String _deleteMode = 'local';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _store.load(account: await AuthService.username());
    if (!mounted) return;
    setState(() {
      _autoDelete = _store.archiveAutoDelete;
      _days = _store.archiveRetentionDays;
      _anchor = _store.archiveAnchor;
      _deleteMode = _store.archiveDeleteMode;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _store.setArchivePolicy(
      autoDelete: _autoDelete,
      retentionDays: _days,
      anchor: _anchor,
      deleteMode: _deleteMode,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          leading: IconButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            icon: const Icon(CupertinoIcons.chevron_back),
          ),
          titleText: 'Группы и архив',
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
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  SwitchListTile.adaptive(
                    value: _autoDelete,
                    onChanged: (value) => setState(() => _autoDelete = value),
                    title: const Text('Автоматически очищать архив'),
                    subtitle: const Text(
                      'Удаляются локальные данные чата, серверная история не трогается',
                    ),
                  ),
                  DropdownButtonFormField<int?>(
                    value: _days,
                    decoration: const InputDecoration(
                      labelText: 'Срок хранения в архиве',
                      contentPadding: EdgeInsets.symmetric(horizontal: 16),
                    ),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1 день')),
                      DropdownMenuItem(value: 3, child: Text('3 дня')),
                      DropdownMenuItem(value: 5, child: Text('5 дней')),
                      DropdownMenuItem(value: 7, child: Text('7 дней')),
                      DropdownMenuItem(value: 30, child: Text('30 дней')),
                      DropdownMenuItem(value: null, child: Text('Бессрочно')),
                    ],
                    onChanged: _autoDelete
                        ? (value) => setState(() => _days = value)
                        : null,
                  ),
                  DropdownButtonFormField<String>(
                    value: _anchor,
                    decoration: const InputDecoration(
                      labelText: 'Точка отсчёта',
                      contentPadding: EdgeInsets.symmetric(horizontal: 16),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'archived_at',
                        child: Text('Дата архивации'),
                      ),
                      DropdownMenuItem(
                        value: 'activity',
                        child: Text('Последняя активность'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _anchor = value);
                    },
                  ),
                  DropdownButtonFormField<String>(
                    value: _deleteMode,
                    decoration: const InputDecoration(
                      labelText: 'Действие после срока',
                      contentPadding: EdgeInsets.symmetric(horizontal: 16),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'local',
                        child: Text('Удалить только локальные данные'),
                      ),
                      DropdownMenuItem(
                        value: 'contact',
                        child: Text('Удалить локально и контакт'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _deleteMode = value);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Группы чатов хранятся локально и не меняют состав комнат на сервере. Один чат можно добавить в несколько групп; LAN-чаты остаются на устройстве.',
              style: TextStyle(color: GE.sub, height: 1.35, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}
