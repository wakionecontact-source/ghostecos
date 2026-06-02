// Smoke-тест приложения. WebView и tray требуют native платформы — не покрываем здесь.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app smoke (placeholder)', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Center(child: Text('GhostEcos')))),
    );
    expect(find.text('GhostEcos'), findsOneWidget);
  });
}
