import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/ui/ui_config.dart';
import 'package:ghost/ui/ui_registry.dart';

Map<String, dynamic> _read(String name) =>
    jsonDecode(File('assets/ui/$name.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('дефолтный конфиг валиден и покрывает все элементы реестра', () {
    final config = UiConfig.fromMap(_read('ghost_default'));
    expect(config.id, 'ghost_default');
    for (final spec in UiRegistry.instance.styleable) {
      expect(
        config.valuesOf(spec.id),
        isNotEmpty,
        reason: 'Нет конфига для ${spec.id}',
      );
    }
  });

  test('тестовый конфиг Aurora валиден', () {
    final config = UiConfig.fromMap(_read('ghost_aurora_test'));
    expect(config.tokens.radius, 24);
    expect(config.valuesOf('chat.list.row')['avatarSide'], 'right');
  });

  test('радиус у элемента запрещён — только глобально', () {
    final map = _read('ghost_default');
    (map['elements'] as Map<String, dynamic>)['nav.bar']['radius'] = 12;
    expect(
      () => UiConfig.fromMap(map),
      throwsA(
        isA<UiConfigError>().having(
          (e) => e.errors.join('\n'),
          'errors',
          contains('только глобально'),
        ),
      ),
    );
  });

  test('пропущенный элемент реестра — ошибка', () {
    final map = _read('ghost_default');
    (map['elements'] as Map<String, dynamic>).remove('settings.row');
    expect(
      () => UiConfig.fromMap(map),
      throwsA(
        isA<UiConfigError>().having(
          (e) => e.errors.join('\n'),
          'errors',
          contains('Нет конфига для элемента "settings.row"'),
        ),
      ),
    );
  });

  test('неизвестное свойство — ошибка', () {
    final map = _read('ghost_default');
    (map['elements'] as Map<String, dynamic>)['app.bar']['borderWidth'] = 2;
    expect(() => UiConfig.fromMap(map), throwsA(isA<UiConfigError>()));
  });

  test('заблокированный элемент нельзя оформить', () {
    final map = _read('ghost_default');
    (map['elements'] as Map<String, dynamic>)['auth.key_entry'] = <String, dynamic>{};
    expect(() => UiConfig.fromMap(map), throwsA(isA<UiConfigError>()));
  });
}
