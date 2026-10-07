import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../services/auth_service.dart';
import 'site_auth_screen.dart';

class AuthScreen extends StatefulWidget {
  final VoidCallback onLoggedIn;
  const AuthScreen({super.key, required this.onLoggedIn});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  int _tab = 0; // 0 вход, 1 регистрация
  final _loginUser = TextEditingController();
  final _loginPass = TextEditingController();
  final _regUser = TextEditingController();
  final _regName = TextEditingController();
  final _regPass = TextEditingController();
  bool _busy = false;
  bool _showPass = false;
  String? _error;
  String? _seed;

  @override
  void dispose() {
    _loginUser.dispose();
    _loginPass.dispose();
    _regUser.dispose();
    _regName.dispose();
    _regPass.dispose();
    super.dispose();
  }

  Future<void> _doLogin() async {
    if (_loginUser.text.trim().isEmpty || _loginPass.text.isEmpty) {
      setState(() => _error = 'Введи имя пользователя и пароль');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await AuthService.instance.login(_loginUser.text, _loginPass.text);
      widget.onLoggedIn();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doRegister() async {
    if (_regUser.text.trim().length < 3) {
      setState(() => _error = 'Имя пользователя — минимум 3 символа');
      return;
    }
    if (_regName.text.trim().isEmpty) {
      setState(() => _error = 'Введи отображаемое имя');
      return;
    }
    if (_regPass.text.length < 8) {
      setState(() => _error = 'Пароль — минимум 8 символов');
      return;
    }
    setState(() { _busy = true; _error = null; _seed = null; });
    try {
      final d = await AuthService.instance.register(
        username: _regUser.text,
        displayName: _regName.text,
        password: _regPass.text,
      );
      final seed = d['seed_phrase']?.toString();
      if (mounted) setState(() => _seed = seed);
      if (seed == null) widget.onLoggedIn();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doGuest() async {
    setState(() { _busy = true; _error = null; });
    try {
      await AuthService.instance.loginAsGuest();
      widget.onLoggedIn();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GG.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              Text(
                'Вход в GhostEcos',
                style: TextStyle(
                  color: GG.paper,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Один аккаунт — чат, Work, соцсеть и банк',
                style: TextStyle(color: GG.muted, fontSize: 13),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: GG.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    _tabBtn(0, 'Вход'),
                    _tabBtn(1, 'Регистрация'),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (_tab == 0) ...[
                _field(_loginUser, 'Имя пользователя', CupertinoIcons.person, false),
                const SizedBox(height: 12),
                _field(_loginPass, 'Пароль', CupertinoIcons.lock, true),
                const SizedBox(height: 16),
                _submit('Войти', _doLogin),
              ] else ...[
                _field(_regUser, 'Имя пользователя (латиница)', CupertinoIcons.person, false),
                const SizedBox(height: 12),
                _field(_regName, 'Отображаемое имя', CupertinoIcons.smiley, false),
                const SizedBox(height: 12),
                _field(_regPass, 'Пароль (минимум 8 символов)', CupertinoIcons.lock, true),
                const SizedBox(height: 16),
                _submit('Создать аккаунт', _doRegister),
                if (_seed != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: GG.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(CupertinoIcons.exclamationmark_triangle_fill,
                                color: GG.yellow, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              'Запиши seed-фразу',
                              style: TextStyle(
                                color: GG.paper,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Это единственный способ восстановить доступ. Больше она не покажется.',
                          style: TextStyle(color: GG.muted, fontSize: 12),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          _seed!,
                          style: TextStyle(
                            color: GG.yellow,
                            fontSize: 16,
                            fontFamily: 'monospace',
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: widget.onLoggedIn,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: GG.violet,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Text('Записал, продолжить'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: GG.red, fontSize: 13)),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(child: Container(height: 1, color: GG.surface2)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('или', style: TextStyle(color: GG.faint, fontSize: 12)),
                  ),
                  Expanded(child: Container(height: 1, color: GG.surface2)),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SiteAuthScreen(
                                onLoggedIn: widget.onLoggedIn,
                              ),
                            ),
                          ),
                  icon: const Icon(CupertinoIcons.globe, size: 18),
                  label: const Text(
                    'Войти через сайт',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: GG.surface2,
                    foregroundColor: GG.paper,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _doGuest,
                  icon: Icon(CupertinoIcons.person_crop_circle, color: GG.dim, size: 18),
                  label: Text(
                    'Продолжить как гость',
                    style: TextStyle(color: GG.dim, fontSize: 14),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide.none,
                    backgroundColor: GG.surface,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Гостю доступны Work и anon-модели без сервера',
                  style: TextStyle(color: GG.faint, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabBtn(int i, String label) {
    final sel = _tab == i;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() { _tab = i; _error = null; _seed = null; }),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: sel ? GG.surface2 : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: sel ? GG.paper : GG.muted,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, IconData icon, bool pass) {
    return TextField(
      controller: c,
      obscureText: pass && !_showPass,
      style: TextStyle(color: GG.paper, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: GG.faint, fontSize: 13),
        prefixIcon: Icon(icon, color: GG.muted, size: 18),
        suffixIcon: pass
            ? IconButton(
                icon: Icon(
                  _showPass ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                  color: GG.muted,
                  size: 18,
                ),
                onPressed: () => setState(() => _showPass = !_showPass),
              )
            : null,
        filled: true,
        fillColor: GG.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      onSubmitted: (_) => _tab == 0 ? _doLogin() : _doRegister(),
    );
  }

  Widget _submit(String label, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _busy ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: GG.violet,
          foregroundColor: Colors.white,
          disabledBackgroundColor: GG.surface2,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(label,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      ),
    );
  }
}
