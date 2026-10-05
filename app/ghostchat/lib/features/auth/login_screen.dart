import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../core/api/auth_api.dart';
import '../../core/api/http_client.dart';
import '../../core/constants.dart';
import '../../core/models/user.dart';
import '../../services/bot_check_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/validators.dart';
import '../home/home_shell.dart';
import 'device_trust_wait_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!_form.currentState!.validate()) return;
    final normalizedUsername = Validators.normalizeUsername(_username.text);
    if (normalizedUsername != _username.text) {
      _username.value = TextEditingValue(
        text: normalizedUsername,
        selection: TextSelection.collapsed(offset: normalizedUsername.length),
      );
    }
    setState(() => _loading = true);
    try {
      await BotCheckService.instance.ensureToken(context);
      final outcome = await AuthApi.I.login(
        username: normalizedUsername,
        password: _password.text,
      );
      if (!mounted) return;
      switch (outcome) {
        case LoginSuccess():
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute<void>(builder: (_) => const HomeShell()),
            (_) => false,
          );
        case LoginPending(:final requestId):
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DeviceTrustWaitScreen(requestId: requestId),
            ),
          );
      }
    } on ApiException catch (e) {
      _showError(_mapError(e));
    } catch (_) {
      _showError('Не удалось войти');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _mapError(ApiException e) {
    if (e.statusCode == 401) return 'Неверное имя пользователя или пароль';
    if (e.statusCode == 403) return 'Это устройство заблокировано';
    if (e.isRateLimited) return 'Слишком много попыток. Подождите минуту';
    if (e.statusCode == 0) return 'Нет соединения с сервером';
    return e.message;
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'С возвращением',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Войдите в свой аккаунт GhostChat.',
                  style: TextStyle(fontSize: 13, color: AppColors.sub),
                ),
                const SizedBox(height: 28),
                _label('Имя пользователя'),
                TextFormField(
                  controller: _username,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  inputFormatters: [
                    // Краевые пробелы нормализуются при отправке, внутренние
                    // остаются в поле и отклоняются валидатором.
                    FilteringTextInputFormatter.allow(
                      RegExp(r'[a-zA-Z0-9_. ]'),
                    ),
                    LengthLimitingTextInputFormatter(K.usernameMaxTotal),
                  ],
                  decoration: _dec('username', prefix: '@'),
                  style: const TextStyle(color: AppColors.text),
                  validator: (v) => Validators.username(v ?? ''),
                ),
                const SizedBox(height: 8),
                _label('Пароль'),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  textInputAction: TextInputAction.done,
                  decoration: _dec('Ваш пароль', toggle: true),
                  style: const TextStyle(color: AppColors.text),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Введите пароль' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Войти'),
                ),
                const SizedBox(height: 16),
                Center(
                  child: TextButton(
                    onPressed: _loading
                        ? null
                        : () => Navigator.of(context).pushReplacement(
                            MaterialPageRoute<void>(
                              builder: (_) => const RegisterScreen(),
                            ),
                          ),
                    child: const Text(
                      'Нет аккаунта? Создать',
                      style: TextStyle(color: AppColors.primary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6, left: 2),
    child: Text(t, style: const TextStyle(color: AppColors.sub, fontSize: 13)),
  );

  InputDecoration _dec(String hint, {String? prefix, bool toggle = false}) {
    return InputDecoration(
      hintText: hint,
      prefixText: prefix,
      prefixStyle: const TextStyle(color: AppColors.sub, fontSize: 16),
      suffixIcon: toggle
          ? IconButton(
              icon: Icon(
                _obscure ? CupertinoIcons.eye_slash : CupertinoIcons.eye_fill,
                color: AppColors.faint,
                size: 20,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            )
          : null,
    );
  }
}
