// TDA (Trust Device Authorization): экран ожидания на НОВОМ устройстве.
//
// Флоу (проверено по реальному серверу, chat_router.py + social_router.py):
//  1. AuthService.login() вернул {requires_approval, request_id, code, ...}
//     когда на аккаунте включена TDA И это устройство ещё не доверено.
//  2. Код УЖЕ у нас (сервер прислал его сразу в ответе login) — показываем
//     его юзеру.
//  3. Юзер идёт на СВОЁ доверенное устройство → Настройки → Устройства →
//     «Ожидают подтверждения» → вводит этот код → approve.
//  4. Мы поллим GET /devices/pending/{request_id}/status (БЕЗ авторизации —
//     токена ещё нет) раз в 2с, пока не придёт phase=approved+token.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';

class DeviceApprovalWaitScreen extends StatefulWidget {
  final String requestId;
  final String code;
  final String username;
  final VoidCallback onApproved;
  const DeviceApprovalWaitScreen({
    super.key,
    required this.requestId,
    required this.code,
    required this.username,
    required this.onApproved,
  });

  @override
  State<DeviceApprovalWaitScreen> createState() => _DeviceApprovalWaitScreenState();
}

class _DeviceApprovalWaitScreenState extends State<DeviceApprovalWaitScreen> {
  final _api = ApiClient();
  Timer? _poll;
  String _phase = 'pending';
  String? _error;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    try {
      final r = await _api.chatGet('/devices/pending/${widget.requestId}/status');
      if (!mounted) return;
      final phase = (r is Map ? r['phase'] as String? : null) ?? 'pending';
      switch (phase) {
        case 'approved':
          _poll?.cancel();
          final token = (r as Map)['token'] as String?;
          if (token != null) {
            await AuthService.saveApprovedSession(token, widget.username);
            if (!mounted) return;
            widget.onApproved();
          }
        case 'denied':
          _terminal('Вход отклонён на доверенном устройстве');
        case 'expired':
          _terminal('Время истекло — попробуйте войти заново');
        default:
          if (phase != _phase) setState(() => _phase = phase);
      }
    } catch (_) {
      // разовые сетевые ошибки игнорируем — следующий тик повторит
    }
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
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Center(
              child: _phase == 'error' ? _errorView() : _waitView(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _waitView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.shield_moon_outlined, size: 56, color: GE.primary),
        const SizedBox(height: 18),
        Text(
          'Подтвердите вход',
          style: TextStyle(color: GE.text, fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        Text(
          'На аккаунте включено подтверждение новых устройств. Введите код '
          'ниже на ЛЮБОМ доверенном устройстве:\n'
          'Настройки → Устройства → Ожидают подтверждения',
          textAlign: TextAlign.center,
          style: TextStyle(color: GE.sub, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 28),
        PressScale(
          onTap: () {
            Clipboard.setData(ClipboardData(text: widget.code));
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
            decoration: BoxDecoration(
              color: GE.glassFill,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: GE.primary.withValues(alpha: 0.4)),
            ),
            child: Text(
              widget.code,
              style: TextStyle(
                color: GE.text,
                fontSize: 36,
                fontWeight: FontWeight.w800,
                letterSpacing: 10,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text('Тап — скопировать', style: TextStyle(color: GE.muted, fontSize: 11)),
        const SizedBox(height: 32),
        SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: GE.primary),
        ),
        const SizedBox(height: 12),
        Text('Ожидание подтверждения…', style: TextStyle(color: GE.muted, fontSize: 13)),
        const SizedBox(height: 24),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Отмена', style: TextStyle(color: GE.sub, fontSize: 13)),
        ),
      ],
    );
  }

  Widget _errorView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(CupertinoIcons.exclamationmark_circle, size: 56, color: GE.red),
        const SizedBox(height: 16),
        Text(
          _error ?? 'Ошибка',
          textAlign: TextAlign.center,
          style: TextStyle(color: GE.text, fontSize: 16),
        ),
        const SizedBox(height: 24),
        GlassButton(
          label: 'Назад ко входу',
          fullWidth: true,
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
