import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../mesh_background.dart';
import '../models/bot_program.dart';
import '../services/api_client.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';

class BotBuilderScreen extends StatefulWidget {
  final int botId;
  final String username;

  const BotBuilderScreen({
    super.key,
    required this.botId,
    required this.username,
  });

  @override
  State<BotBuilderScreen> createState() => _BotBuilderScreenState();
}

class _CommandDraft {
  final TextEditingController command;
  final TextEditingController description;
  final TextEditingController response;

  _CommandDraft(BotCommandRule rule)
    : command = TextEditingController(text: rule.command),
      description = TextEditingController(text: rule.description),
      response = TextEditingController(text: rule.response);

  BotCommandRule get rule => BotCommandRule(
    command: command.text,
    description: description.text,
    response: response.text,
  );

  void dispose() {
    command.dispose();
    description.dispose();
    response.dispose();
  }
}

class _BotBuilderScreenState extends State<BotBuilderScreen> {
  final _fallback = TextEditingController();
  final List<_CommandDraft> _commands = [];
  Timer? _statusTimer;
  bool _checkingStatus = false;
  bool _loading = true;
  bool _saving = false;
  bool _runnerAvailable = false;
  bool _managedReady = false;
  bool _managedEnabled = false;
  String _botStatus = 'offline';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _fallback.dispose();
    for (final command in _commands) {
      command.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool showLoading = true}) async {
    if (showLoading && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final raw = await ApiClient().botsGet('/${widget.botId}/program');
      final data = Map<String, dynamic>.from(raw as Map);
      final program = BotProgram.fromDynamic(data['program']);
      for (final command in _commands) {
        command.dispose();
      }
      _commands
        ..clear()
        ..addAll(program.commands.map(_CommandDraft.new));
      _fallback.text = program.fallback;
      if (mounted) {
        setState(() {
          _runnerAvailable = data['runner_available'] == true;
          _managedReady = data['managed_ready'] == true;
          _managedEnabled = data['managed_enabled'] == true;
          _botStatus = data['bot_status'] as String? ?? 'offline';
          _loading = false;
          _error = null;
        });
        _syncStatusPolling();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  BotProgram _currentProgram() => BotProgram(
    commands: _commands.map((command) => command.rule).toList(),
    fallback: _fallback.text,
  );

  Future<bool> _saveProgram({bool showToast = true}) async {
    final program = _currentProgram();
    final errors = program.validate();
    if (errors.isNotEmpty) {
      if (showToast) toast.show(errors.first);
      return false;
    }
    setState(() => _saving = true);
    try {
      await ApiClient().botsPut('/${widget.botId}/program', {
        'program': program.toJson(),
      });
      if (showToast && mounted) toast.show('Сценарий сохранён');
      return true;
    } catch (error) {
      if (showToast && mounted) toast.show('Не удалось сохранить: $error');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addCommand() async {
    final rule = await showGlassSheet<BotCommandRule>(
      context,
      child: const _AddBotCommandSheet(),
    );
    if (rule == null || !mounted) return;
    if (_commands.length >= 50) {
      toast.show('Можно добавить не больше 50 команд');
      return;
    }
    setState(() => _commands.add(_CommandDraft(rule)));
  }

  Future<void> _toggleRunner() async {
    if (_saving) return;
    if (_managedEnabled) {
      setState(() => _saving = true);
      try {
        await ApiClient().botsPost('/${widget.botId}/runner/stop');
        if (mounted) {
          setState(() => _managedEnabled = false);
          _syncStatusPolling();
          toast.show('Бот останавливается');
        }
      } catch (error) {
        if (mounted) toast.show('Не удалось остановить: $error');
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Запустить на сервере?', style: TextStyle(color: GE.text)),
        content: Text(
          'Для одного бота поддерживается одно активное подключение. Если он уже запущен в другой программе, серверный запуск заменит ту сессию.',
          style: TextStyle(color: GE.sub, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Запустить', style: TextStyle(color: GE.primary)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    if (!await _saveProgram(showToast: false) || !mounted) {
      toast.show('Проверь команды и ответы перед запуском');
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiClient().botsPost('/${widget.botId}/runner/start');
      if (mounted) {
        setState(() => _managedEnabled = true);
        toast.show('Бот запускается на сервере');
      }
      await _load(showLoading: false);
    } catch (error) {
      if (mounted) toast.show('Не удалось запустить: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _syncStatusPolling() {
    if (!_managedEnabled || _botStatus == 'online' || !mounted) {
      _statusTimer?.cancel();
      _statusTimer = null;
      return;
    }
    _statusTimer ??= Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted || _checkingStatus) return;
      _checkingStatus = true;
      try {
        final raw = await ApiClient().botsGet('/${widget.botId}/program');
        final data = Map<String, dynamic>.from(raw as Map);
        if (!mounted) return;
        setState(() {
          _runnerAvailable = data['runner_available'] == true;
          _managedReady = data['managed_ready'] == true;
          _managedEnabled = data['managed_enabled'] == true;
          _botStatus = data['bot_status'] as String? ?? 'offline';
        });
        _syncStatusPolling();
      } catch (_) {
        // Keep the last known status; transient polling errors must not alter
        // the user's unsaved command drafts.
      } finally {
        _checkingStatus = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: true, titleText: 'Конструктор бота'),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: GE.primary))
            : _error != null
            ? _errorView()
            : _editor(),
      ),
    );
  }

  Widget _errorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: GE.sub),
          ),
          const SizedBox(height: 12),
          GlassButton(label: 'Повторить', onTap: _load),
        ],
      ),
    ),
  );

  Widget _editor() => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
    children: [
      _introCard(),
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: Text(
              'Команды  ${_commands.length}/50',
              style: TextStyle(
                color: GE.text,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Добавить команду',
            onPressed: _addCommand,
            icon: Icon(CupertinoIcons.add_circled_solid, color: GE.primary),
          ),
        ],
      ),
      if (_commands.isEmpty)
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Text(
              'Добавь, например, /start или /help. Нажатая команда отправит пользователю заданный ответ.',
              style: TextStyle(color: GE.sub, height: 1.4),
            ),
          ),
        ),
      for (var i = 0; i < _commands.length; i++) _commandCard(i),
      const SizedBox(height: 10),
      Text(
        'Ответ по умолчанию',
        style: TextStyle(color: GE.text, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      GlassCard(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _fallback,
          minLines: 2,
          maxLines: 5,
          maxLength: 4000,
          style: TextStyle(color: GE.text),
          decoration: _inputDecoration(
            'Необязательно',
            'Ответ на обычный текст или неизвестную команду',
          ),
        ),
      ),
      const SizedBox(height: 14),
      GlassButton(
        label: _saving ? 'Сохраняю…' : 'Сохранить сценарий',
        icon: CupertinoIcons.checkmark_circle,
        primary: true,
        fullWidth: true,
        onTap: _saving ? null : () => _saveProgram(),
      ),
      const SizedBox(height: 10),
      _runnerCard(),
      const SizedBox(height: 12),
      Text(
        'Сценарии выполняются через ghostecos-api. Код Python из чата или полей не запускается.',
        textAlign: TextAlign.center,
        style: TextStyle(color: GE.muted, fontSize: 11, height: 1.4),
      ),
    ],
  );

  Widget _introCard() => GlassCard(
    padding: const EdgeInsets.all(16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: GE.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(CupertinoIcons.gear_alt_fill, color: GE.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '@${widget.username}',
                style: TextStyle(color: GE.text, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'Собери ответы из команд. Например, /start приветствует, /help показывает список, а резервный ответ обрабатывает всё остальное.',
                style: TextStyle(color: GE.sub, fontSize: 12.5, height: 1.4),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _commandCard(int index) {
    final draft = _commands[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: draft.command,
                    maxLength: 33,
                    autocorrect: false,
                    textCapitalization: TextCapitalization.none,
                    style: TextStyle(
                      color: GE.primary,
                      fontWeight: FontWeight.w700,
                    ),
                    decoration: _inputDecoration(
                      'Команда',
                      '/start',
                    ).copyWith(counterText: ''),
                  ),
                ),
                IconButton(
                  tooltip: 'Удалить команду',
                  onPressed: () {
                    setState(() => _commands.removeAt(index).dispose());
                  },
                  icon: Icon(CupertinoIcons.trash, color: GE.red, size: 19),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: draft.description,
              maxLength: 64,
              style: TextStyle(color: GE.text),
              decoration: _inputDecoration(
                'Короткое описание',
                'Открыть главное меню',
              ).copyWith(counterText: ''),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: draft.response,
              minLines: 2,
              maxLines: 6,
              maxLength: 4000,
              style: TextStyle(color: GE.text),
              decoration: _inputDecoration(
                'Ответ',
                'Текст, который отправит бот',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _runnerCard() {
    final canStart =
        _runnerAvailable && _managedReady && _currentProgram().canStart;
    final state = !_runnerAvailable
        ? 'Серверный исполнитель не подключён'
        : _managedEnabled
        ? (_botStatus == 'online'
              ? 'Работает · бот онлайн'
              : 'Запускается · ждёт соединения')
        : 'Остановлен';
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _managedEnabled
                    ? CupertinoIcons.play_circle_fill
                    : CupertinoIcons.play_circle,
                color: _managedEnabled ? GE.green : GE.primary,
                size: 22,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Запуск на сервере',
                  style: TextStyle(color: GE.text, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Обновить статус',
                onPressed: () => _load(showLoading: false),
                icon: Icon(CupertinoIcons.refresh, color: GE.sub, size: 19),
              ),
            ],
          ),
          Text(state, style: TextStyle(color: GE.sub, fontSize: 12)),
          if (!_managedReady && _runnerAvailable) ...[
            const SizedBox(height: 6),
            Text(
              'Для этого старого бота нужно один раз перевыпустить токен в профиле.',
              style: TextStyle(color: GE.muted, fontSize: 11.5, height: 1.35),
            ),
          ],
          const SizedBox(height: 12),
          GlassButton(
            label: _saving
                ? 'Подожди…'
                : _managedEnabled
                ? 'Остановить бота'
                : 'Запустить бота',
            icon: _managedEnabled
                ? CupertinoIcons.stop_circle
                : CupertinoIcons.play_fill,
            danger: _managedEnabled,
            primary: !_managedEnabled,
            fullWidth: true,
            onTap: _saving || (!_managedEnabled && !canStart)
                ? null
                : _toggleRunner,
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String label, String hint) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: GE.sub, fontSize: 12),
        hintStyle: TextStyle(color: GE.muted, fontSize: 12),
        filled: true,
        fillColor: GE.glassFill,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: GE.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: GE.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: GE.primary, width: 1.3),
        ),
      );
}

