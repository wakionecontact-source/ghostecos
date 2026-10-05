import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/widgets/room_visibility_mark.dart';

void main() {
  testWidgets('private-room mark has an accessible privacy label', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: RoomVisibilityMark())),
    );

    expect(find.byKey(const ValueKey('room-private-mark')), findsOneWidget);
    expect(find.bySemanticsLabel('Приватная комната'), findsOneWidget);
  });
}
