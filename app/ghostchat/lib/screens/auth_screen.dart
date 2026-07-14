// Login / Register native с дисклеймером ToS+Privacy.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../auth_service.dart';
import '../services/theme_service.dart';
import '../widgets/glass.dart';

// ── Лимиты регистрации — ЗЕРКАЛО серверных (social_router.py: _NAME_MIN/MAX,
// _USER_MIN/MAX/TOTAL, _PASS_MIN/MAX). Если сервер поменяет — поменять и тут,
// иначе клиент будет молчать про лимит, а сервер откажет уже после отправки.
const _usernameMin = 3;
const _usernameMax = 60; // без учёта точек (см. _usernameValid)
const _usernameTotalMax = 64; // общий лимит длины строки (с точками)
const _nameMin = 2;
const _nameMax = 100;
const _passMin = 8;
const _passMax = 150;

bool _usernameValid(String raw) {
  final v = raw.trim().toLowerCase();
  if (v.isEmpty || v.length > _usernameTotalMax) return false;
  if (!RegExp(r'^[a-z0-9_.]+$').hasMatch(v)) return false;
  final noDots = v.replaceAll('.', '');
  return noDots.length >= _usernameMin && noDots.length <= _usernameMax;
}

String _usernameHint(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return 'Латиница, цифры, _ и точка · $_usernameMin–$_usernameMax символов';
  if (!RegExp(r'^[a-z0-9_.]+$').hasMatch(v.toLowerCase())) {
    return 'Только латиница, цифры, _ и точка';
  }
  final noDots = v.replaceAll('.', '');
  if (noDots.length < _usernameMin) return 'Ещё ${_usernameMin - noDots.length} симв. (точки не в счёт)';
  if (noDots.length > _usernameMax) return 'Слишком длинное — максимум $_usernameMax символов';
  return 'Похоже на валидное имя пользователя';
}

bool _nameValid(String raw) {
  final v = raw.trim();
  return v.length >= _nameMin && v.length <= _nameMax;
}

String _nameHint(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return '$_nameMin–$_nameMax символов, любые';
  if (v.length < _nameMin) return 'Ещё ${_nameMin - v.length} симв.';
  if (v.length > _nameMax) return 'Слишком длинное — максимум $_nameMax символов';
  return 'Ок';
}

bool _passValid(String raw) => raw.length >= _passMin && raw.length <= _passMax;

String _passHint(String raw) {
  if (raw.isEmpty) return '$_passMin–$_passMax символов';
  if (raw.length < _passMin) return 'Ещё ${_passMin - raw.length} симв.';
  if (raw.length > _passMax) return 'Слишком длинный — максимум $_passMax символов';
  return 'Ок';
}

class AuthScreen extends StatefulWidget {
  final VoidCallback onLoggedIn;
  final bool startInRegister;
  const AuthScreen({super.key, required this.onLoggedIn, this.startInRegister = false});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late bool _isLogin = !widget.startInRegister;
  bool _busy = false;
  bool _age18 = false;
  bool _agreedTerms = false;
  String? _err;
  final _userCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _pwd2Ctrl = TextEditingController();
  final _userFieldKey = GlobalKey<_ValidatedFieldState>();
  final _nameFieldKey = GlobalKey<_ValidatedFieldState>();
  final _pwdFieldKey = GlobalKey<_ValidatedFieldState>();

