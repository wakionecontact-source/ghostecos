// Кастомизация порядка категорий в хабе Настроек (зажатие → драг). Персист —
// SharedPreferences (JSON список ключей), тот же паттерн, что NavBarSettings.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ключ категории → заголовок (для шторки переупорядочивания).
const Map<String, String> settingsCategoryLabels = {
  'appearance': 'Оформление',
  'security': 'Безопасность',
  'beta': 'Бета-функции',
  'privacy': 'Система',
  'account': 'Аккаунт',
  'data': 'Данные',
  'soon': 'Скоро',
  'network': 'Сеть',
  'dev': 'Разработка',
  'other': 'Прочее',
};

/// Категории, содержащие экспериментальные возможности. Экран настроек
/// использует этот набор, чтобы одинаково помечать все beta-разделы и не
/// разносить проверку по отдельным виджетам.
const Set<String> settingsBetaCategoryKeys = {'beta'};

/// Порядок по умолчанию — по частоте использования и важности: Оформление и
/// Система вперёд, редкие разделы — в конец, а Бета-функции всегда последние.
const List<String> _defaultOrder = [
  'appearance',
  'privacy',
  'security',
  'account',
  'data',
  'soon',
  'network',
  'dev',
  'other',
  'beta',
];

class SettingsOrder {
  SettingsOrder._();
  static final SettingsOrder instance = SettingsOrder._();

  static const _kKey = 'settings_category_order_v1';
  bool _loaded = false;

  final ValueNotifier<List<String>> orderNotifier = ValueNotifier(
    List.of(_defaultOrder),
  );

  List<String> _normalizeOrder(Iterable<String> keys) {
    final order = <String>[];
    for (final key in keys) {
      if (_defaultOrder.contains(key) && !order.contains(key)) {
        order.add(key);
      }
    }
    for (final key in _defaultOrder) {
      if (!order.contains(key)) order.add(key);
    }
    // Бета-раздел — служебный и всегда остаётся последним, включая старые
    // сохранённые порядки и ручную перестановку через экран настроек.
    order.remove('beta');
    order.add('beta');
    return order;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final savedOrder = decoded.whereType<String>().toList();
      final normalizedOrder = _normalizeOrder(savedOrder);
      orderNotifier.value = normalizedOrder;
      if (!listEquals(savedOrder, normalizedOrder)) {
        await prefs.setString(_kKey, jsonEncode(normalizedOrder));
      }
    } catch (_) {}
  }

  Future<void> save(List<String> order) async {
    _loaded = true;
    final normalizedOrder = _normalizeOrder(order);
    orderNotifier.value = normalizedOrder;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, jsonEncode(normalizedOrder));
  }
}
