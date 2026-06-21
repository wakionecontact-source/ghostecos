// Тесты ThemeService: пресеты валидны, переключение перезаписывает GE.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ghost/services/theme_service.dart';
import 'package:ghost/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('Все пресеты имеют уникальный id и непустые поля', () {
    final presets = ThemeService.instance.presets;
    expect(presets.length, greaterThanOrEqualTo(5),
        reason: 'ожидаем минимум 5 тем по ТЗ');
    final ids = presets.map((p) => p.id).toSet();
    expect(ids.length, equals(presets.length),
        reason: 'дубликат id среди пресетов');
    for (final p in presets) {
      expect(p.name.isNotEmpty, isTrue);
      expect(p.subtitle.isNotEmpty, isTrue);
      // Все цвета должны быть отличны от транспарентного «забыли»-значения.
      expect(p.bg.a, greaterThan(0.0));
      expect(p.primary.a, greaterThan(0.0));
      expect(p.text.a, greaterThan(0.0));
    }
  });

  test('setPreset перезаписывает GE.primary', () async {
    final sunset = ThemeService.instance.presets.firstWhere((p) => p.id == 'sunset');
    await ThemeService.instance.setPreset('sunset');
    expect(GE.primary, equals(sunset.primary));
    expect(GE.bg, equals(sunset.bg));
  });

  test('setPreset с неизвестным id — fallback на первый пресет', () async {
    final first = ThemeService.instance.presets.first;
    await ThemeService.instance.setPreset('definitely-not-exists');
    expect(GE.primary, equals(first.primary));
  });

  test('Светлая тема ivory — brightness Light', () {
    final ivory = ThemeService.instance.presets.firstWhere((p) => p.id == 'ivory');
    expect(ivory.brightness, equals(Brightness.light));
  });

  test('notifier эмитит при смене темы', () async {
    int emitted = 0;
    final listener = () => emitted++;
    ThemeService.instance.notifier.addListener(listener);
    await ThemeService.instance.setPreset('forest');
    await ThemeService.instance.setPreset('aurora');
    ThemeService.instance.notifier.removeListener(listener);
    expect(emitted, greaterThanOrEqualTo(2));
  });
}
