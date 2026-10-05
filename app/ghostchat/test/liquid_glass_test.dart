import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/widgets/glass.dart';

void main() {
  testWidgets('bounded glass cards survive list scrolling', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (var i = 0; i < 20; i++)
                GlassCard(
                  key: ValueKey('glass-$i'),
                  lite: true,
                  child: SizedBox(
                    height: 72,
                    child: Center(child: Text('card $i')),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('glass-0')), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -620));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('glass-10')), findsOneWidget);
    expect(find.text('card 10'), findsOneWidget);
  });
}
