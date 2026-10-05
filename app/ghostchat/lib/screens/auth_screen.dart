// Login / Register native с дисклеймером ToS+Privacy.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import '../theme.dart';
import '../services/public_page_link.dart';
import '../mesh_background.dart';
import '../auth_service.dart';
import '../services/bot_check_service.dart';
import '../services/theme_service.dart';
import '../widgets/glass.dart';
import '../core/local/app_logger.dart';
import '../widgets/error_panel.dart';
import '../widgets/toast_overlay.dart';
import 'device_approval_wait_screen.dart';

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

String _normalizeUsername(String raw) => raw.trim().toLowerCase();

String _usernameHint(String raw) {
  final v = raw.trim();
  if (v.isEmpty)
    return 'Латиница, цифры, _ и точка · $_usernameMin–$_usernameMax символов';
  if (!RegExp(r'^[a-z0-9_.]+$').hasMatch(v.toLowerCase())) {
    return 'Только латиница, цифры, _ и точка';
  }
  final noDots = v.replaceAll('.', '');
  if (noDots.length < _usernameMin)
    return 'Ещё ${_usernameMin - noDots.length} симв. (точки не в счёт)';
  if (noDots.length > _usernameMax)
    return 'Слишком длинное — максимум $_usernameMax символов';
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
  if (v.length > _nameMax)
    return 'Слишком длинное — максимум $_nameMax символов';
  return 'Ок';
}

bool _passValid(String raw) => raw.length >= _passMin && raw.length <= _passMax;

String _passHint(String raw) {
  if (raw.isEmpty) return '$_passMin–$_passMax символов';
  if (raw.length < _passMin) return 'Ещё ${_passMin - raw.length} симв.';
  if (raw.length > _passMax)
    return 'Слишком длинный — максимум $_passMax символов';
  return 'Ок';
}

