import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ghost/services/remote_settings_service.dart';
import 'package:ghost/screens/settings_screen.dart';
import 'package:ghost/widgets/remote_settings_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bundleJson = {
    'id': 'network.transport',
    'revision': 1,
    'title': 'Сетевые настройки',
    'category': 'network',
    'min_app_version': '1.2.2',
    'settings': [
      {
        'id': 'prefer_relay',
        'type': 'toggle',
        'title': 'Предпочитать relay',
        'description': 'Демо декларативной настройки.',
        'default': false,
      },
      {
        'id': 'route',
        'type': 'select',
        'title': 'Маршрут',
        'options': [
          {'value': 'auto', 'label': 'Автоматически'},
          {'value': 'direct', 'label': 'Напрямую'},
        ],
        'default': 'auto',
      },
    ],
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('parses supported settings and bounds user values', () {
    final bundle = RemoteSettingsBundle.parse(bundleJson);
    expect(bundle.revision, 1);
    expect(bundle.settings, hasLength(2));
    expect(bundle.settings.first.acceptsValue(true), isTrue);
    expect(bundle.settings.last.acceptsValue('direct'), isTrue);
    expect(bundle.settings.last.acceptsValue('unknown'), isFalse);
  });

  test('persists user values separately from the downloaded schema', () async {
    final service = RemoteSettingsService.instance;
    await service.loadLocal();
    final bundle = RemoteSettingsBundle.parse(bundleJson);
    await service.setValue(bundle, bundle.settings.first, true);

    final prefs = await SharedPreferences.getInstance();
    final saved =
        jsonDecode(prefs.getString('gc_ota_settings_values_v1')!)
            as Map<String, dynamic>;
    expect(saved['network.transport.prefer_relay'], isTrue);
    expect(prefs.getString('gc_ota_settings_bundles_v1'), isNull);
  });

  test('rejects executable settings and malformed sliders', () {
    final executable = {
      'id': 'network.bad',
      'revision': 1,
      'title': 'Bad',
      'category': 'network',
      'settings': [
        {'id': 'x', 'type': 'javascript', 'title': 'Run'},
      ],
    };
    expect(() => RemoteSettingsBundle.parse(executable), throwsFormatException);

    expect(
      () => RemoteSettingDefinition.parse({
        'id': 'amount',
        'type': 'slider',
        'title': 'Amount',
        'min': 10,
        'max': 2,
        'default': 5,
      }),
      throwsFormatException,
    );
  });

  testWidgets('settings hub and OTA panel compile as Flutter widgets', (
    tester,
  ) async {
    expect(const SettingsScreen(embedded: true), isA<Widget>());
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: RemoteSettingsPanel(category: 'network')),
      ),
    );
    expect(find.text('OTA'), findsNothing);
  });
}