  Future<void> _guest() async {
    setState(() { _err = null; _busy = true; });
    try {
      await AuthService.loginAsGuest();
      widget.onLoggedIn();
    } catch (e) {
      setState(() => _err = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
        // Бьём тревогу локально по тем же лимитам, что и сервер — не гоняем
        // запрос впустую, и сразу видно КАКОЕ поле не так (тряска).
        var bad = false;
        if (!_usernameValid(_userCtrl.text)) { _userFieldKey.currentState?.shake(); bad = true; }
        if (!_nameValid(_nameCtrl.text)) { _nameFieldKey.currentState?.shake(); bad = true; }
        if (!_passValid(_pwdCtrl.text)) { _pwdFieldKey.currentState?.shake(); bad = true; }
        if (bad) throw 'Проверьте подсвеченные поля';
        if (_pwdCtrl.text != _pwd2Ctrl.text) throw 'Пароли не совпадают';
        if (!_age18) throw 'Подтвердите 18+';
        if (!_agreedTerms) throw 'Примите условия использования и политику приватности';
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
                  _isLogin
                      ? _input('Имя пользователя', _userCtrl)
                      : _ValidatedField(
                          key: _userFieldKey,
                          hint: 'Имя пользователя',
                          controller: _userCtrl,
                          isValid: _usernameValid,
                          hintText: _usernameHint,
                          atPrefix: true,
                        ),
                  if (!_isLogin) ...[
                    const SizedBox(height: 10),
                    _ValidatedField(
                      key: _nameFieldKey,
                      hint: 'Отображаемое имя',
                      controller: _nameCtrl,
                      isValid: _nameValid,
                      hintText: _nameHint,
                    ),
                  ],
                  const SizedBox(height: 10),
                  _isLogin
                      ? _input('Пароль', _pwdCtrl, obscure: true)
                      : _ValidatedField(
                          key: _pwdFieldKey,
                          hint: 'Пароль',
                          controller: _pwdCtrl,
                          obscure: true,
                          isValid: _passValid,
                          hintText: _passHint,
                        ),
                  if (!_isLogin) ...[
                    const SizedBox(height: 10),
                    _input('Повторите пароль', _pwd2Ctrl, obscure: true),
                    const SizedBox(height: 14),
                    _Age18Checkbox(
                      value: _age18,
                      onChanged: (v) => setState(() => _age18 = v ?? false),
                    ),
                    _TermsCheckbox(
                      value: _agreedTerms,
                      onChanged: (v) =>
                          setState(() => _agreedTerms = v ?? false),
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
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy ? null : _guest,
                    child: Text(
                      'Продолжить как гость',
                      style: TextStyle(color: GE.sub, fontSize: 13),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      'Только чаты с устройствами поблизости (LAN/BLE/Wi-Fi Direct). '
                      'Без аккаунта — сервер вообще не используется.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: GE.sub, fontSize: 10.5, height: 1.4),
                    ),
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

}

Widget _input(String hint, TextEditingController c, {bool obscure = false}) {
  return _ObscurableField(hint: hint, controller: c, obscure: obscure);
}

// Поле пароля с глазиком-переключателем видимости (обычные поля тоже через
// него проходят, просто без иконки — obscure=false).
class _ObscurableField extends StatefulWidget {
  final String hint;
  final TextEditingController controller;
  final bool obscure;
  const _ObscurableField({
    required this.hint,
    required this.controller,
    required this.obscure,
  });

  @override
  State<_ObscurableField> createState() => _ObscurableFieldState();
}

class _ObscurableFieldState extends State<_ObscurableField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      obscureText: widget.obscure && !_visible,
      style: TextStyle(color: GE.text, fontSize: 14),
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: TextStyle(color: GE.sub, fontSize: 14),
        filled: true,
        fillColor: GE.glassFill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        suffixIcon: widget.obscure
            ? IconButton(
                icon: Icon(
                  _visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  color: GE.sub,
                  size: 20,
                ),
                onPressed: () => setState(() => _visible = !_visible),
              )
            : null,
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

/// Поле username с "@" внутри текста, пока пусто и не в фокусе — при фокусе
/// или вводе символ реально уезжает влево, наружу за левый край поля (тем же
/// цветом, что обычный текст, без затухания). "@" не часть значения
/// контроллера — чисто визуальная накладка поверх обычного _input.
class _AtPrefixField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  const _AtPrefixField({
    required this.controller,
    required this.focusNode,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final flown = focusNode.hasFocus || controller.text.isNotEmpty;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.centerLeft,
      children: [
        AnimatedPositioned(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          left: flown ? -18 : 14,
          child: Text('@', style: TextStyle(color: GE.text, fontSize: 14)),
        ),
        TextField(
          controller: controller,
          focusNode: focusNode,
          style: TextStyle(color: GE.text, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: GE.sub, fontSize: 14),
            filled: true,
            fillColor: GE.glassFill,
            contentPadding:
                const EdgeInsets.only(left: 28, right: 14, top: 14, bottom: 14),
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
        ),
      ],
    );
  }
}

/// Поле с живой подсказкой-критерием ПОД собой (см. _usernameHint/_nameHint/
/// _passHint) — цвет меняется по мере ввода (серый → красный/зелёный),
/// при неудачной попытке отправки формы shake() трясёт строку критерия,
/// чтобы взгляд сразу упал на то, что не так.
class _ValidatedField extends StatefulWidget {
  final String hint;
  final TextEditingController controller;
  final bool obscure;
  final bool Function(String) isValid;
  final String Function(String) hintText;
  final bool atPrefix;
  const _ValidatedField({
    super.key,
    required this.hint,
    required this.controller,
    required this.isValid,
    required this.hintText,
    this.obscure = false,
    this.atPrefix = false,
  });

  @override
  State<_ValidatedField> createState() => _ValidatedFieldState();
}

class _ValidatedFieldState extends State<_ValidatedField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shakeCtrl;
  FocusNode? _focusNode;

  @override
  void initState() {
    super.initState();
    _shakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    widget.controller.addListener(_onChange);
    if (widget.atPrefix) {
      _focusNode = FocusNode()..addListener(_onChange);
    }
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void shake() => _shakeCtrl.forward(from: 0);

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _focusNode?.removeListener(_onChange);
    _focusNode?.dispose();
    _shakeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final touched = text.trim().isNotEmpty;
    final valid = widget.isValid(text);
    final color = !touched ? GE.sub : (valid ? GE.green : GE.red);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.atPrefix
            ? _AtPrefixField(controller: widget.controller, focusNode: _focusNode!, hint: widget.hint)
            : _input(widget.hint, widget.controller, obscure: widget.obscure),
        const SizedBox(height: 4),
        AnimatedBuilder(
          animation: _shakeCtrl,
          builder: (context, child) {
            final t = _shakeCtrl.value;
            final dx = math.sin(t * math.pi * 6) * 4 * (1 - t);
            return Transform.translate(offset: Offset(dx, 0), child: child);
          },
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Row(
              children: [
                Icon(
                  !touched
                      ? Icons.info_outline
                      : (valid ? Icons.check_circle : Icons.error_outline),
                  size: 12,
                  color: color,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    widget.hintText(text),
                    style: TextStyle(color: color, fontSize: 10.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
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
            colors: [GE.text, GE.primary],
          ).createShader(b),
          child: Text(
            'GhostEcos',
            style: TextStyle(
              fontSize: 28, fontWeight: FontWeight.w800,
              color: GE.text, letterSpacing: -0.5,
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
        color: GE.glassFill,
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
          border: ThemeService.isMinimal
              ? null
              : (active
                  ? Border.all(color: GE.primary.withValues(alpha: 0.35))
                  : null),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            'Подтверждаю, что мне исполнилось 18 лет',
            style: TextStyle(color: GE.sub, fontSize: 12, height: 1.5),
          ),
        ),
        GhostSwitch(
          value: value,
          onChanged: (v) => onChanged(v),
          activeColor: GE.primary,
        ),
      ],
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
          boxShadow: ThemeService.isMinimal
              ? null
              : [
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

Future<void> _openLegalPage(String path) async {
  final url = Uri.parse('${GE.baseUrl}$path');
  await launchUrl(url, mode: LaunchMode.externalApplication);
}

TapGestureRecognizer _tapRec(VoidCallback cb) =>
    TapGestureRecognizer()..onTap = cb;

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();
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
          recognizer: _tapRec(() => _openLegalPage('/terms')),
        ),
        const TextSpan(text: ' и '),
        TextSpan(
          text: 'Политикой приватности',
          style: link,
          recognizer: _tapRec(() => _openLegalPage('/privacy')),
        ),
      ]),
      textAlign: TextAlign.center,
    );
  }
}

class _TermsCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?> onChanged;
  const _TermsCheckbox({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final base = TextStyle(color: GE.sub, fontSize: 12, height: 1.5);
    final link = TextStyle(color: GE.primary, fontSize: 12, height: 1.5);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(style: base, children: [
              const TextSpan(text: 'Принимаю '),
              TextSpan(
                text: 'Условия использования',
                style: link,
                recognizer: _tapRec(() => _openLegalPage('/terms')),
              ),
              const TextSpan(text: ' и '),
              TextSpan(
                text: 'Политику приватности',
                style: link,
                recognizer: _tapRec(() => _openLegalPage('/privacy')),
              ),
            ]),
          ),
        ),
        GhostSwitch(
          value: value,
          onChanged: (v) => onChanged(v),
          activeColor: GE.primary,
        ),
      ],
    );
  }
}
