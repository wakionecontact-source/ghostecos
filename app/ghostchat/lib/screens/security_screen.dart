import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../mesh_background.dart';
import '../core/local/app_logger.dart';
import '../services/app_security_store.dart';
import '../services/biometric_auth_service.dart';
import '../services/chat_organization_store.dart';
import '../services/incoming_call_notification_service.dart';
import '../services/notification_service.dart';
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
  bool _appInBackground = false;
  Timer? _lockTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ChatOrganizationStore.instance.revision.addListener(_onOrganizationChanged);
    AppSecurityStore.instance.revision.addListener(_onSecurityChanged);
    unawaited(_load());
  }

  Future<void> _load() async {
    await AppSecurityStore.instance.load();
    if (!mounted) return;
    appLog.protectedContext = AppSecurityStore.instance.isInSafeMode;
    final shouldLock = AppSecurityStore.instance.hasPrimaryCode;
    setState(() {
      _ready = true;
      _locked = shouldLock;
    });
    NotificationService.chatNavigationAllowed = !shouldLock;
  }

  void _onSecurityChanged() {
    appLog.protectedContext = AppSecurityStore.instance.isInSafeMode;
    if (mounted) setState(() {});
  }

  void _onOrganizationChanged() {
    NotificationService.instance.clearProtectedNotifications();
    unawaited(
      IncomingCallNotificationService.instance.clearIfCallerProtected(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appInBackground = false;
      _lockTimer?.cancel();
      _lockTimer = null;
      return;
    }

    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached) {
      return;
    }

    _appInBackground = true;
    if (!AppSecurityStore.instance.hasPrimaryCode ||
        _locked ||
        _lockTimer?.isActive == true) {
      return;
    }

    final delay = AppSecurityStore.instance.autoLockDelaySeconds;
    if (delay == 0) {
      _lockNow();
      return;
    }
    _lockTimer = Timer(Duration(seconds: delay), () {
      _lockTimer = null;
      if (!mounted ||
          !_appInBackground ||
          !AppSecurityStore.instance.hasPrimaryCode) {
        return;
      }
      setState(() => _locked = true);
      NotificationService.chatNavigationAllowed = false;
    });
  }

  void _lockNow() {
    _lockTimer?.cancel();
    _lockTimer = null;
    if (mounted) setState(() => _locked = true);
    NotificationService.chatNavigationAllowed = false;
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ChatOrganizationStore.instance.revision.removeListener(
      _onOrganizationChanged,
    );
    AppSecurityStore.instance.revision.removeListener(_onSecurityChanged);
    NotificationService.chatNavigationAllowed = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator(color: GE.primary)),
      );
    }
    final scenarioId = AppSecurityStore.instance.activeScenarioId;
    final scopedChild = KeyedSubtree(
      key: ValueKey<String>('security:${scenarioId ?? 'normal'}'),
      child: widget.child,
    );
    if (!_locked) return scopedChild;
    return _SecurityLockOverlay(
      onUnlocked: () {
        if (mounted) setState(() => _locked = false);
        NotificationService.chatNavigationAllowed = true;
      },
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
  bool _biometricsAvailable = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshBiometricAvailability());
  }

  Future<void> _refreshBiometricAvailability() async {
    if (!AppSecurityStore.instance.biometricUnlockEnabled) return;
    final available = await BiometricAuthService.instance.isAvailable();
    if (mounted) setState(() => _biometricsAvailable = available);
  }

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
    if (result.removedScenarioIds.isNotEmpty) {
      await ChatOrganizationStore.instance.removeFoldersForSecurityScenarios(
        result.removedScenarioIds,
      );
      if (!mounted) return;
    }
    widget.onUnlocked();
  }

  Future<void> _unlockWithBiometrics() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final authenticated = await BiometricAuthService.instance.authenticate();
      if (!mounted) return;
      if (!authenticated) {
        setState(() => _busy = false);
        return;
      }
      final result = await AppSecurityStore.instance.unlockWithBiometrics();
      if (!mounted) return;
      if (result.mode == SecurityUnlockMode.wrong) {
        setState(() {
          _busy = false;
          _error = 'Введите код или пароль';
        });
        return;
      }
      if (result.removedScenarioIds.isNotEmpty) {
        await ChatOrganizationStore.instance.removeFoldersForSecurityScenarios(
          result.removedScenarioIds,
        );
        if (!mounted) return;
      }
      widget.onUnlocked();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Биометрия недоступна. Введите код или пароль';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
                      CupertinoIcons.lock_shield,
                      color: GE.primary,
                      size: 42,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Приложение заблокировано',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Введите код или пароль.',
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
                    if (_biometricsAvailable) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _unlockWithBiometrics,
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('Войти по биометрии'),
                        ),
                      ),
                    ],
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
  bool _closingForSafeMode = false;
  bool _biometricsAvailable = false;

  @override
  void initState() {
    super.initState();
    unawaited(AppSecurityStore.instance.load());
    unawaited(_refreshBiometricAvailability());
    AppSecurityStore.instance.revision.addListener(_refresh);
  }

  Future<void> _refreshBiometricAvailability() async {
    await AppSecurityStore.instance.load();
    final available = await BiometricAuthService.instance.isAvailable();
    if (mounted) setState(() => _biometricsAvailable = available);
  }

  void _refresh() {
    if (!mounted) return;
    if (AppSecurityStore.instance.isInSafeMode) {
      _closeForSafeMode();
      return;
    }
    setState(() {});
  }

  void _closeForSafeMode() {
    if (_closingForSafeMode) return;
    _closingForSafeMode = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!AppSecurityStore.instance.isInSafeMode) {
        _closingForSafeMode = false;
        return;
      }
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
      } else {
        _closingForSafeMode = false;
      }
    });
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

  Future<void> _setBiometricUnlock(bool enabled) async {
    if (enabled) {
      try {
        final authenticated = await BiometricAuthService.instance
            .authenticate();
        if (!authenticated || !mounted) return;
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось проверить биометрию')),
        );
        return;
      }
    }
    await AppSecurityStore.instance.setBiometricUnlockEnabled(enabled);
  }

  String _autoLockDelayLabel(int seconds) {
    if (seconds == 0) return 'Сразу';
    if (seconds < 60) return '$seconds секунд';
    final minutes = seconds ~/ 60;
    final suffix = minutes == 1
        ? 'минута'
        : minutes < 5
        ? 'минуты'
        : 'минут';
    return '$minutes $suffix';
  }

  Future<void> _chooseAutoLockDelay() async {
    final current = AppSecurityStore.instance.autoLockDelaySeconds;
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: const Text('Автоблокировка'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final seconds in AppSecurityStore.autoLockDelayOptionsSeconds)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_autoLockDelayLabel(seconds)),
                trailing: seconds == current
                    ? Icon(CupertinoIcons.checkmark, color: GE.primary)
                    : null,
                onTap: () => Navigator.pop(dialogContext, seconds),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      await AppSecurityStore.instance.setAutoLockDelaySeconds(selected);
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
    final security = AppSecurityStore.instance;
    final parentId = security.activeScenarioId;
    if (!security.canCreateScenario(parentId: parentId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Достигнута максимальная глубина: 5 уровней'),
        ),
      );
      return;
    }
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
        parentId: parentId,
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
    if (security.isInSafeMode) {
      _closeForSafeMode();
      return const SizedBox.shrink();
    }
    final canCreateScenario = security.canCreateScenario(
      parentId: security.activeScenarioId,
    );
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
                    'Код не отправляется на сервер. После сворачивания приложение заблокируется через выбранное время.',
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
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(CupertinoIcons.timer, color: GE.primary),
                      title: const Text('Автоблокировка'),
                      subtitle: Text(
                        _autoLockDelayLabel(security.autoLockDelaySeconds),
                      ),
                      trailing: const Icon(CupertinoIcons.chevron_right),
                      onTap: _chooseAutoLockDelay,
                    ),
                    if (_biometricsAvailable)
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        secondary: Icon(
                          Icons.fingerprint,
                          color: GE.primary,
                        ),
                        title: const Text('Вход по биометрии'),
                        subtitle: const Text(
                          'Быстрый вход в обычное пространство. Для безопасных сред используются их отдельные коды.',
                        ),
                        value: security.biometricUnlockEnabled,
                        onChanged: _setBiometricUnlock,
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
                      onPressed: canCreateScenario ? _createScenario : null,
                      icon: const Icon(CupertinoIcons.plus),
                      label: const Text('Добавить среду'),
                    ),
                  if (security.hasPrimaryCode &&
                      security.isInSafeMode &&
                      !canCreateScenario) ...[
                    const SizedBox(height: 5),
                    Text(
                      'В этой среде уже достигнута максимальная глубина в 5 уровней.',
                      style: TextStyle(color: GE.sub, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Группы, созданные внутри безопасной среды, доступны только в ней.',
              textAlign: TextAlign.center,
              style: TextStyle(color: GE.sub, fontSize: 12, height: 1.35),
            ),
          ],
        ),
      ),
    );
  }
}
