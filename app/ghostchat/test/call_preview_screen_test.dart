import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/screens/call_preview_screen.dart';

void main() {
  testWidgets('call entry point is enabled and remains themed', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CallPreviewScreen(username: 'mira', displayName: 'Mira'),
      ),
    );
    await tester.pump();

    expect(callEntryPointEnabled, isTrue);
    expect(find.text('Mira'), findsOneWidget);
    expect(find.text('@mira'), findsOneWidget);
    expect(find.text('Звонки доступны'), findsOneWidget);
    expect(find.textContaining('Аудио- и видеозвонки работают'), findsOneWidget);
  });
}
