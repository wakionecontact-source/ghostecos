import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../core/api/auth_api.dart';
import '../../core/storage/secure_store.dart';
import '../../shared/theme/app_theme.dart';
import '../home/home_shell.dart';

/// Экран входа с нового устройства (device-trust).
///
/// Флоу (безопасный, код генерит/сверяет СЕРВЕР):
///   1. Ждём, пока на доверенном устройстве одобрят вход (поллинг фазы).
///   2. Фаза code_phase → показываем поле ввода 6-значного кода
///      (код виден ТОЛЬКО на доверенном устройстве).
///   3. Отправляем код на сервер → success → токен → Home.
class DeviceTrustWaitScreen extends StatefulWidget {
  final String requestId;
  const DeviceTrustWaitScreen({super.key, required this.requestId});

  @override
  State<DeviceTrustWaitScreen> createState() => _DeviceTrustWaitScreenState();
}

class _DeviceTrustWaitScreenState extends State<DeviceTrustWaitScreen> {
  Timer? _poll;
  final _code = TextEditingController();
  String _phase = 'pending';
  bool _verifying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    _tick();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _tick() async {
    if (_verifying) return; // не дёргаем сервер во время проверки кода
    try {
      final r = await AuthApi.I.pollLoginRequest(widget.requestId);
      final phase = (r['phase'] ?? 'pending') as String;
      if (!mounted) return;

      switch (phase) {
        case 'success':
          // Фолбэк: устройство одобрено напрямую, токен в ответе poll.
          final token = r['token'] as String?;
          final uname = r['username'] as String?;
          if (token != null) {
            await SecureStore.I.setToken(token);
            if (uname != null) await SecureStore.I.setUsername(uname);
            _goHome();
          }
        case 'denied':
          _terminal('Вход отклонён с доверенного устройства');
        case 'blocked':
          _terminal('Это устройство заблокировано');
        case 'expired':
          _terminal('Время истекло. Попробуйте войти заново');
        default: // pending | code_phase
          if (phase != _phase) setState(() => _phase = phase);
      }
    } catch (_) {
      // разовые сетевые ошибки игнорируем — следующий тик повторит
    }
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length != 6) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final res = await AuthApi.I.verifyCode(widget.requestId, code);
      if (!mounted) return;
      switch (res.result) {
        case 'success':
          _goHome();
        case 'wrong':
          setState(() {
            _error = 'Неверный код'
                '${res.attemptsLeft != null ? ' (осталось попыток: ${res.attemptsLeft})' : ''}';
            _code.clear();
          });
        case 'locked':
          _terminal('Слишком много попыток. Войдите заново');
        case 'expired':
          _terminal('Время истекло. Войдите заново');
        default:
          setState(() => _error = 'Не удалось подтвердить код');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Ошибка проверки кода');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  void _goHome() {
    _poll?.cancel();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const HomeShell()),
      (_) => false,
    );
  }

  void _terminal(String msg) {
    _poll?.cancel();
    if (!mounted) return;
    setState(() {
      _phase = 'error';
      _error = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_phase) {
            'code_phase' => _codeView(),
            'error' => _errorView(),
            _ => _waitView(),
          },
        ),
      ),
    );
  }

  // ── Ожидание одобрения ───────────────────────────────────────────────────────
  Widget _waitView() {
    return Column(
      children: [
        const Spacer(),
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppColors.border),
          ),
          child: const Icon(Icons.devices_other, size: 40, color: AppColors.primary),
        ),
        const SizedBox(height: 24),
        const Text(
          'Новое устройство',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Подтвердите вход на одном из доверенных устройств, '
          'где вы уже вошли в GhostChat.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: AppColors.sub, height: 1.5),
        ),
        const SizedBox(height: 32),
        const SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        const SizedBox(height: 12),
        const Text(
          'Ожидание подтверждения…',
          style: TextStyle(fontSize: 13, color: AppColors.faint),
        ),
        const Spacer(),
      ],
    );
  }

  // ── Ввод 6-значного кода ──────────────────────────────────────────────────────
  Widget _codeView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        const Text(
          'Введите код',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: AppColors.text,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'На доверенном устройстве показан 6-значный код. Введите его здесь.',
          style: TextStyle(fontSize: 14, color: AppColors.sub, height: 1.5),
        ),
        const SizedBox(height: 28),
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 32,
            fontWeight: FontWeight.w700,
            letterSpacing: 12,
          ),
          decoration: const InputDecoration(
            counterText: '',
            hintText: '••••••',
            hintStyle: TextStyle(color: AppColors.faint, letterSpacing: 12),
          ),
          onChanged: (v) {
            if (v.length == 6 && !_verifying) _verify();
          },
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: const TextStyle(color: AppColors.red, fontSize: 13),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _verifying ? null : _verify,
          child: _verifying
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: Colors.white,
                  ),
                )
              : const Text('Подтвердить'),
        ),
      ],
    );
  }

  // ── Терминальная ошибка ───────────────────────────────────────────────────────
  Widget _errorView() {
    return Column(
      children: [
        const Spacer(),
        const Icon(CupertinoIcons.exclamationmark_circle, size: 56, color: AppColors.red),
        const SizedBox(height: 16),
        Text(
          _error ?? 'Ошибка',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, color: AppColors.text),
        ),
        const Spacer(),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Назад ко входу'),
        ),
      ],
    );
  }
}
