import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/widgets/bot_badge.dart';

void main() {
  testWidgets('bot badge is a compact avatar marker', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BotBadge(size: 20))),
    );

    expect(find.bySemanticsLabel('Бот'), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy_rounded), findsOneWidget);
    expect(find.text('в сети'), findsNothing);
  });

  testWidgets('bot presence renders online and offline labels', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: BotStatusLabel(status: 'online')),
      ),
    );
    expect(find.text('в сети'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: BotStatusLabel(status: 'offline')),
      ),
    );
    expect(find.text('не в сети'), findsOneWidget);
  });
}
