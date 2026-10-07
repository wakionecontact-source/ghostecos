// Настройки → Сеть: куда идут запросы, ручной HTTP/SOCKS5-прокси и Android VLESS.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_vless/flutter_vless.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';
import '../services/network_settings.dart';
import '../services/api_client.dart';
import '../services/theme_service.dart';
import '../services/vless_service.dart';
import '../services/ws_client.dart';

class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});
  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  final _vlessService = VlessService.instance;
  final _vlessCtrl = TextEditingController();
  bool _vlessProfileVisible = false;
  bool _vlessBusy = false;
  String? _vlessLoadError;

  late bool _enabled = NetworkSettings.instance.enabledNotifier.value;
  late bool _checkConnection =
      NetworkSettings.instance.checkConnectionNotifier.value;
  late ProxyType _type = NetworkSettings.instance.typeNotifier.value;
  late final _hostCtrl = TextEditingController(
    text: NetworkSettings.instance.hostNotifier.value,
  );
  late final _portCtrl = TextEditingController(
    text: NetworkSettings.instance.portNotifier.value?.toString() ?? '',
  );
  late final _keyCtrl = TextEditingController(
    text: NetworkSettings.instance.authKeyNotifier.value,
  );

  @override
  void initState() {
    super.initState();
    _vlessService.status.addListener(_onVlessStatusChanged);
    unawaited(_loadVlessProfile());
  }

  @override
  void dispose() {
    _vlessService.status.removeListener(_onVlessStatusChanged);
    _vlessCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  void _onVlessStatusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadVlessProfile() async {
    if (!Platform.isAndroid) return;
    try {
      await _vlessService.initialize();
      final profile = await _vlessService.loadSavedProfile();
      if (!mounted) return;
      _vlessCtrl.text = profile ?? '';
      setState(() => _vlessLoadError = null);
    } catch (_) {
      if (!mounted) return;
      setState(() => _vlessLoadError = 'Не удалось открыть VLESS-профиль.');
    }
  }

  bool get _vlessActive {
    final state = _vlessService.status.value.connectionState;
    return state == VlessConnectionState.connected ||
        state == VlessConnectionState.connecting ||
        state == VlessConnectionState.disconnecting;
  }

  Future<void> _saveVlessProfile() async {
    if (_vlessCtrl.text.trim().isEmpty) {
      toast.show('Вставь ссылку VLESS');
      return;
    }
    try {
      await _vlessService.saveProfile(_vlessCtrl.text);
      if (mounted) toast.show('Профиль сохранён в защищённом хранилище');
    } on FormatException {
      toast.show('Не удалось разобрать ссылку VLESS');
    } on ArgumentError {
      toast.show('Ссылка VLESS некорректна');
    } catch (_) {
      toast.show('Не удалось сохранить VLESS-профиль');
    }
  }

  Future<void> _connectVless() async {
    if (_vlessBusy) return;
    setState(() => _vlessBusy = true);
    try {
      await _vlessService.connect(_vlessCtrl.text);
      if (mounted) toast.show('Запрос на подключение VLESS отправлен');
    } on VlessPermissionDeniedException {
      toast.show('Android не разрешил создать VPN-подключение');
    } on FormatException {
      toast.show('Не удалось разобрать ссылку VLESS');
    } on ArgumentError {
      toast.show('Профиль VLESS некорректен');
    } catch (_) {
      toast.show(
        'Не удалось подключить VLESS. Проверь профиль и разрешение Android.',
      );
    } finally {
      if (mounted) setState(() => _vlessBusy = false);
    }
  }

  Future<void> _disconnectVless() async {
    if (_vlessBusy) return;
    setState(() => _vlessBusy = true);
    try {
      await _vlessService.disconnect();
      if (mounted) toast.show('VLESS отключён');
    } catch (_) {
      toast.show('Не удалось отключить VLESS');
    } finally {
      if (mounted) setState(() => _vlessBusy = false);
    }
  }

  Future<void> _save() async {
    final port = int.tryParse(_portCtrl.text.trim());
    if (_enabled &&
        (_hostCtrl.text.trim().isEmpty ||
            port == null ||
            port < 1 ||
            port > 65535)) {
      toast.show('Укажи хост и порт прокси');
      return;
    }
    await NetworkSettings.instance.save(
      enabled: _enabled,
      host: _hostCtrl.text.trim(),
      port: port,
      type: _type,
      authKey: _keyCtrl.text.trim(),
    );
    ApiClient().applyProxySettings();
    WsClient.instance.reconnectForNetworkChange();
    if (!mounted) return;
    toast.show('Сохранено');
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: true, titleText: 'Сеть'),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Куда идут запросы',
              style: TextStyle(
                color: GE.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            GlassCard(
              isListSection: true,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(
                children: [
                  Icon(CupertinoIcons.globe, size: 18, color: GE.sub),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      GE.baseUrl,
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (ThemeService.instance.showDetailedDescriptions)
              Text(
                'Всё шифруется на устройстве до отправки (см. Ключи шифрования) — '
                'сервер видит только адрес, куда идёт запрос, не содержимое.',
                style: TextStyle(color: GE.sub, fontSize: 12, height: 1.4),
              ),
            const SizedBox(height: 24),
            Text(
              'Состояние соединения',
              style: TextStyle(
                color: GE.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            GlassCard(
              isListSection: true,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.antenna_radiowaves_left_right,
                    size: 19,
                    color: GE.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Проверять соединение',
                          style: TextStyle(color: GE.text, fontSize: 14),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Показывать уведомление при потере связи и восстановлении',
                          style: TextStyle(color: GE.sub, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  GhostSwitch(
                    value: _checkConnection,
                    activeColor: GE.primary,
                    onChanged: (value) async {
                      setState(() => _checkConnection = value);
                      await NetworkSettings.instance.setCheckConnection(value);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Прокси',
              style: TextStyle(
                color: GE.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            GlassCard(
              isListSection: true,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Использовать прокси',
                          style: TextStyle(color: GE.text, fontSize: 14),
                        ),
                      ),
                      GhostSwitch(
                        value: _enabled,
                        activeColor: GE.primary,
                        onChanged: (v) => setState(() => _enabled = v),
                      ),
                    ],
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    child: _enabled
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 12),
                              Text(
                                'Тип подключения',
                                style: TextStyle(color: GE.sub, fontSize: 11.5),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: _typeChip('HTTP', ProxyType.http),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: _typeChip(
                                      'SOCKS5',
                                      ProxyType.socks5,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              _field(_hostCtrl, 'Хост', 'proxy.example.com'),
                              const SizedBox(height: 8),
                              _field(
                                _portCtrl,
                                'Порт',
                                '1080',
                                keyboardType: TextInputType.number,
                              ),
                              const SizedBox(height: 8),
                              _field(
                                _keyCtrl,
                                'Ключ / пароль (необязательно)',
                                'токен, пароль или логин:пароль',
                                obscure: true,
                              ),
                              if (_type == ProxyType.socks5) ...[
                                const SizedBox(height: 8),
                                Text(
                                  'Полноценный SOCKS5 CONNECT. Домен передаётся прокси без локального DNS. '
                                  'Для авторизации укажи пароль или логин:пароль.',
                                  style: TextStyle(
                                    color: GE.sub,
                                    fontSize: 11,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            GlassButton(
              label: 'Сохранить',
              primary: true,
              fullWidth: true,
              onTap: _save,
            ),
            const SizedBox(height: 24),
            Text(
              'VLESS-туннель',
              style: TextStyle(
                color: GE.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            if (Platform.isAndroid) _vlessCard() else _vlessUnavailableCard(),
          ],
        ),
      ),
    );
  }

  Widget _vlessCard() {
    final active = _vlessActive;
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                CupertinoIcons.shield_lefthalf_fill,
                size: 20,
                color: GE.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _vlessStatusLabel(_vlessService.status.value.connectionState),
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_vlessBusy)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: GE.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Туннель охватывает трафик GhostChat, включая звонки. Другие приложения телефона идут напрямую.',
            style: TextStyle(color: GE.sub, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _vlessCtrl,
            enabled: !active && !_vlessBusy,
            obscureText: !_vlessProfileVisible,
            maxLines: 1,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            style: TextStyle(color: GE.text, fontSize: 13),
            decoration: InputDecoration(
              labelText: 'Ссылка VLESS',
              labelStyle: TextStyle(color: GE.sub),
              hintText: 'vless://…',
              hintStyle: TextStyle(color: GE.sub.withValues(alpha: 0.5)),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: _vlessProfileVisible
                    ? 'Скрыть ссылку'
                    : 'Показать ссылку',
                onPressed: active || _vlessBusy
                    ? null
                    : () => setState(
                        () => _vlessProfileVisible = !_vlessProfileVisible,
                      ),
                icon: Icon(
                  _vlessProfileVisible
                      ? CupertinoIcons.eye_slash
                      : CupertinoIcons.eye,
                  color: GE.sub,
                  size: 18,
                ),
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
          ),
          if (_vlessLoadError != null) ...[
            const SizedBox(height: 8),
            Text(
              _vlessLoadError!,
              style: TextStyle(color: GE.red, fontSize: 12),
            ),
          ],
          if (active) ...[
            const SizedBox(height: 10),
            Text(
              '↑ ${_formatBytes(_vlessService.status.value.upload)}   ↓ ${_formatBytes(_vlessService.status.value.download)}',
              style: TextStyle(color: GE.sub, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GlassButton(
                  label: active ? 'Отключить' : 'Подключить',
                  primary: !active,
                  danger: active,
                  loading: _vlessBusy,
                  onTap: _vlessBusy
                      ? null
                      : active
                      ? _disconnectVless
                      : _connectVless,
                ),
              ),
              if (!active) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: GlassButton(
                    label: 'Сохранить',
                    onTap: _vlessBusy ? null : _saveVlessProfile,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _vlessUnavailableCard() {
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(CupertinoIcons.shield_lefthalf_fill, size: 20, color: GE.sub),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'VLESS-туннель доступен в Android-приложении',
              style: TextStyle(color: GE.sub, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  String _vlessStatusLabel(VlessConnectionState state) {
    return switch (state) {
      VlessConnectionState.connected => 'VLESS подключён',
      VlessConnectionState.connecting => 'Подключение VLESS…',
      VlessConnectionState.disconnected => 'VLESS отключён',
      VlessConnectionState.disconnecting => 'Отключение VLESS…',
      VlessConnectionState.unknown => 'Статус VLESS неизвестен',
    };
  }

  String _formatBytes(int bytes) {
    const units = ['Б', 'КБ', 'МБ', 'ГБ'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  Widget _typeChip(String label, ProxyType type) {
    final active = _type == type;
    return GestureDetector(
      onTap: () => setState(() => _type = type),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
              ? GE.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: active ? GE.primary : GE.borderStrong),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? GE.primary : GE.sub,
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label,
    String hint, {
    TextInputType? keyboardType,
    bool obscure = false,
  }) {
    return TextField(
      controller: c,
      keyboardType: keyboardType,
      obscureText: obscure,
      style: TextStyle(color: GE.text, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: GE.sub),
        hintText: hint,
        hintStyle: TextStyle(color: GE.sub.withValues(alpha: 0.5)),
        isDense: true,
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
