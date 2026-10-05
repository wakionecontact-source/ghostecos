import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/core/models/bot_reply_markup.dart';
import 'package:ghost/services/db_service.dart';
import 'package:ghost/widgets/bot_reply_keyboard.dart';

void main() {
  group('BotReplyMarkup', () {
    test('parses inline callbacks and safe links', () {
      final markup = BotReplyMarkup.tryParse({
        'inline_keyboard': [
          [
            {'text': 'Купить', 'callback_data': 'buy:power'},
            {'text': 'Сайт', 'url': 'https://example.com/shop'},
          ],
        ],
      });

      expect(markup?.inlineKeyboard?.single[0].callbackData, 'buy:power');
      expect(markup?.inlineKeyboard?.single[1].url, 'https://example.com/shop');
    });

    test('rejects unsafe, oversized, and malformed button data', () {
      expect(
        BotReplyMarkup.tryParse({
          'inline_keyboard': [
            [
              {'text': 'bad link', 'url': 'javascript:alert(1)'},
            ],
          ],
        }),
        isNull,
      );
      expect(
        BotReplyMarkup.tryParse({
          'inline_keyboard': [
            [
              {'text': 'bad callback', 'callback_data': 'я' * 33},
            ],
          ],
        }),
        isNull,
      );
      expect(BotReplyMarkup.tryParse({'unexpected': true}), isNull);
      expect(BotReplyMarkup.tryParse(' ' * 16_385), isNull);
    });

    test('parses reply text and persists markup with the local message', () {
      final markup = BotReplyMarkup.tryParse(
        '{"keyboard":[[{"text":"Магазин","send_text":"/shop"}]],'
        '"resize_keyboard":true,"one_time_keyboard":true}',
      )!;
      final message = StoredMessage(
        sid: 17,
        peer: 'shopbot',
        fromMe: false,
        text: 'Выбери действие',
        createdAt: '2026-09-14T10:00:00Z',
        replyMarkup: markup,
      );
      final restored = StoredMessage.fromMap(message.toMap());

      expect(markup.keyboard?.single.single.sendText, '/shop');
      expect(markup.oneTimeKeyboard, isTrue);
      expect(restored.replyMarkup?.toJson(), markup.toJson());
    });
  });

  testWidgets('inline buttons deliver callbacks and safe URL taps', (
    tester,
  ) async {
    final markup = BotReplyMarkup.tryParse({
      'inline_keyboard': [
        [
          {'text': 'Купить', 'callback_data': 'buy:power'},
          {'text': 'Сайт', 'url': 'https://example.com'},
        ],
      ],
    })!;
    final callbacks = <String>[];
    final urls = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BotInlineKeyboardView(
            markup: markup,
            onCallback: callbacks.add,
            onUrlTap: urls.add,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Купить'));
    await tester.tap(find.text('Сайт'));

    expect(callbacks, ['buy:power']);
    expect(urls, ['https://example.com']);
  });

  testWidgets('inline keyboard fits the intrinsic-width chat bubble', (
    tester,
  ) async {
    final markup = BotReplyMarkup.tryParse({
      'inline_keyboard': [
        [
          {'text': 'Улучшение скорости', 'callback_data': 'speed'},
          {'text': 'Улучшение защиты', 'callback_data': 'shield'},
        ],
      ],
    })!;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: IntrinsicWidth(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Выбери улучшение'),
                      BotInlineKeyboardView(
                        markup: markup,
                        onCallback: (_) {},
                        onUrlTap: (_) {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('reply keyboard tap emits configured message text', (
    tester,
  ) async {
    final markup = BotReplyMarkup.tryParse({
      'keyboard': [
        [
          {'text': 'Магазин', 'send_text': '/shop'},
          {'text': 'Помощь', 'send_text': '/help'},
        ],
      ],
    })!;
    final sentTexts = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BotReplyKeyboardView(markup: markup, onTap: sentTexts.add),
        ),
      ),
    );
    await tester.tap(find.text('Магазин'));

    expect(sentTexts, ['/shop']);
  });
}
