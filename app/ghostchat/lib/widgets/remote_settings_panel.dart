import 'dart:async';

import 'package:flutter/material.dart';

import '../services/remote_settings_service.dart';
import '../theme.dart';
import 'glass.dart';

/// Renders server-delivered settings inside an existing Settings category.
/// The server supplies labels and bounded values, never executable UI code.
class RemoteSettingsPanel extends StatelessWidget {
  final String category;

  const RemoteSettingsPanel({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    final service = RemoteSettingsService.instance;
    return ValueListenableBuilder<int>(
      valueListenable: service.revisionNotifier,
      builder: (context, _, _) {
        final bundles = service.bundlesForCategory(category);
        if (bundles.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final bundle in bundles) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        bundle.title,
                        style: TextStyle(
                          color: GE.sub,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    Text(
                      'OTA',
                      style: TextStyle(
                        color: GE.primary,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.7,
                      ),
                    ),
                  ],
                ),
              ),
              GlassCard(
                isListSection: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (var index = 0; index < bundle.settings.length; index++)
                      Column(
                        children: [
                          RemoteSettingControl(
                            key: ValueKey(
                              '${bundle.id}.${bundle.settings[index].id}',
                            ),
                            bundle: bundle,
                            setting: bundle.settings[index],
                            value: service.valueFor(
                              bundle,
                              bundle.settings[index],
                            ),
                          ),
                          if (index < bundle.settings.length - 1)
                            Divider(
                              height: 1,
                              color: GE.glassBorder,
                              indent: 16,
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class RemoteSettingControl extends StatefulWidget {
  final RemoteSettingsBundle bundle;
  final RemoteSettingDefinition setting;
  final Object? value;

  const RemoteSettingControl({
    super.key,
    required this.bundle,
    required this.setting,
    required this.value,
  });

  @override
  State<RemoteSettingControl> createState() => _RemoteSettingControlState();
}

class _RemoteSettingControlState extends State<RemoteSettingControl> {
  late Object? _draft;
  late final TextEditingController _textController;
  late final FocusNode _textFocusNode;
  Timer? _textSaveTimer;

  @override
  void initState() {
    super.initState();
    _draft = widget.value;
    _textController = TextEditingController(
      text: widget.value as String? ?? '',
    );
    _textFocusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant RemoteSettingControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _draft = widget.value;
      if (widget.setting.type == 'text' && !_textFocusNode.hasFocus) {
        _textController.text = widget.value as String? ?? '';
      }
    }
  }

  @override
  void dispose() {
    _textSaveTimer?.cancel();
    if (widget.setting.type == 'text' && _draft != widget.value) {
      unawaited(_save(_draft));
    }
    _textController.dispose();
    _textFocusNode.dispose();
    super.dispose();
  }

  Future<void> _save(Object? value) async {
    if (!widget.setting.acceptsValue(value)) return;
    if (mounted) setState(() => _draft = value);
    await RemoteSettingsService.instance.setValue(
      widget.bundle,
      widget.setting,
      value,
    );
  }

  @override
  Widget build(BuildContext context) {
    final setting = widget.setting;
    final textStyle = TextStyle(color: GE.text, fontSize: 14);
    final subtitle = setting.description.isEmpty
        ? null
        : Text(
            setting.description,
            style: TextStyle(color: GE.sub, fontSize: 11.5),
          );

    switch (setting.type) {
      case 'toggle':
        return SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(setting.title, style: textStyle),
          subtitle: subtitle,
          value: _draft as bool? ?? false,
          activeThumbColor: GE.primary,
          onChanged: (value) => unawaited(_save(value)),
        );
      case 'select':
        final current = _draft as String? ?? setting.defaultValue as String;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(setting.title, style: textStyle),
          subtitle: subtitle,
          trailing: DropdownButton<String>(
            value: current,
            underline: const SizedBox.shrink(),
            dropdownColor: GE.bgDeep,
            style: TextStyle(color: GE.text, fontSize: 12),
            items: [
              for (final option in setting.options)
                DropdownMenuItem<String>(
                  value: option.value,
                  child: Text(option.label),
                ),
            ],
            onChanged: (value) {
              if (value != null) unawaited(_save(value));
            },
          ),
        );
      case 'slider':
        final current = (_draft as num? ?? setting.defaultValue as num)
            .toDouble()
            .clamp(setting.minimum, setting.maximum)
            .toDouble();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(setting.title, style: textStyle)),
                  Text(
                    _formatNumber(current),
                    style: TextStyle(
                      color: GE.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              if (setting.description.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(setting.description, style: subtitle!.style),
              ],
              Slider(
                value: current,
                min: setting.minimum,
                max: setting.maximum,
                divisions: setting.divisions,
                activeColor: GE.primary,
                onChanged: (value) => setState(() => _draft = value),
                onChangeEnd: (value) => unawaited(_save(value)),
              ),
            ],
          ),
        );
      case 'text':
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(setting.title, style: textStyle),
              if (setting.description.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(setting.description, style: subtitle!.style),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: _textController,
                focusNode: _textFocusNode,
                maxLength: setting.maxLength,
                style: TextStyle(color: GE.text, fontSize: 13),
                cursorColor: GE.primary,
                decoration: InputDecoration(
                  isDense: true,
                  counterStyle: TextStyle(color: GE.sub, fontSize: 10),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: GE.glassBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: GE.primary),
                  ),
                ),
                onChanged: (value) {
                  _draft = value;
                  _textSaveTimer?.cancel();
                  _textSaveTimer = Timer(
                    const Duration(milliseconds: 450),
                    () => unawaited(_save(value)),
                  );
                },
                onEditingComplete: () {
                  _textSaveTimer?.cancel();
                  unawaited(_save(_textController.text));
                  _textFocusNode.unfocus();
                },
              ),
            ],
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  String _formatNumber(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);
}
