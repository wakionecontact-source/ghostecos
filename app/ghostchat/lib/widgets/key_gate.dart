// KeyGate — оверлей поверх приложения. Реагирует на ChatRepo.keySyncNotifier:
//   needPassword   → просит пароль аккаунта и повторяет синхронизацию;
//   serverCopyMissing → предлагает создать отсутствующую серверную копию;
//   needChooseMode → просит выбрать server/local.
//   skipped        → пользователь явно продолжил без проверки в этой сессии.
// При ok оверлей исчезает (ValueListenableBuilder).
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/chat_repo.dart';
import 'glass.dart';

class KeyGate extends StatelessWidget {
  final Widget child;
  const KeyGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<KeySyncOutcome>(
      valueListenable: ChatRepo.instance.keySyncNotifier,
      builder: (context, outcome, _) {
        final show =
            outcome == KeySyncOutcome.needPassword ||
            outcome == KeySyncOutcome.serverCopyMissing ||
            outcome == KeySyncOutcome.needChooseMode ||
            outcome == KeySyncOutcome.needUpdateConfirm ||
            outcome == KeySyncOutcome.keyMismatch;
        return Stack(
          children: [
            child,
            if (show) Positioned.fill(child: _GateOverlay(outcome: outcome)),
          ],
        );
      },
    );
  }
}

class _GateOverlay extends StatefulWidget {
  final KeySyncOutcome outcome;
  const _GateOverlay({required this.outcome});
  @override
  State<_GateOverlay> createState() => _GateOverlayState();
}