class AuthScreen extends StatefulWidget {
  final VoidCallback onLoggedIn;
  final bool startInRegister;
  const AuthScreen({
    super.key,
    required this.onLoggedIn,
    this.startInRegister = false,
  });
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late bool _isLogin = !widget.startInRegister;
  bool _busy = false;
  bool _age18 = false;
  bool _agreedTerms = false;
  String? _err;
  String? _errDetails;
  int? _errLogId;
  String? _usernameServerError;
  String? _usernameCheckError;
  bool _usernameChecking = false;
  bool? _usernameAvailable;
  Timer? _usernameCheckTimer;
  int _usernameCheckGeneration = 0;
  final _userCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _pwd2Ctrl = TextEditingController();
  final _userFieldKey = GlobalKey<_ValidatedFieldState>();
  final _nameFieldKey = GlobalKey<_ValidatedFieldState>();
  final _pwdFieldKey = GlobalKey<_ValidatedFieldState>();
  final _loginUserFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _userCtrl.addListener(_onUsernameChanged);
  }

  void _onUsernameChanged() {
    _usernameCheckTimer?.cancel();
    final generation = ++_usernameCheckGeneration;
    final raw = _userCtrl.text;
    if (mounted) {
      setState(() {
        _usernameServerError = null;
        _usernameCheckError = null;
        _usernameAvailable = null;
        _usernameChecking = false;
      });
    }
    if (_isLogin || !_usernameValid(raw)) return;
    if (mounted) setState(() => _usernameChecking = true);
    _usernameCheckTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_checkUsernameAvailability(raw, generation));
    });
  }

  Future<void> _checkUsernameAvailability(String raw, int generation) async {
    final username = _normalizeUsername(raw);
    try {
      final result = await AuthService.checkUsername(username);
      if (!mounted || generation != _usernameCheckGeneration) return;
      if (_normalizeUsername(_userCtrl.text) != username || _isLogin) return;
      final available = result['available'] == true;
      setState(() {
        _usernameChecking = false;
        _usernameAvailable = available;
        // The debounced probe is advisory. Only the registration response can
        // authoritatively mark a name as occupied.
        _usernameServerError = null;
      });
    } catch (e) {
      if (!mounted || generation != _usernameCheckGeneration) return;
      appLog.warn('auth', 'username availability check failed: $e');
      setState(() {
        _usernameChecking = false;
        _usernameAvailable = null;
        _usernameCheckError = 'Не удалось проверить имя';
      });
    }
  }

  @override
  void dispose() {
    _usernameCheckTimer?.cancel();
    _userCtrl.removeListener(_onUsernameChanged);
    _loginUserFocusNode.dispose();
    _userCtrl.dispose();
    _nameCtrl.dispose();
    _pwdCtrl.dispose();
    _pwd2Ctrl.dispose();
    super.dispose();
  }

  Future<void> _guest() async {
    setState(() {
      _err = null;
      _busy = true;
      _usernameServerError = null;
    });
    try {
      await AuthService.loginAsGuest();
      widget.onLoggedIn();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _go() async {
    setState(() {
      _err = null;
      _busy = true;
      _usernameServerError = null;
    });
    try {
      // Убираем только пробелы/whitespace по краям, включая несколько подряд.
      // Внутренний пробел сохраняем, чтобы валидатор показал ошибку, а не
      // молча превратил невалидный логин в другой.
      final uname = _normalizeUsername(_userCtrl.text);
      if (uname != _userCtrl.text) {
        _userCtrl.value = TextEditingValue(
          text: uname,
          selection: TextSelection.collapsed(offset: uname.length),
        );
      }

      if (_isLogin) {
        if (uname.isEmpty || _pwdCtrl.text.isEmpty) {
          throw 'Заполните логин и пароль';
        }
        if (!_usernameValid(uname)) throw _usernameHint(uname);
        await BotCheckService.instance.ensureToken(context);
        final r = await AuthService.login(uname, _pwdCtrl.text);
        if (r['requires_approval'] == true) {
          // TDA: аккаунт требует подтверждения с доверенного устройства —
          // не логинимся сразу, ждём на отдельном экране.
          _pwdCtrl.clear();
          if (!mounted) return;
          setState(() => _busy = false);
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DeviceApprovalWaitScreen(
                requestId: r['request_id'] as String,
                code: r['code'] as String,
                username: (r['username'] as String?) ?? uname,
                onApproved: () {
                  Navigator.of(context).pop();
                  widget.onLoggedIn();
                },
              ),
            ),
          );
          return;
        }
      } else {
        if (uname.isEmpty ||
            _nameCtrl.text.trim().isEmpty ||
            _pwdCtrl.text.isEmpty ||
            _pwd2Ctrl.text.isEmpty) {
          throw 'Заполните все поля';
        }
        // Бьём тревогу локально по тем же лимитам, что и сервер — не гоняем
        // запрос впустую, и сразу видно КАКОЕ поле не так (тряска).
        var bad = false;
        if (!_usernameValid(uname)) {
          _userFieldKey.currentState?.shake();
          bad = true;
        }
        if (_usernameChecking)
          throw 'Подождите, идёт проверка имени пользователя';
        // Availability is only an advisory/debounced hint. The registration
        // endpoint is authoritative; a stale or misrouted probe must not
        // block every otherwise valid username.
        if (!_nameValid(_nameCtrl.text)) {
          _nameFieldKey.currentState?.shake();
          bad = true;
        }
        if (!_passValid(_pwdCtrl.text)) {
          _pwdFieldKey.currentState?.shake();
          bad = true;
        }
        if (bad) throw 'Проверьте подсвеченные поля';
        if (_pwdCtrl.text != _pwd2Ctrl.text) throw 'Пароли не совпадают';
        if (!_age18) throw 'Подтвердите 18+';
        if (!_agreedTerms)
          throw 'Примите условия использования и политику приватности';
        await BotCheckService.instance.ensureToken(context);
        await AuthService.register(
          username: uname,
          displayName: _nameCtrl.text.trim(),
          password: _pwdCtrl.text,
          age18: true,
        );
      }
      _pwdCtrl.clear();
      _pwd2Ctrl.clear();
      widget.onLoggedIn();
    } catch (e) {
      if (!_isLogin && _isUsernameTakenError(e)) {
        _showUsernameTakenError(e);
      } else {
        _showError(e);
      }
    } finally {
      setState(() => _busy = false);
    }
  }

  void _showError(Object error) {
    final details = errorDetails(error);
    final entry = appLog.error('auth', 'Authentication failed: $details');
    if (!mounted) return;
    final summary = errorSummary(error, fallback: 'Не удалось выполнить вход');
    setState(() {
      _err = summary;
      _errDetails = details;
      _errLogId = entry.id;
    });
    toast.show(summary, level: ToastLevel.error, logId: entry.id);
  }

  bool _isUsernameTakenError(Object error) {
    final raw = error.toString().toLowerCase();
    return raw.contains('имя пользователя уже занято') ||
        raw.contains('username already') ||
        (raw.contains('409') && raw.contains('занят'));
  }

  void _showUsernameTakenError(Object error) {
    final details = errorDetails(error);
    final entry = appLog.error(
      'auth',
      'Registration username conflict: $details',
    );
    if (!mounted) return;
    setState(() {
      _err = null;
      _errDetails = null;
      _errLogId = null;
      _usernameServerError = 'Имя пользователя уже занято';
    });
    _userFieldKey.currentState?.shake();
    toast.show(
      'Имя пользователя уже занято',
      level: ToastLevel.error,
      logId: entry.id,
    );
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
                    onChange: (login) {
                      if (login == _isLogin) return;
                      FocusManager.instance.primaryFocus?.unfocus();
                      _loginUserFocusNode.unfocus();
                      setState(() {
                        _isLogin = login;
                        _err = null;
                        _errDetails = null;
                        _errLogId = null;
                        _usernameServerError = null;
                      });
                    },
                  ),
                  const SizedBox(height: 20),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 340),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    layoutBuilder: (currentChild, previousChildren) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ...previousChildren,
                        if (currentChild != null) currentChild,
                      ],
                    ),
                    transitionBuilder: (child, animation) {
                      final slide =
                          Tween<Offset>(
                            begin: const Offset(0, 0.025),
                            end: Offset.zero,
                          ).animate(
                            CurvedAnimation(
                              parent: animation,
                              curve: Curves.easeOutCubic,
                            ),
                          );
                      return FadeTransition(
                        opacity: animation,
                        child: SizeTransition(
                          sizeFactor: animation,
                          alignment: Alignment.topCenter,
                          child: SlideTransition(position: slide, child: child),
                        ),
                      );
                    },
                    child: _isLogin
                        ? Column(
                            key: const ValueKey('login-fields'),
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _AtPrefixField(
                                controller: _userCtrl,
                                focusNode: _loginUserFocusNode,
                                hint: 'Юзернейм',
                              ),
                              const SizedBox(height: 10),
                              _input('Пароль', _pwdCtrl, obscure: true),
                            ],
                          )
                        : Column(
                            key: const ValueKey('register-fields'),
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _ValidatedField(
                                key: _nameFieldKey,
                                hint: 'Имя',
                                controller: _nameCtrl,
                                isValid: _nameValid,
                                hintText: _nameHint,
                              ),
                              const SizedBox(height: 10),
                              _ValidatedField(
                                key: _userFieldKey,
                                hint: 'Юзернейм',
                                controller: _userCtrl,
                                isValid: _usernameValid,
                                hintText: (raw) {
                                  if (_usernameChecking) return 'Проверка…';
                                  if (_usernameServerError != null) {
                                    return _usernameServerError!;
                                  }
                                  if (_usernameCheckError != null) {
                                    return _usernameCheckError!;
                                  }
                                  if (_usernameAvailable == true) {
                                    return 'Имя пользователя свободно';
                                  }
                                  return _usernameHint(raw);
                                },
                                serverError: _usernameServerError,
                                serverChecking: _usernameChecking,
                                serverAvailable: _usernameAvailable,
                                atPrefix: true,
                              ),
                              const SizedBox(height: 10),
                              _ValidatedField(
                                key: _pwdFieldKey,
                                hint: 'Пароль',
                                controller: _pwdCtrl,
                                obscure: true,
                                isValid: _passValid,
                                hintText: _passHint,
                              ),
                              const SizedBox(height: 10),
                              _input(
                                'Повторите пароль',
                                _pwd2Ctrl,
                                obscure: true,
                              ),
                              const SizedBox(height: 14),
                              _Age18Checkbox(
                                value: _age18,
                                onChanged: (v) =>
                                    setState(() => _age18 = v ?? false),
                              ),
                              _TermsCheckbox(
                                value: _agreedTerms,
                                onChanged: (v) =>
                                    setState(() => _agreedTerms = v ?? false),
                              ),
                            ],
                          ),
                  ),
                  if (_err != null) ...[
                    const SizedBox(height: 12),
                    AppErrorPanel(
                      title: 'Ошибка авторизации',
                      message: _err!,
                      details: _errDetails,
                      logId: _errLogId,
                    ),
                  ],
                  const SizedBox(height: 16),
                  _PrimaryBtn(
                    label: _isLogin ? 'Войти' : 'Зарегистрироваться',
                    busy: _busy,
                    onTap: _go,
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
                      style: TextStyle(
                        color: GE.sub,
                        fontSize: 10.5,
                        height: 1.4,
                      ),
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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        suffixIcon: widget.obscure
            ? IconButton(
                icon: Icon(
                  _visible ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
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

/// Поле username с постоянной визуальной "@". Символ не входит в значение
/// контроллера и всегда остаётся серым префиксом внутри поля.
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
    return TextField(
      controller: controller,
      focusNode: focusNode,
      style: TextStyle(color: GE.text, fontSize: 14),
      decoration: InputDecoration(
        prefixText: '@',
        prefixStyle: TextStyle(color: GE.sub, fontSize: 14),
        hintText: hint,
        hintStyle: TextStyle(color: GE.sub, fontSize: 14),
        filled: true,
        fillColor: GE.glassFill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
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
  final String? serverError;
  final bool serverChecking;
  final bool? serverAvailable;
  final bool atPrefix;
  const _ValidatedField({
    super.key,
    required this.hint,
    required this.controller,
    required this.isValid,
    required this.hintText,
    this.serverError,
    this.serverChecking = false,
    this.serverAvailable,
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
    final color = widget.serverError != null
        ? GE.red
        : widget.serverChecking
        ? GE.sub
        : widget.serverAvailable == true
        ? GE.green
        : (!touched ? GE.sub : (valid ? GE.green : GE.red));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.atPrefix
            ? _AtPrefixField(
                controller: widget.controller,
                focusNode: _focusNode!,
                hint: widget.hint,
              )
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
                widget.serverChecking
                    ? SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: GE.sub,
                        ),
                      )
                    : Icon(
                        widget.serverError != null
                            ? CupertinoIcons.exclamationmark_circle
                            : !touched
                            ? CupertinoIcons.info_circle
                            : (valid
                                  ? CupertinoIcons.checkmark_circle_fill
                                  : CupertinoIcons.exclamationmark_circle),
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
          shaderCallback: (b) =>
              LinearGradient(colors: [GE.text, GE.primary]).createShader(b),
          child: Text(
            'GhostEcos',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: GE.text,
              letterSpacing: -0.5,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Приватное общение',
          style: TextStyle(color: GE.sub, fontSize: 12),
        ),
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
    return PressScale(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active
              ? GE.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: ThemeService.isMinimal
              ? null
              : (active
                    ? Border.all(color: GE.primary.withValues(alpha: 0.35))
                    : null),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: active ? GE.primary : GE.sub,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
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
  const _PrimaryBtn({
    required this.label,
    required this.busy,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [GE.primary, GE.primary2]),
          borderRadius: BorderRadius.circular(12),
          boxShadow: ThemeService.isMinimal
              ? null
              : [
                  BoxShadow(
                    color: GE.primary.withValues(alpha: 0.4),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: Center(
          child: busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
  }
}

Future<void> _openLegalPage(String path) async {
  await PublicPageLink.open('${GE.baseUrl}$path');
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
      TextSpan(
        style: base,
        children: [
          const TextSpan(
            text: 'Входя или регистрируя аккаунт вы соглашаетесь с ',
          ),
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
        ],
      ),
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
            TextSpan(
              style: base,
              children: [
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
              ],
            ),
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
