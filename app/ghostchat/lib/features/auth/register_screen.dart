import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../core/api/auth_api.dart';
import '../../core/api/http_client.dart';
import '../../core/constants.dart';
import '../../services/bot_check_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/validators.dart';
import '../home/home_shell.dart';
import 'login_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
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
      await AuthApi.I.register(
        username: normalizedUsername,
        password: _password.text,
        displayName: _name.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const HomeShell()),
        (_) => false,
      );
    } on ApiException catch (e) {
      _showError(_mapError(e));
    } catch (_) {
      _showError('Не удалось зарегистрироваться');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _mapError(ApiException e) {
    if (e.statusCode == 409) return 'Это имя пользователя уже занято';
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
                  'Создать аккаунт',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Ключи шифрования создаются на устройстве и не покидают его.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.sub,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 28),
                _label('Имя'),
                TextFormField(
                  controller: _name,
                  textInputAction: TextInputAction.next,
                  maxLength: K.nameMax,
                  decoration: _dec('Как вас будут видеть', counter: true),
                  style: const TextStyle(color: AppColors.text),
                  validator: (v) => Validators.name(v ?? ''),
                ),
                const SizedBox(height: 8),
                _label('Имя пользователя'),
                TextFormField(
                  controller: _username,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  inputFormatters: [
                    // Пробел разрешён только временно: по краям он будет
                    // убран при отправке, внутри валидатор покажет ошибку.
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
                  textInputAction: TextInputAction.next,
                  decoration: _dec(
                    'Минимум ${K.passwordMin} символов',
                    toggle: true,
                  ),
                  style: const TextStyle(color: AppColors.text),
                  validator: (v) => Validators.password(v ?? ''),
                ),
                const SizedBox(height: 8),
                _label('Повторите пароль'),
                TextFormField(
                  controller: _confirm,
                  obscureText: _obscure,
                  textInputAction: TextInputAction.done,
                  decoration: _dec('Ещё раз'),
                  style: const TextStyle(color: AppColors.text),
                  validator: (v) =>
                      Validators.passwordConfirm(_password.text, v ?? ''),
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
                      : const Text('Создать аккаунт'),
                ),
                const SizedBox(height: 16),
                Center(
                  child: TextButton(
                    onPressed: _loading
                        ? null
                        : () => Navigator.of(context).pushReplacement(
                            MaterialPageRoute<void>(
                              builder: (_) => const LoginScreen(),
                            ),
                          ),
                    child: const Text(
                      'Уже есть аккаунт? Войти',
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

  InputDecoration _dec(
    String hint, {
    String? prefix,
    bool toggle = false,
    bool counter = false,
  }) {
    return InputDecoration(
      hintText: hint,
      prefixText: prefix,
      prefixStyle: const TextStyle(color: AppColors.sub, fontSize: 16),
      counterText: counter ? null : '',
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