class _GateOverlayState extends State<_GateOverlay> {
  final _pwd = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _pwd.dispose();
    super.dispose();
  }

  Future<void> _submitPwd() async {
    if (_pwd.text.isEmpty) {
      setState(() => _err = 'Введи пароль');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    final r = await ChatRepo.instance.retryKeySync(password: _pwd.text);
    if (!mounted) return;
    setState(() => _busy = false);
    // ok → оверлей скроется сам (keySyncNotifier == ok).
    if (r != KeySyncOutcome.ok && r != KeySyncOutcome.needChooseMode) {
      setState(() {
        _err = r == KeySyncOutcome.serverCopyMissing
            ? 'На сервере нет копии ключа. Проверь состояние аккаунта и повтори.'
            : r == KeySyncOutcome.keyMismatch
            ? 'Публичный ключ не совпал с сервером. Автоматическое обновление отменено.'
            : 'Не подошло. Проверь пароль аккаунта.';
      });
    }
  }

  Future<void> _chooseMode(String mode) async {
    setState(() {
      _busy = true;
      _err = null;
    });
    // server → если нужен пароль, outcome станет needPassword и оверлей покажет
    // поле пароля. local → публикуем pub без приватника, готово.
    final r = await ChatRepo.instance.retryKeySync(
      chosenMode: mode,
      password: mode == 'server' && _pwd.text.isNotEmpty ? _pwd.text : null,
    );
    if (r == KeySyncOutcome.ok) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('key_storage_mode', mode);
      await prefs.setBool('keychoice_done', true);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == KeySyncOutcome.error) {
      setState(() => _err = 'Не вышло, попробуй ещё раз.');
    }
  }

  void _acceptUpdatedKey() {
    ChatRepo.instance.keySyncNotifier.value = KeySyncOutcome.needPassword;
  }

  void _dismissMismatch() {
    ChatRepo.instance.keySyncNotifier.value = KeySyncOutcome.error;
  }

  void _skipKeySetup() {
    ChatRepo.instance.skipKeySyncForSession();
  }

  @override
  Widget build(BuildContext context) {
    final isPwd =
        widget.outcome == KeySyncOutcome.needPassword ||
        widget.outcome == KeySyncOutcome.serverCopyMissing;
    // Клавиатура: поднимаем панель над ней плавной анимацией (та же длительность,
    // что и системная анимация клавиатуры на Android). Без этого поле пароля
    // на маленьких экранах уезжает под клавиатуру.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: Container(
        color: GE.shadow.withValues(alpha: 0.55),
        // KeyGate висит поверх приложения ВНЕ Scaffold/MaterialApp-поддерева
        // MainShell — TextField внутри GlassInput требует Material-предка,
        // без него краш "No Material widget found".
        child: Material(
          type: MaterialType.transparency,
          child: AnimatedPadding(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            padding: EdgeInsets.only(bottom: bottomInset),
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: GlassCard(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ...(isPwd
                            ? _pwdBody(
                                missingCopy:
                                    widget.outcome ==
                                    KeySyncOutcome.serverCopyMissing,
                              )
                            : widget.outcome == KeySyncOutcome.needUpdateConfirm
                            ? _updateBody()
                            : widget.outcome == KeySyncOutcome.keyMismatch
                            ? _mismatchBody()
                            : _modeBody()),
                        const SizedBox(height: 4),
                        TextButton(
                          onPressed: _busy ? null : _skipKeySetup,
                          child: Text(
                            'Пропустить',
                            style: TextStyle(color: GE.sub),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _pwdBody({bool missingCopy = false}) => [
    Icon(CupertinoIcons.lock, color: GE.primary, size: 40),
    const SizedBox(height: 12),
    Text(
      missingCopy ? 'Сохранить копию ключа' : 'Пароль для ключа',
      style: TextStyle(
        color: GE.text,
        fontSize: 18,
        fontWeight: FontWeight.w800,
      ),
    ),
    const SizedBox(height: 8),
    Text(
      missingCopy
          ? 'На сервере нет зашифрованной копии. Введи пароль аккаунта, чтобы сохранить текущий ключ в защищённом виде.'
          : 'Чтобы восстановить ключ шифрования с сервера, введи пароль аккаунта.',
      textAlign: TextAlign.center,
      style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
    ),
    const SizedBox(height: 16),
    GlassInput(
      controller: _pwd,
      hint: 'Пароль аккаунта',
      icon: CupertinoIcons.lock,
      obscure: true,
      onSubmitted: (_) => _submitPwd(),
    ),
    if (_err != null) ...[
      const SizedBox(height: 8),
      Text(_err!, style: TextStyle(color: GE.red, fontSize: 12)),
    ],
    const SizedBox(height: 14),
    GlassButton(
      label: missingCopy ? 'Сохранить копию' : 'Восстановить',
      icon: missingCopy
          ? CupertinoIcons.cloud_upload
          : CupertinoIcons.cloud_download,
      primary: true,
      fullWidth: true,
      loading: _busy,
      onTap: _submitPwd,
    ),
  ];

  List<Widget> _modeBody() => [
    Icon(Icons.key_outlined, color: GE.primary, size: 40),
    const SizedBox(height: 12),
    Text(
      'Хранение ключа',
      style: TextStyle(
        color: GE.text,
        fontSize: 18,
        fontWeight: FontWeight.w800,
      ),
    ),
    const SizedBox(height: 8),
    Text(
      'Как хранить ключ шифрования? Серверная копия переживает переустановку '
      '(нужен пароль). Локальный вариант приватнее, но без восстановления.',
      textAlign: TextAlign.center,
      style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
    ),
    const SizedBox(height: 16),
    GlassButton(
      label: 'Копия на сервере',
      icon: Icons.cloud_done_outlined,
      primary: true,
      fullWidth: true,
      loading: _busy,
      onTap: () => _chooseMode('server'),
    ),
    const SizedBox(height: 10),
    GlassButton(
      label: 'Только на устройстве',
      icon: Icons.phonelink_lock_outlined,
      fullWidth: true,
      onTap: () => _chooseMode('local'),
    ),
    if (_err != null) ...[
      const SizedBox(height: 8),
      Text(_err!, style: TextStyle(color: GE.red, fontSize: 12)),
    ],
  ];

  List<Widget> _updateBody() => [
    Icon(Icons.sync_problem_outlined, color: GE.primary, size: 40),
    const SizedBox(height: 12),
    Text(
      'Ключ обновился',
      style: TextStyle(
        color: GE.text,
        fontSize: 18,
        fontWeight: FontWeight.w800,
      ),
    ),
    const SizedBox(height: 8),
    Text(
      'На сервере обнаружена новая публичная версия ключа. Обновить локальный ключ с серверной копии?',
      textAlign: TextAlign.center,
      style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
    ),
    const SizedBox(height: 16),
    GlassButton(
      label: 'Обновить ключ',
      icon: CupertinoIcons.arrow_2_circlepath,
      primary: true,
      fullWidth: true,
      onTap: _acceptUpdatedKey,
    ),
    const SizedBox(height: 10),
    GlassButton(
      label: 'Позже',
      icon: CupertinoIcons.clock,
      fullWidth: true,
      onTap: _dismissMismatch,
    ),
  ];

  List<Widget> _mismatchBody() => [
    Icon(CupertinoIcons.exclamationmark_triangle, color: GE.red, size: 40),
    const SizedBox(height: 12),
    Text(
      'Ключи не совпадают',
      style: TextStyle(
        color: GE.text,
        fontSize: 18,
        fontWeight: FontWeight.w800,
      ),
    ),
    const SizedBox(height: 8),
    Text(
      'Публичный ключ аккаунта на сервере изменился, но зашифрованной копии для безопасного восстановления нет. Автоматически принимать такой ключ нельзя.',
      textAlign: TextAlign.center,
      style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
    ),
    const SizedBox(height: 16),
    GlassButton(
      label: 'Понятно',
      icon: CupertinoIcons.checkmark,
      primary: true,
      fullWidth: true,
      onTap: _dismissMismatch,
    ),
  ];
}
