// KeyGate — оверлей поверх приложения. Реагирует на ChatRepo.keySyncNotifier:
//   needPassword   → просит пароль аккаунта (восстановить/опубликовать приватник
//                    в server-режиме), повторяет синхронизацию;
//   needChooseMode → просит выбрать server/local.
// При ok оверлей исчезает (ValueListenableBuilder).
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/auth_service.dart';
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
            outcome == KeySyncOutcome.needChooseMode;
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
    // Если только что логинились с паролем и первый автосинк в ChatRepo.init()
    // не долетел (сеть/тайминг) — тихо пробуем ТЕМ ЖЕ паролем ещё раз, прежде
    // чем заставлять юзера вводить его вручную (см. AuthService.peekPendingPwd).
    // initState зовётся ровно один раз за жизнь виджета — повторного триггера
    // не будет, отдельный guard-флаг не нужен.
    if (widget.outcome == KeySyncOutcome.needPassword) {
      final pending = AuthService.peekPendingPwd();
      if (pending != null) _autoRetry(pending);
    }
  }

  Future<void> _autoRetry(String pending) async {
    if (mounted) setState(() => _busy = true);
    await ChatRepo.instance.retryKeySync(password: pending);
    AuthService.clearPendingPwd();
    if (!mounted) return;
    setState(() => _busy = false);
    // ok → оверлей скроется сам. Не ok — молча остаёмся на обычной форме,
    // юзер даже не увидит, что была автопопытка (никакого "не подошло" тут,
    // это не его ввод).
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
      setState(() => _err = 'Не подошло. Проверь пароль аккаунта.');
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
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == KeySyncOutcome.error) {
      setState(() => _err = 'Не вышло, попробуй ещё раз.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPwd = widget.outcome == KeySyncOutcome.needPassword;
    // Клавиатура: поднимаем панель над ней плавной анимацией (та же длительность,
    // что и системная анимация клавиатуры на Android). Без этого поле пароля
    // на маленьких экранах уезжает под клавиатуру.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: Container(
        color: Colors.black.withValues(alpha: 0.55),
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
                      children: isPwd ? _pwdBody() : _modeBody(),
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

  List<Widget> _pwdBody() => [
    Icon(Icons.lock_outline, color: GE.primary, size: 40),
    const SizedBox(height: 12),
    Text(
      'Пароль для ключа',
      style: TextStyle(
        color: GE.text,
        fontSize: 18,
        fontWeight: FontWeight.w800,
      ),
    ),
    const SizedBox(height: 8),
    Text(
      'Чтобы восстановить ключ шифрования с сервера, введи пароль аккаунта.',
      textAlign: TextAlign.center,
      style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
    ),
    const SizedBox(height: 16),
    GlassInput(
      controller: _pwd,
      hint: 'Пароль аккаунта',
      icon: Icons.lock_outline,
      obscure: true,
      onSubmitted: (_) => _submitPwd(),
    ),
    if (_err != null) ...[
      const SizedBox(height: 8),
      Text(_err!, style: TextStyle(color: GE.red, fontSize: 12)),
    ],
    const SizedBox(height: 14),
    GlassButton(
      label: 'Восстановить',
      icon: Icons.cloud_download_outlined,
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
      'Как хранить ключ шифрования? Облачный бэкап переживает переустановку '
      '(нужен пароль). Локальный — приватнее, но без восстановления.',
      textAlign: TextAlign.center,
      style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
    ),
    const SizedBox(height: 16),
    GlassButton(
      label: 'Облачный бэкап',
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
}
