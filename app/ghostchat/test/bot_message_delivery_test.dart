import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/bot_message_delivery.dart';

void main() {
  group('incomplete bot realtime event', () {
    test('is deferred for history replay instead of E2E decryption', () {
      expect(
        shouldDeferKnownBotMessage(isKnownBot: true, plainText: null),
        isTrue,
      );
    });

    test('does not defer a message that already has bot plaintext', () {
      expect(
        shouldDeferKnownBotMessage(isKnownBot: true, plainText: '/start'),
        isFalse,
      );
    });

    test('does not change normal user-message handling', () {
      expect(
        shouldDeferKnownBotMessage(isKnownBot: false, plainText: null),
        isFalse,
      );
    });
  });

  group('bot reply catch-up', () {
    test(
      'pulls pending until the realtime reply is present, then stops',
      () async {
        var fetches = 0;
        var replyVisible = false;
        final waits = <Duration>[];

        await catchUpBotReply(
          fetchPending: () async {
            fetches++;
            if (fetches == 2) replyVisible = true;
          },
          hasReply: () async => replyVisible,
          isCurrentSession: () => true,
          wait: (delay) async => waits.add(delay),
        );

        expect(fetches, 2);
        expect(waits, botReplyCatchUpDelays.take(2));
      },
    );

    test('does not poll after the account session changes', () async {
      var current = true;
      var fetches = 0;

      await catchUpBotReply(
        fetchPending: () async => fetches++,
        hasReply: () async => false,
        isCurrentSession: () => current,
        wait: (_) async => current = false,
      );

      expect(fetches, 0);
    });

    test('has a bounded retry count when the bot does not answer', () async {
      var fetches = 0;

      await catchUpBotReply(
        fetchPending: () async => fetches++,
        hasReply: () async => false,
        isCurrentSession: () => true,
        wait: (_) async {},
      );

      expect(fetches, botReplyCatchUpDelays.length);
    });
  });
}
