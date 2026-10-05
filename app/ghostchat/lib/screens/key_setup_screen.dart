import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../mesh_background.dart';
import '../services/chat_repo.dart';
import '../services/crypto_service.dart';
import '../theme.dart';
import '../widgets/glass.dart';

enum _KeySetupPhase {
  loading,
  existingServer,
  serverKeyMismatch,
  serverCopyMissing,
  chooseStorage,
  passwordExisting,
  passwordNew,
  error,
}

/// Явная развилка ключа после авторизации. Здесь нет доступа к чатам и WS:
/// сначала проверяется принадлежность приватника серверному public key, и лишь
/// потом запускается MainShell.
class KeySetupScreen extends StatefulWidget {
  final VoidCallback onDone;

  const KeySetupScreen({super.key, required this.onDone});

  @override
  State<KeySetupScreen> createState() => _KeySetupScreenState();
}

class _KeySetupScreenState extends State<KeySetupScreen> {
  _KeySetupPhase _phase = _KeySetupPhase.loading;
  KeyServerState? _server;
  bool _createNew = false;
  bool _repairServerCopy = false;
  bool _reuseCurrentKey = false;
  bool _busy = false;
  String? _error;
  final _password = TextEditingController();

  void _skipKeySetup() {
    ChatRepo.instance.skipKeySyncForSession();
    widget.onDone();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final state = await ChatRepo.instance.prepareKeySetupForLogin();
      if (!mounted) return;
      _server = state;
      final account = await ChatRepo.instance.currentUsername();
      final hasLocal =
          account != null &&
          await CryptoService.instance.hasStoredPrivateKey(account: account);
      if (!mounted) return;

      // A server blob is not proof that this device has the same identity.
      // Verify the public part before showing "found key" or entering the app.
      // In local mode the server may legitimately expose the owner/device pub
      // of another device, so an existing local key remains authoritative.
      final mode = state.mode?.trim().toLowerCase();
      if (mode == 'local' && hasLocal) {
        setState(() => _phase = _KeySetupPhase.loading);
        widget.onDone();
        return;
      }
      if (state.hasServerCopy) {
        if (!hasLocal || account == null || account.trim().isEmpty) {
          setState(() => _phase = _KeySetupPhase.existingServer);
          return;
        }
        final localPub = base64Encode(
          await CryptoService.instance.myPublicKeyRaw(account: account),
        );
        if (!mounted) return;
        final serverPub = state.publicKey?.trim();
        if (serverPub != null &&
            serverPub.isNotEmpty &&
            serverPub == localPub) {
          // The identity is already present locally and was verified against
          // the server. There is no reason to ask for the recovery password on
          // every cold start/login.
          widget.onDone();
        } else {
          // A missing or different server public key must never be presented
          // as a valid found key. Recovery remains explicit and password-gated.
          setState(() => _phase = _KeySetupPhase.serverKeyMismatch);
        }
        return;
      }

      // The server may remember server mode while the encrypted copy is
      // absent. This is an inconsistent state, not a password challenge.
      if (state.mode?.trim().toLowerCase() == 'server') {
        var reuseCurrentKey = false;
        if (hasLocal) {
          final localPub = base64Encode(
            await CryptoService.instance.myPublicKeyRaw(account: account),
          );
          reuseCurrentKey =
              state.publicKey == null ||
              state.publicKey!.isEmpty ||
              state.publicKey == localPub;
        }
        _reuseCurrentKey = reuseCurrentKey;
        setState(() => _phase = _KeySetupPhase.serverCopyMissing);
        return;
      }
      if (state.mode?.trim().toLowerCase() == 'local' && hasLocal) {
        final result = await ChatRepo.instance.completeKeySetup(
          mode: 'local',
          createNew: false,
          knownState: state,
        );
        if (!mounted) return;
        if (result == KeySyncOutcome.ok) {
          widget.onDone();
        } else {
          setState(() {
            _phase = _KeySetupPhase.error;
            _error = 'Не удалось подготовить локальный ключ.';
          });
        }
        return;
      }
      setState(() => _phase = _KeySetupPhase.chooseStorage);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _KeySetupPhase.error;
        _error = 'Не удалось проверить ключ на сервере. Попробуй ещё раз.';
      });
    }
  }

  Future<void> _useExistingServer() async {
    setState(() {
      _phase = _KeySetupPhase.passwordExisting;
      _error = null;
    });
  }

  Future<void> _createNewKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Создать новый ключ?', style: TextStyle(color: GE.text)),
        content: Text(
          'Старая серверная копия будет заменена после выбора места хранения. Сообщения, зашифрованные старым ключом, могут стать недоступны. Продолжить?',
          style: TextStyle(color: GE.sub, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text('Создать', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _createNew = true;
      _repairServerCopy = false;
      _reuseCurrentKey = false;
      _phase = _KeySetupPhase.chooseStorage;
      _error = null;
    });
  }

  void _createServerCopy() {
    setState(() {
      _createNew = false;
      _repairServerCopy = true;
      _phase = _KeySetupPhase.passwordNew;
      _error = null;
    });
  }

  Future<void> _chooseStorage(String mode) async {
    if (mode == 'server') {
      setState(() {
        _repairServerCopy = false;
        _phase = _KeySetupPhase.passwordNew;
        _error = null;
      });
      return;
    }
    await _finish(mode: 'local');
  }

  Future<void> _submitPassword() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Введи пароль аккаунта.');
      return;
    }
    await _finish(mode: 'server', password: _password.text);
  }

  Future<void> _finish({required String mode, String? password}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ChatRepo.instance.completeKeySetup(
      mode: mode,
      createNew: _createNew,
      password: password,
      knownState: _server,
    );
    if (!mounted) return;
    if (result == KeySyncOutcome.ok) {
      widget.onDone();
      return;
    }
    setState(() {
      _busy = false;
      _phase = _KeySetupPhase.error;
      _error = switch (result) {
        KeySyncOutcome.needPassword =>
          'Не удалось расшифровать ключ. Проверь пароль.',
        KeySyncOutcome.serverCopyMissing =>
          'На сервере нет зашифрованной копии. Сначала создай её.',
        KeySyncOutcome.keyMismatch =>
          'Ключ не совпал с публичным ключом аккаунта. Серверная копия не принята.',
        _ => 'Не удалось сохранить настройки ключа. Попробуй ещё раз.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 390),
                child: GlassCard(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _body(),
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
    );
  }

  Widget _body() {
    switch (_phase) {
      case _KeySetupPhase.loading:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: GE.primary),
            const SizedBox(height: 16),
            Text(
              'Проверяем ключ на сервере…',
              style: TextStyle(color: GE.text),
            ),
          ],
        );
      case _KeySetupPhase.existingServer:
        return _existingBody();
      case _KeySetupPhase.serverKeyMismatch:
        return _serverKeyMismatchBody();
      case _KeySetupPhase.serverCopyMissing:
        return _serverCopyMissingBody();
      case _KeySetupPhase.chooseStorage:
        return _storageBody();
      case _KeySetupPhase.passwordExisting:
        return _passwordBody(
          title: 'Восстановить ключ',
          subtitle:
              'Введи пароль ещё раз. Он используется только на устройстве для расшифровки серверной копии.',
        );
      case _KeySetupPhase.passwordNew:
        return _passwordBody(
          title: _repairServerCopy
              ? 'Сохранить копию на сервере'
              : 'Зашифровать ключ',
          subtitle: _repairServerCopy
              ? 'Серверной копии нет. Введи пароль, чтобы зашифровать текущий ключ Argon2id + AES-GCM и сохранить его на сервере.'
              : 'Введи пароль аккаунта. Приватный ключ будет зашифрован Argon2id + AES-GCM до отправки на сервер.',
        );
      case _KeySetupPhase.error:
        return _errorBody();
    }
  }

  Widget _existingBody() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(CupertinoIcons.lock_shield, color: GE.primary, size: 44),
      const SizedBox(height: 14),
      Text(
        'Найдена копия ключа на сервере',
        style: TextStyle(
          color: GE.text,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Локального ключа на этом устройстве нет. Можно восстановить серверную копию паролем или создать новую пару. Новый ключ может сделать старые сообщения недоступными.',
        textAlign: TextAlign.center,
        style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 20),
      GlassButton(
        label: 'Использовать ключ с сервера',
        icon: CupertinoIcons.cloud_download,
        primary: true,
        fullWidth: true,
        onTap: _useExistingServer,
      ),
      const SizedBox(height: 10),
      GlassButton(
        label: 'Создать новый ключ',
        icon: CupertinoIcons.refresh,
        fullWidth: true,
        onTap: _createNewKey,
      ),
    ],
  );

  Widget _serverKeyMismatchBody() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(CupertinoIcons.exclamationmark_triangle, color: GE.red, size: 44),
      const SizedBox(height: 14),
      Text(
        'Ключ не подтверждён',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: GE.text,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        _server?.publicKey?.trim().isNotEmpty == true
            ? 'Публичный ключ на сервере не совпал с локальным. Автоматически принимать другую пару нельзя.'
            : 'У серверной копии отсутствует публичный ключ. Нельзя безопасно подтвердить, какой приватный ключ нужно восстановить.',
        textAlign: TextAlign.center,
        style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 20),
      if (_server?.publicKey?.trim().isNotEmpty == true) ...[
        GlassButton(
          label: 'Проверить и восстановить',
          icon: CupertinoIcons.cloud_download,
          primary: true,
          fullWidth: true,
          onTap: _useExistingServer,
        ),
        const SizedBox(height: 10),
      ],
      GlassButton(
        label: 'Создать новую пару',
        icon: CupertinoIcons.refresh,
        fullWidth: true,
        onTap: _createNewKey,
      ),
      const SizedBox(height: 10),
      GlassButton(
        label: 'Повторить проверку',
        icon: CupertinoIcons.refresh,
        fullWidth: true,
        onTap: () {
          setState(() {
            _phase = _KeySetupPhase.loading;
            _error = null;
          });
          _load();
        },
      ),
    ],
  );

  Widget _serverCopyMissingBody() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.cloud_off_outlined, color: GE.red, size: 44),
      const SizedBox(height: 14),
      Text(
        'Серверная копия не найдена',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: GE.text,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Для аккаунта выбран серверный режим, но зашифрованного приватного ключа на сервере нет. Пароль не будет проверяться у отсутствующей копии.',
        textAlign: TextAlign.center,
        style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 20),
      GlassButton(
        label: _reuseCurrentKey
            ? 'Сохранить текущий ключ на сервере'
            : 'Создать новую пару ключей',
        icon: _reuseCurrentKey
            ? CupertinoIcons.cloud_upload
            : CupertinoIcons.refresh,
        primary: true,
        fullWidth: true,
        onTap: _reuseCurrentKey ? _createServerCopy : _createNewKey,
      ),
      const SizedBox(height: 10),
      GlassButton(
        label: 'Только на устройстве',
        icon: Icons.phonelink_lock_outlined,
        fullWidth: true,
        onTap: () => _chooseStorage('local'),
      ),
      const SizedBox(height: 10),
      GlassButton(
        label: 'Повторить проверку',
        icon: CupertinoIcons.refresh,
        fullWidth: true,
        onTap: () {
          setState(() {
            _phase = _KeySetupPhase.loading;
            _error = null;
          });
          _load();
        },
      ),
    ],
  );

  Widget _storageBody() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.key_outlined, color: GE.primary, size: 44),
      const SizedBox(height: 14),
      Text(
        'Где хранить ключ?',
        style: TextStyle(
          color: GE.text,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Локально — приватный ключ остаётся на устройстве. На сервере — хранится только зашифрованная копия, защищённая твоим паролем.',
        textAlign: TextAlign.center,
        style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 20),
      GlassButton(
        label: 'Только на устройстве',
        icon: Icons.phonelink_lock_outlined,
        fullWidth: true,
        loading: _busy,
        onTap: () => _chooseStorage('local'),
      ),
      const SizedBox(height: 10),
      GlassButton(
        label: 'На сервере (с паролем)',
        icon: Icons.cloud_done_outlined,
        primary: true,
        fullWidth: true,
        loading: _busy,
        onTap: () => _chooseStorage('server'),
      ),
      if (_error != null) ...[
        const SizedBox(height: 10),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: GE.red, fontSize: 12),
        ),
      ],
    ],
  );

  Widget _passwordBody({required String title, required String subtitle}) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.lock, color: GE.primary, size: 44),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              color: GE.text,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 18),
          GlassInput(
            controller: _password,
            hint: 'Пароль аккаунта',
            icon: CupertinoIcons.lock,
            obscure: true,
            onSubmitted: (_) => _submitPassword(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: GE.red, fontSize: 12),
            ),
          ],
          const SizedBox(height: 16),
          GlassButton(
            label: 'Продолжить',
            icon: CupertinoIcons.checkmark_shield,
            primary: true,
            fullWidth: true,
            loading: _busy,
            onTap: _submitPassword,
          ),
        ],
      );

  Widget _errorBody() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(CupertinoIcons.exclamationmark_triangle, color: GE.red, size: 44),
      const SizedBox(height: 14),
      Text(
        'Ключ не подготовлен',
        style: TextStyle(
          color: GE.text,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        _error ?? 'Попробуй ещё раз.',
        textAlign: TextAlign.center,
        style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 18),
      GlassButton(
        label: 'Повторить',
        icon: CupertinoIcons.refresh,
        primary: true,
        fullWidth: true,
        loading: _busy,
        onTap: () {
          setState(() {
            _phase = _KeySetupPhase.loading;
            _error = null;
          });
          _load();
        },
      ),
    ],
  );
}
