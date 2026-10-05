import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/widgets/rich_message_editing_controller.dart';

void main() {
  testWidgets('bold and italic markers keep native offsets', (tester) async {
    final controller = RichMessageEditingController()
      ..text = '**мир** _привет_';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(controller: controller)),
      ),
    );

    final context = tester.element(find.byType(TextField));
    final span = controller.buildTextSpan(
      context: context,
      style: const TextStyle(fontSize: 15),
      withComposing: false,
    );
    final children = span.children!.whereType<TextSpan>().toList();
    expect(children.map((child) => child.text), contains('**'));
    expect(children.map((child) => child.text), contains('_'));
    expect(span.toPlainText(), '**мир** _привет_');
  });
}
