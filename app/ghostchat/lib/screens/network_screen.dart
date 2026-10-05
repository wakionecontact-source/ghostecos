// Настройки → Сеть: куда реально уходят запросы (одна строка, read-only) +
// HTTP/SOCKS5-прокси с хостом/портом/типом/ключом. VPN — место зарезервировано
// на будущее, не реализовано.
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';
import '../services/network_settings.dart';
import '../services/api_client.dart';
import '../services/theme_service.dart';

class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});
  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
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
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
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
              'VPN',
              style: TextStyle(
                color: GE.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            GlassCard(
              isListSection: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      CupertinoIcons.shield_lefthalf_fill,
                      size: 20,
                      color: GE.sub,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Скоро',
                        style: TextStyle(color: GE.sub, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
