import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../mesh_background.dart';
import '../services/theme_service.dart';
import '../services/update_service.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';

class UpdatesSettingsScreen extends StatefulWidget {
  const UpdatesSettingsScreen({super.key});

  @override
  State<UpdatesSettingsScreen> createState() => _UpdatesSettingsScreenState();
}

class _UpdatesSettingsScreenState extends State<UpdatesSettingsScreen> {
  final _updates = UpdateService.instance;
  String _currentVersion = '…';
  bool _checksEnabled = true;
  bool _checking = false;
  bool _installing = false;
  double _progress = 0;
  AppUpdateCheckResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    await _updates.loadSettings();
    final version = await _updates.currentVersion();
    if (!mounted) return;
    setState(() {
      _checksEnabled = _updates.checksEnabled;
      _currentVersion = version;
    });
  }

  Future<void> _setChecksEnabled(bool enabled) async {
    setState(() => _checksEnabled = enabled);
    await _updates.setChecksEnabled(enabled);
    if (mounted)
      toast.show(enabled ? 'Проверка включена' : 'Проверка выключена');
  }

  Future<void> _checkNow() async {
    if (_checking || _installing) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final result = await _updates.checkStatus();
      if (!mounted) return;
      setState(() {
        _result = result;
        _currentVersion = result.currentVersion;
        _checking = false;
      });
      toast.show(
        result.updateAvailable
            ? 'Доступна версия ${result.latestVersion}'
            : 'Установлена последняя версия',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = error is UpdateException
            ? error.message
            : 'Не удалось проверить обновления';
      });
      toast.show(_error!, level: ToastLevel.error);
    }
  }

  Future<void> _install(AppUpdateInfo info) async {
    if (_installing) return;
    setState(() {
      _installing = true;
      _progress = 0;
      _error = null;
    });
    try {
      await _updates.downloadAndOpen(
        context,
        info,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value.clamp(0, 1));
        },
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _installing = false;
          _error = error is UpdateException
              ? error.message
              : 'Не удалось установить обновление';
        });
        toast.show(_error!, level: ToastLevel.error);
      }
      return;
    }
    if (mounted) setState(() => _installing = false);
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final info = result?.update;
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: const GlassAppBar(showBack: true, titleText: 'Обновления'),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            GlassCard(
              isListSection: true,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                children: [
                  Icon(CupertinoIcons.arrow_down_circle, color: GE.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Проверять обновления автоматически',
                          style: TextStyle(color: GE.text, fontSize: 14),
                        ),
                        if (ThemeService.instance.showDetailedDescriptions)
                          Text(
                            'Проверка при запуске, возврате в приложение и далее по таймеру.',
                            style: TextStyle(color: GE.sub, fontSize: 11.5),
                          ),
                      ],
                    ),
                  ),
                  GhostSwitch(
                    value: _checksEnabled,
                    activeColor: GE.primary,
                    onChanged: _setChecksEnabled,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Проверка версии',
              style: TextStyle(
                color: GE.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            GlassCard(
              isListSection: true,
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _versionLine(result),
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          CupertinoIcons.xmark_circle,
                          color: GE.red,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(color: GE.red, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (_checking || _installing) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: _installing && _progress > 0 ? _progress : null,
                      color: GE.primary,
                      backgroundColor: GE.border,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _installing && _progress > 0
                          ? 'Скачивание ${(_progress * 100).round()}%'
                          : 'Проверяем сервер…',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: GE.sub, fontSize: 11.5),
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (info != null) ...[
                    GlassButton(
                      label: _installing ? 'Скачивание…' : 'Обновить',
                      icon: CupertinoIcons.arrow_down_to_line,
                      primary: true,
                      fullWidth: true,
                      onTap: _installing ? null : () => _install(info),
                    ),
                    const SizedBox(height: 8),
                  ],
                  GlassButton(
                    label: _checking
                        ? 'Проверяем…'
                        : 'Проверить обновления сейчас',
                    icon: CupertinoIcons.refresh,
                    fullWidth: true,
                    onTap: _checking || _installing ? null : _checkNow,
                  ),
                ],
              ),
            ),
            if (ThemeService.instance.showDetailedDescriptions) ...[
              const SizedBox(height: 10),
              Text(
                'При найденной новой версии кнопка «Обновить» откроет стандартный установщик Android.',
                style: TextStyle(color: GE.sub, fontSize: 12, height: 1.35),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _versionLine(AppUpdateCheckResult? result) {
    if (_error != null) {
      return Row(
        children: [
          Expanded(child: _versionText(_currentVersion)),
          Icon(CupertinoIcons.xmark, color: GE.red, size: 20),
        ],
      );
    }
    if (result?.updateAvailable == true) {
      return Row(
        children: [
          Expanded(child: _versionText(result!.currentVersion)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Icon(
              CupertinoIcons.arrow_right,
              color: GE.primary,
              size: 20,
            ),
          ),
          Expanded(child: _versionText(result.latestVersion, accent: true)),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: _versionText(result?.currentVersion ?? _currentVersion),
        ),
        Icon(
          result == null
              ? CupertinoIcons.question_circle
              : CupertinoIcons.checkmark_circle_fill,
          color: result == null ? GE.sub : GE.green,
          size: 20,
        ),
      ],
    );
  }

  Widget _versionText(String version, {bool accent = false}) => Text(
    version,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: accent ? GE.primary : GE.text,
      fontSize: 18,
      fontWeight: FontWeight.w700,
    ),
  );
}
