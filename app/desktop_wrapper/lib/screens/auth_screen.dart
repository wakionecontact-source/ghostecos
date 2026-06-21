// Login / Register native с дисклеймером ToS+Privacy.
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../auth_service.dart';

class AuthScreen extends StatefulWidget {
  final VoidCallback onLoggedIn;
  const AuthScreen({super.key, required this.onLoggedIn});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLogin = true;
  bool _busy = false;
  bool _age18 = false;
  String? _err;
  final _userCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _pwd2Ctrl = TextEditingController();

  Future<void> _go() async {
    setState(() { _err = null; _busy = true; });
    try {
      if (_isLogin) {
        if (_userCtrl.text.trim().isEmpty || _pwdCtrl.text.isEmpty) {
          throw 'Заполните логин и пароль';
        }
        await AuthService.login(_userCtrl.text.trim().toLowerCase(), _pwdCtrl.text);
      } else {
        if (_userCtrl.text.trim().isEmpty ||
            _nameCtrl.text.trim().isEmpty ||
            _pwdCtrl.text.isEmpty ||
            _pwd2Ctrl.text.isEmpty) {
          throw 'Заполните все поля';
        }
        if (_pwdCtrl.text != _pwd2Ctrl.text) throw 'Пароли не совпадают';
        if (!_age18) throw 'Подтвердите 18+';
        await AuthService.register(
          username: _userCtrl.text.trim().toLowerCase(),
          displayName: _nameCtrl.text.trim(),
          password: _pwdCtrl.text,
          age18: true,
        );
      }
      widget.onLoggedIn();
    } catch (e) {
      setState(() => _err = e.toString());
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: GE.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: GE.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _Brand(),
                  const SizedBox(height: 20),
                  _Tabs(
                    isLogin: _isLogin,
                    onChange: (login) => setState(() {
                      _isLogin = login; _err = null;
                    }),
                  ),
                  const SizedBox(height: 20),
                  _input('Имя пользователя', _userCtrl),
                  if (!_isLogin) ...[
                    const SizedBox(height: 10),
                    _input('Отображаемое имя', _nameCtrl),
                  ],
                  const SizedBox(height: 10),
                  _input('Пароль', _pwdCtrl, obscure: true),
                  if (!_isLogin) ...[
                    const SizedBox(height: 10),
                    _input('Повторите пароль', _pwd2Ctrl, obscure: true),
                    const SizedBox(height: 14),
                    _Age18Checkbox(
                      value: _age18,
                      onChanged: (v) => setState(() => _age18 = v ?? false),
                    ),
                  ],
                  if (_err != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: GE.red.withValues(alpha: 0.10),
                        border: Border.all(color: GE.red.withValues(alpha: 0.30)),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(_err!,
                          style: TextStyle(color: GE.red, fontSize: 13)),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _PrimaryBtn(
                    label: _isLogin ? 'Войти' : 'Зарегистрироваться',
                    busy: _busy, onTap: _go,
                  ),
                  const SizedBox(height: 16),
                  const _Disclaimer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _input(String hint, TextEditingController c, {bool obscure = false}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      style: TextStyle(color: GE.text, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: GE.sub, fontSize: 14),
        filled: true,
        fillColor: const Color(0x66000000),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: GE.borderStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: GE.borderStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: GE.primary, width: 1.5),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ShaderMask(
          shaderCallback: (b) => LinearGradient(
            colors: [Colors.white, GE.primary],
          ).createShader(b),
          child: const Text(
            'GhostEcos',
            style: TextStyle(
              fontSize: 28, fontWeight: FontWeight.w800,
              color: Colors.white, letterSpacing: -0.5,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('Один аккаунт — вся экосистема',
            style: TextStyle(color: GE.sub, fontSize: 12)),
      ],
    );
  }
}

class _Tabs extends StatelessWidget {
  final bool isLogin;
  final ValueChanged<bool> onChange;
  const _Tabs({required this.isLogin, required this.onChange});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0x66000000),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(child: _tab('Войти', isLogin, () => onChange(true))),
          Expanded(child: _tab('Регистрация', !isLogin, () => onChange(false))),
        ],
      ),
    );
  }

  Widget _tab(String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? GE.primary.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: active
              ? Border.all(color: GE.primary.withValues(alpha: 0.35))
              : null,
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: TextStyle(
              color: active ? GE.primary : GE.sub,
              fontWeight: FontWeight.w600, fontSize: 13,
            )),
      ),
    );
  }
}

class _Age18Checkbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?> onChanged;
  const _Age18Checkbox({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: value, onChanged: onChanged,
            activeColor: GE.primary,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Подтверждаю, что мне исполнилось 18 лет',
                style: TextStyle(color: GE.sub, fontSize: 12, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrimaryBtn extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback onTap;
  const _PrimaryBtn({required this.label, required this.busy, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [GE.primary, GE.primary2]),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(color: GE.primary.withValues(alpha: 0.4),
                blurRadius: 18, offset: const Offset(0, 6)),
          ],
        ),
        child: Center(
          child: busy
              ? const SizedBox(
                  height: 18, width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(label,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();
  Future<void> _open(String path) async {
    final url = Uri.parse('${GE.baseUrl}$path');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }
  @override
  Widget build(BuildContext context) {
    final base = TextStyle(color: GE.sub, fontSize: 11, height: 1.55);
    final link = TextStyle(color: GE.primary, fontSize: 11, height: 1.55);
    return Text.rich(
      TextSpan(style: base, children: [
        const TextSpan(text: 'Входя или регистрируя аккаунт вы соглашаетесь с '),
        TextSpan(
          text: 'Условиями пользования',
          style: link,
          recognizer: _tapRec(() => _open('/terms')),
        ),
        const TextSpan(text: ' и '),
        TextSpan(
          text: 'Политикой приватности',
          style: link,
          recognizer: _tapRec(() => _open('/privacy')),
        ),
      ]),
      textAlign: TextAlign.center,
    );
  }
  static TapGestureRecognizer _tapRec(VoidCallback cb) =>
      TapGestureRecognizer()..onTap = cb;
}
