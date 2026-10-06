import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/core/models/message_button.dart';
import 'package:ghost/services/db_service.dart';
import 'package:ghost/services/public_page_link.dart';

void main() {
  group('MessageButton', () {
    test('text button sends exactly its visible label', () {
      final button = MessageButton.text('  Hello there  ');

      expect(button.isValid, isTrue);
      expect(button.label, 'Hello there');
      expect(button.toJson(), {'type': 'text', 'label': 'Hello there'});
      expect(MessageButton.tryParse(button.toJson()), button);
    });

    test('link button accepts public HTTPS targets only', () {
      expect(
        MessageButton.link(label: 'Open', url: 'example.com/page').isValid,
        isTrue,
      );
      expect(
        MessageButton.link(label: 'Open', url: 'javascript:alert(1)').isValid,
        isFalse,
      );
      expect(
        MessageButton.link(label: '', url: 'https://example.com').isValid,
        isFalse,
      );
    });

    test('parsing skips invalid entries and caps the list', () {
      final parsed = MessageButton.parseList([
        for (var i = 0; i < MessageButton.maxCount + 2; i++)
          {'type': 'text', 'label': 'Action $i'},
        {'type': 'unknown', 'label': 'Ignore me'},
      ]);

      expect(parsed, hasLength(MessageButton.maxCount));
      expect(parsed.last.label, 'Action ${MessageButton.maxCount - 1}');
    });
  });

  test('DM message serialization preserves attached buttons', () {
    final message = StoredMessage(
      sid: 12,
      peer: 'alice',
      fromMe: true,
      text: 'Choose',
      createdAt: '2026-10-06T10:00:00Z',
      userButtons: [MessageButton.text('Continue')],
    );

    expect(
      StoredMessage.fromMap(message.toMap()).userButtons,
      message.userButtons,
    );
  });

  test('GhostEcos link exemption matches exact known hosts only', () {
    expect(PublicPageLink.isGhostEcosHost('ghostchats.duckdns.org'), isTrue);
    expect(PublicPageLink.isGhostEcosHost('GHOSTECOS.DUCKDNS.ORG'), isTrue);
    expect(
      PublicPageLink.isGhostEcosHost('evil-ghostchats.duckdns.org'),
      isFalse,
    );
    expect(
      PublicPageLink.isGhostEcosHost('ghostchats.duckdns.org.example.com'),
      isFalse,
    );
  });
}
