import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/screens/room_link_preview_screen.dart';
import 'package:ghost/services/room_deep_link.dart';

void main() {
  test('room links are parsed into native previews', () {
    final channel = RoomLinkTarget.parse(
      'https://ghostecos.duckdns.org/c/my_channel',
    );
    expect(channel?.username, 'my_channel');
    expect(channel?.roomTypeHint, 'channel');
    expect(channel?.isInvite, isFalse);

    final group = RoomLinkTarget.parse('https://ghostecos.duckdns.org/g/1');
    expect(group?.username, '1');
    expect(group?.roomTypeHint, 'group');
    expect(group?.isInvite, isFalse);

    final invite = RoomLinkTarget.parse(
      'https://ghostecos.duckdns.org/invite/Abcdefghijklmnop_1234',
    );
    expect(invite?.isInvite, isTrue);
    expect(invite?.token, 'Abcdefghijklmnop_1234');
  });

  test('room parser rejects unsafe or unrelated pages', () {
    expect(RoomLinkTarget.parse('https://ghostecos.duckdns.org/chat/'), isNull);
    expect(RoomLinkTarget.parse('https://example.com/c/my_channel'), isNull);
    expect(
      RoomLinkTarget.parse('https://ghostecos.duckdns.org/invite/short'),
      isNull,
    );
  });

  test('android deep links unwrap the original room URL', () {
    const raw =
        'ghostchat://open?url=https%3A%2F%2Fghostecos.duckdns.org%2Fg%2F1';
    expect(
      RoomDeepLinkService.normalize(raw),
      'https://ghostecos.duckdns.org/g/1',
    );
    expect(
      RoomDeepLinkService.normalize('ghostchat://c/my_channel'),
      'https://ghostecos.duckdns.org/c/my_channel',
    );
  });
}
