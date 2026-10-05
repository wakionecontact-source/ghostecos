import 'package:flutter_test/flutter_test.dart';

import 'package:ghost/services/room_service.dart';

RoomSummary _room(String roomType, int id, String role, String visibility) {
  return RoomSummary.fromMap({
    'id': id,
    'room_type': roomType,
    'role': role,
    'visibility': visibility,
    'title': 'Room $id',
  });
}

void main() {
  group('RoomLimits', () {
    test('uses separate channel and group quotas', () {
      expect(RoomLimits.channelsPerUser, 10);
      expect(RoomLimits.groupsPerUser, 15);
      expect(RoomLimits.limitFor('channel'), 10);
      expect(RoomLimits.limitFor('group'), 15);
    });

    test(
      'counts only rooms owned by the user, including either visibility',
      () {
        final rooms = [
          ...List.generate(
            5,
            (index) => _room(
              'channel',
              index,
              'owner',
              index.isEven ? 'public' : 'private',
            ),
          ),
          _room('channel', 90, 'member', 'public'),
          ...List.generate(
            8,
            (index) => _room(
              'group',
              100 + index,
              'owner',
              index.isEven ? 'public' : 'private',
            ),
          ),
          _room('group', 190, 'member', 'private'),
        ];

        expect(RoomLimits.ownedCount(rooms, roomType: 'channel'), 5);
        expect(RoomLimits.ownedCount(rooms, roomType: 'group'), 8);
        expect(RoomLimits.canCreate(rooms, roomType: 'channel'), isTrue);
        expect(RoomLimits.canCreate(rooms, roomType: 'group'), isTrue);
      },
    );

    test('blocks exactly at each ownership limit', () {
      final rooms = [
        ...List.generate(
          RoomLimits.channelsPerUser,
          (index) => _room('channel', index, 'owner', 'private'),
        ),
        ...List.generate(
          RoomLimits.groupsPerUser,
          (index) => _room('group', 100 + index, 'owner', 'public'),
        ),
      ];

      expect(RoomLimits.canCreate(rooms, roomType: 'channel'), isFalse);
      expect(RoomLimits.canCreate(rooms, roomType: 'group'), isFalse);
    });
  });

  group('room receipt indicators', () {
    test('maps no delivery, delivery, and first read to distinct states', () {
      expect(
        roomReceiptState(deliveredCount: 0, readCount: 0),
        RoomReceiptState.saved,
      );
      expect(
        roomReceiptState(deliveredCount: 1, readCount: 0),
        RoomReceiptState.delivered,
      );
      expect(
        roomReceiptState(deliveredCount: 1, readCount: 1),
        RoomReceiptState.read,
      );
    });

    test('parses last-message metadata for the chat-list status badge', () {
      final room = RoomSummary.fromMap({
        'id': 4,
        'room_type': 'group',
        'title': 'Receipt test',
        'last_message': {
          'id': 19,
          'created_at': 1_789_000_000,
          'sender_username': 'me',
          'from_me': true,
          'delivered_count': 3,
          'read_count': 1,
        },
      });

      expect(room.lastMessageId, 19);
      expect(room.lastMessageAt, 1_789_000_000);
      expect(room.lastMessageFromMe, isTrue);
      expect(room.lastMessageDeliveredCount, 3);
      expect(room.lastMessageReadCount, 1);
    });
  });
}
