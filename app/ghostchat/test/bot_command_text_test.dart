import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/widgets/bot_command_text.dart';
import 'package:ghost/widgets/command_highlight.dart';

void main() {
  testWidgets(
    'tapping a bot command sends its arguments but not placeholders',
    (tester) async {
      String? sentCommand;
      expect(
        botCommandRe
            .allMatches('/buy power [число]\n/start')
            .map((match) => match.group(1) ?? match.group(2))
            .toList(),
        ['/buy power', '/start'],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BotCommandText(
              '/buy power [число]\n/start',
              onCommandTap: (command) => sentCommand = command,
            ),
          ),
        ),
      );

      final richText = find.descendant(
        of: find.byType(BotCommandText),
        matching: find.byType(RichText),
      );
      final paragraph = tester.renderObject<RenderParagraph>(richText);
      final commandBounds = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 10),
          )
          .first
          .toRect();
      await tester.tapAt(tester.getTopLeft(richText) + commandBounds.center);
      expect(sentCommand, '/buy power');
      expect(sentCommand, isNot(contains('число')));
    },
  );
}
