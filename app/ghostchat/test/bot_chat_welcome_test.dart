import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/widgets/bot_chat_welcome.dart';

void main() {
  testWidgets(
    'welcome stays above composer; composer tap sends exactly /start',
    (tester) async {
      String? sentCommand;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: BotChatWelcome(displayName: 'Helper')),
                BotStartPrompt(
                  sending: false,
                  onTap: () => sentCommand = BotChatWelcome.startCommand,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Начни диалог с Helper'), findsOneWidget);
      expect(find.text('Начать'), findsOneWidget);
      expect(find.text('Отправить /start'), findsOneWidget);
      await tester.tap(find.text('Отправить /start'));
      expect(sentCommand, '/start');
    },
  );
}
