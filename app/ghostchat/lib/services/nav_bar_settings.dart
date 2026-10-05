// Кастомизация нижнего бара: порядок табов + переопределённые подписи.
// По умолчанию — порядок объявления Section.values, подписи из Section.label.
// Персист — SharedPreferences (JSON), тот же паттерн, что ThemeService.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../screens/main_shell.dart' show Section;
import 'theme_service.dart';

class NavBarSettings {
  NavBarSettings._();
  static final NavBarSettings instance = NavBarSettings._();

  static const _kOrderKey = 'navbar_order_v1';
  static const _kLabelsKey = 'navbar_labels_v1';
  static const _kBackgroundKey = 'navbar_background_v1';
  static const _kLabelsVisibleKey = 'navbar_labels_visible_v1';
  static const _kSelectedBackgroundKey = 'navbar_selected_background_v1';
  static const _kSelectedScaleKey = 'navbar_selected_scale_v1';
  static const _kSelectedFlyoutKey = 'navbar_selected_flyout_v1';

  final ValueNotifier<List<Section>> orderNotifier = ValueNotifier(
    List.of(Section.values),
  );
  final ValueNotifier<Map<String, String>> labelOverridesNotifier =
      ValueNotifier({});
  final ValueNotifier<bool> backgroundNotifier = ValueNotifier(true);
  final ValueNotifier<bool> labelsVisibleNotifier = ValueNotifier(true);
  final ValueNotifier<bool> selectedBackgroundNotifier = ValueNotifier(true);
  final ValueNotifier<bool> selectedScaleNotifier = ValueNotifier(false);
  final ValueNotifier<bool> selectedFlyoutNotifier = ValueNotifier(false);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final orderRaw = prefs.getString(_kOrderKey);
    if (orderRaw != null) {
      try {
        final names = (jsonDecode(orderRaw) as List).cast<String>();
        final byName = {for (final s in Section.values) s.name: s};
        final order = names.map((n) => byName[n]).whereType<Section>().toList();
        // Секции, которых нет в сохранённом списке (например добавили новую
        // в коде после того как юзер уже сохранил порядок) — дописываем в конец.
        for (final s in Section.values) {
          if (!order.contains(s)) order.add(s);
        }
        if (order.length == Section.values.length) orderNotifier.value = order;
      } catch (_) {}
    }
    final labelsRaw = prefs.getString(_kLabelsKey);
    if (labelsRaw != null) {
      try {
        labelOverridesNotifier.value = Map<String, String>.from(
          jsonDecode(labelsRaw) as Map,
        );
      } catch (_) {}
    }
    backgroundNotifier.value =
        prefs.getBool(_kBackgroundKey) ??
        ThemeService.instance.navBarPlateNotifier.value;
    labelsVisibleNotifier.value = prefs.getBool(_kLabelsVisibleKey) ?? true;
    selectedBackgroundNotifier.value =
        prefs.getBool(_kSelectedBackgroundKey) ?? true;
    selectedScaleNotifier.value = prefs.getBool(_kSelectedScaleKey) ?? false;
    selectedFlyoutNotifier.value = prefs.getBool(_kSelectedFlyoutKey) ?? false;
  }

  Future<void> save({
    required List<Section> order,
    required Map<String, String> labelOverrides,
  }) async {
    orderNotifier.value = order;
    labelOverridesNotifier.value = labelOverrides;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kOrderKey,
      jsonEncode(order.map((s) => s.name).toList()),
    );
    await prefs.setString(_kLabelsKey, jsonEncode(labelOverrides));
  }

  Future<void> setBackgroundEnabled(bool value) async {
    backgroundNotifier.value = value;
    await ThemeService.instance.setNavBarPlateEnabled(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBackgroundKey, value);
  }

  Future<void> setLabelsVisible(bool value) async {
    labelsVisibleNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLabelsVisibleKey, value);
  }

  Future<void> setSelectedBackground(bool value) async {
    selectedBackgroundNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSelectedBackgroundKey, value);
  }

  Future<void> setSelectedScale(bool value) async {
    selectedScaleNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSelectedScaleKey, value);
  }

  Future<void> setSelectedFlyout(bool value) async {
    selectedFlyoutNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSelectedFlyoutKey, value);
  }

  String labelFor(Section s) => labelOverridesNotifier.value[s.name] ?? s.label;
}
