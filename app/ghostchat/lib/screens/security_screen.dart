import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../mesh_background.dart';
import '../services/app_security_store.dart';
import '../services/chat_organization_store.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/ghost_native_dialog.dart';

/// App-local lock layer. It is intentionally outside the E2EE key gate:
/// unlocking the UI must never be confused with decrypting account keys.
class SecurityGate extends StatefulWidget {
  final Widget child;

  const SecurityGate({super.key, required this.child});

  @override
  State<SecurityGate> createState() => _SecurityGateState();
}

class _SecurityGateState extends State<SecurityGate>
    with WidgetsBindingObserver {
  bool _ready = false;
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppSecurityStore.instance.revision.addListener(_onSecurityChanged);
    unawaited(_load());
  }

  Future<void> _load() async {
    await AppSecurityStore.instance.load();
    if (!mounted) return;
    setState(() {
      _ready = true;
      _locked = AppSecurityStore.instance.hasPrimaryCode;
    });
  }

  void _onSecurityChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (AppSecurityStore.instance.hasPrimaryCode) {
        unawaited(_leaveSafeMode());
        if (mounted) setState(() => _locked = true);
      }
    }
  }

  Future<void> _leaveSafeMode() async {
    final removed = await AppSecurityStore.instance.leaveToNormal();
    await ChatOrganizationStore.instance.removeFoldersForSecurityScenarios(
      removed,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppSecurityStore.instance.revision.removeListener(_onSecurityChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || !_locked) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned.fill(
          child: _SecurityLockOverlay(
            onUnlocked: () {
              if (mounted) setState(() => _locked = false);
            },
          ),
        ),
      ],
    );
  }
}

class _SecurityLockOverlay extends StatefulWidget {
  final VoidCallback onUnlocked;

  const _SecurityLockOverlay({required this.onUnlocked});

  @override
  State<_SecurityLockOverlay> createState() => _SecurityLockOverlayState();
}