class _AddBotCommandSheet extends StatefulWidget {
  const _AddBotCommandSheet();

  @override
  State<_AddBotCommandSheet> createState() => _AddBotCommandSheetState();
}

class _AddBotCommandSheetState extends State<_AddBotCommandSheet> {
  final _command = TextEditingController(text: '/start');
  final _description = TextEditingController(text: 'Начать');
  final _response = TextEditingController();

  @override
  void dispose() {
    _command.dispose();
    _description.dispose();
    _response.dispose();
    super.dispose();
  }

  void _add() {
    final rule = BotCommandRule(
      command: _command.text,
      description: _description.text,
      response: _response.text,
    );
    final error = rule.validate();
    if (error != null) {
      toast.show(error);
      return;
    }
    Navigator.of(context).pop(rule);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      18,
      18,
      18,
      20 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Новая команда',
          style: TextStyle(
            color: GE.text,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _command,
          decoration: const InputDecoration(
            labelText: 'Команда, например /start',
          ),
        ),
        TextField(
          controller: _description,
          maxLength: 64,
          decoration: const InputDecoration(labelText: 'Описание'),
        ),
        TextField(
          controller: _response,
          minLines: 2,
          maxLines: 5,
          maxLength: 4000,
          decoration: const InputDecoration(labelText: 'Ответ бота'),
        ),
        const SizedBox(height: 10),
        GlassButton(
          label: 'Добавить',
          icon: CupertinoIcons.add,
          primary: true,
          fullWidth: true,
          onTap: _add,
        ),
      ],
    ),
  );
}
