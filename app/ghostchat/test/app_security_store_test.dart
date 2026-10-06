import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ghost/services/app_security_store.dart';
import 'package:ghost/screens/security_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'auto-lock delay persists and main unlock removes nested environments',
    () async {
      SharedPreferences.setMockInitialValues({});
      final security = AppSecurityStore.instance;
      await security.load();

      expect(security.autoLockDelaySeconds, 0);
      await security.setAutoLockDelaySeconds(300);
      await security.setPrimaryCode('main-password');

      final root = await security.createScenario('Root', 'root-password');
      expect(root, isNotNull);
      final nested = await security.createScenario(
        'Nested',
        'nested-password',
        parentId: root!.id,
      );
      expect(nested, isNotNull);
      final deeplyNested = await security.createScenario(
        'Deep',
        'deep-password',
        parentId: nested!.id,
      );
      expect(deeplyNested, isNotNull);

      final safeUnlock = await security.unlock('deep-password');
      expect(safeUnlock.mode, SecurityUnlockMode.scenario);
      expect(security.scenarioById(deeplyNested!.id), isNotNull);

      final normalUnlock = await security.unlock('main-password');
      expect(normalUnlock.mode, SecurityUnlockMode.normal);
      expect(normalUnlock.removedScenarioIds, {nested.id, deeplyNested.id});
      expect(security.scenarioById(root.id), isNotNull);
      expect(security.scenarioById(nested.id), isNull);
      expect(security.scenarioById(deeplyNested.id), isNull);
      expect(security.activeScenarioId, isNull);

      final prefs = await SharedPreferences.getInstance();
      final saved =
          jsonDecode(prefs.getString('ghostchat_app_security_v2')!)
              as Map<String, dynamic>;
      expect(saved['auto_lock_delay_seconds'], 300);
    },
  );

  testWidgets('auto-lock waits in background and cancels on resume', (
    tester,
  ) async {
    final security = AppSecurityStore.instance;
    await security.setPrimaryCode('lifecycle-password');
    await security.setAutoLockDelaySeconds(15);
    final scenario = await security.createScenario(
      'Timer environment',
      'timer-password',
    );
    expect(scenario, isNotNull);

    await tester.pumpWidget(
      MaterialApp(
        home: SecurityGate(
          child: const Scaffold(body: Center(child: Text('Secret content'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Приложение заблокировано'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'timer-password');
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(find.text('Secret content'), findsOneWidget);
    expect(security.activeScenarioId, scenario!.id);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 10));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Приложение заблокировано'), findsNothing);
    expect(security.activeScenarioId, scenario.id);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 14));
    expect(find.text('Приложение заблокировано'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(
      find.text(
        'Введите основной код для обычного режима или код безопасной среды.',
      ),
      findsOneWidget,
    );
    expect(security.activeScenarioId, scenario.id);
  });
}