class _SecurityLockOverlayState extends State<_SecurityLockOverlay> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final code = _controller.text.trim();
    if (code.length < 4) {
      setState(() => _error = 'Введите код или пароль');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await AppSecurityStore.instance.unlock(code);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.mode == SecurityUnlockMode.wrong) {
      _controller.clear();
      setState(() => _error = 'Неверный код');
      return;
    }
    widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    final active = AppSecurityStore.instance.activeScenarioId;
    final activeName = active == null
        ? null
        : AppSecurityStore.instance.scenarioById(active)?.name;
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: Material(
        color: Colors.black.withValues(alpha: .68),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: GlassCard(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      activeName == null
                          ? CupertinoIcons.lock_shield
                          : CupertinoIcons.eye_slash,
                      color: GE.primary,
                      size: 42,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      activeName == null
                          ? 'Приложение заблокировано'
                          : 'Безопасная среда',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (activeName != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        activeName,
                        style: TextStyle(color: GE.primary, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      'Введите основной код для обычного режима или код безопасной среды.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: GE.sub,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _controller,
                      autofocus: true,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _unlock(),
                      decoration: InputDecoration(
                        prefixIcon: const Icon(CupertinoIcons.lock),
                        hintText: 'Код или пароль',
                        errorText: _error,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _unlock,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(CupertinoIcons.arrow_right),
                        label: const Text('Открыть'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppSecurityScreen extends StatefulWidget {
  const AppSecurityScreen({super.key});

  @override
  State<AppSecurityScreen> createState() => _AppSecurityScreenState();
}

class _AppSecurityScreenState extends State<AppSecurityScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(AppSecurityStore.instance.load());
    AppSecurityStore.instance.revision.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppSecurityStore.instance.revision.removeListener(_refresh);
    super.dispose();
  }

  Future<String?> _askCode({required String title}) async {
    final first = TextEditingController();
    final second = TextEditingController();
    try {
      final result = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: GE.bgDeep,
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: first,
                autofocus: true,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Код или пароль'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: second,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Повторите код'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final value = first.text.trim();
                if (value.length < 4 || value != second.text.trim()) return;
                Navigator.pop(dialogContext, value);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      );
      return result;
    } finally {
      first.dispose();
      second.dispose();
    }
  }

  Future<void> _setPrimaryCode() async {
    final code = await _askCode(title: 'Основной код приложения');
    if (code == null) return;
    await AppSecurityStore.instance.setPrimaryCode(code);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Код приложения включён')));
    }
  }

  Future<void> _removePrimaryCode() async {
    final confirmed = await showGhostNativeConfirm(
      context: context,
      title: 'Отключить блокировку?',
      message: 'Безопасные среды и их локальные коды тоже будут удалены.',
      confirmLabel: 'Отключить',
      destructive: true,
    );
    if (confirmed == true) await AppSecurityStore.instance.clearPrimaryCode();
  }

  Future<void> _createScenario() async {
    if (!AppSecurityStore.instance.hasPrimaryCode) return;
    final nameController = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: GE.bgDeep,
          title: const Text('Новая безопасная среда'),
          content: TextField(
            controller: nameController,
            autofocus: true,
            maxLength: 32,
            decoration: const InputDecoration(labelText: 'Название'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, nameController.text),
              child: const Text('Далее'),
            ),
          ],
        ),
      );
      if (name == null || name.trim().isEmpty || !mounted) return;
      final code = await _askCode(title: 'Код безопасной среды');
      if (code == null) return;
      await AppSecurityStore.instance.createScenario(
        name,
        code,
        parentId: AppSecurityStore.instance.activeScenarioId,
      );
    } finally {
      nameController.dispose();
    }
  }

  Future<void> _leaveSafeMode() async {
    final removed = await AppSecurityStore.instance.leaveToNormal();
    await ChatOrganizationStore.instance.removeFoldersForSecurityScenarios(
      removed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final security = AppSecurityStore.instance;
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Безопасность'),
          backgroundColor: Colors.transparent,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 40),
          children: [
            GlassCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(CupertinoIcons.lock_shield, color: GE.primary, size: 28),
                  const SizedBox(height: 10),
                  Text(
                    'Локальная защита',
                    style: TextStyle(
                      color: GE.text,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Код не отправляется на сервер. После сворачивания приложение снова попросит его.',
                    style: TextStyle(color: GE.sub, fontSize: 12, height: 1.35),
                  ),
                  const SizedBox(height: 14),
                  if (!security.hasPrimaryCode)
                    FilledButton.icon(
                      onPressed: _setPrimaryCode,
                      icon: const Icon(CupertinoIcons.lock),
                      label: const Text('Установить код'),
                    )
                  else ...[
                    Row(
                      children: [
                        Icon(CupertinoIcons.checkmark_shield, color: GE.green),
                        const SizedBox(width: 8),
                        const Expanded(child: Text('Блокировка включена')),
                        TextButton(
                          onPressed: _setPrimaryCode,
                          child: const Text('Изменить'),
                        ),
                      ],
                    ),
                    TextButton.icon(
                      onPressed: _removePrimaryCode,
                      icon: Icon(CupertinoIcons.trash, color: GE.red),
                      label: Text('Отключить', style: TextStyle(color: GE.red)),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            GlassCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(CupertinoIcons.eye_slash, color: GE.primary),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Безопасные среды',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Отдельные коды открывают скрытые группы чатов. Количество сред не ограничено, вложенность — до 5 уровней.',
                    style: TextStyle(color: GE.sub, fontSize: 12, height: 1.35),
                  ),
                  if (security.isInSafeMode) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _leaveSafeMode,
                      icon: const Icon(CupertinoIcons.arrow_left),
                      label: const Text('Выйти в обычный режим'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (security.isInSafeMode)
                    for (final scenario in security.scenarios)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(CupertinoIcons.lock, color: GE.primary),
                        title: Text(scenario.name),
                        subtitle: Text(
                          scenario.parentId == null
                              ? 'Отдельная среда'
                              : 'Вложенная среда',
                        ),
                        trailing: IconButton(
                          tooltip: 'Удалить',
                          onPressed: () => security.removeScenario(scenario.id),
                          icon: Icon(CupertinoIcons.trash, color: GE.red),
                        ),
                      ),
                  if (security.hasPrimaryCode)
                    OutlinedButton.icon(
                      onPressed: _createScenario,
                      icon: const Icon(CupertinoIcons.plus),
                      label: const Text('Добавить среду'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Безопасные группы помечаются при создании группы чатов. В обычном режиме они и их содержимое не показываются.',
              textAlign: TextAlign.center,
              style: TextStyle(color: GE.sub, fontSize: 12, height: 1.35),
            ),
          ],
        ),
      ),
    );
  }
}
