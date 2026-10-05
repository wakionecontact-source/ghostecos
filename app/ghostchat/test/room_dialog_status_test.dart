import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/room_service.dart';
import 'package:ghost/widgets/room_dialog_status.dart';

RoomSummary _privateRoom({Map<String, Object?>? lastMessage}) =>
    RoomSummary.fromMap({
      'room_type': 'group',
      'id': 7,
      'title': 'Private group',
      'owner_id': 1,
      'visibility': 'private',
      'history_mode': 'all',
      'encryption_mode': 'e2ee_v2',
      'key_epoch': 1,
      'members_count': 3,
      'role': 'owner',
      'created_at': 1789300000,
      'updated_at': 1789320000,
      if (lastMessage != null) 'last_message': lastMessage,
    });

RoomMessage _cachedMessage({
  int id = 8,
  bool fromMe = true,
  int deliveredCount = 0,
  int readCount = 0,
}) => RoomMessage(
  id: id,
  senderUsername: fromMe ? 'me' : 'other',
  senderDisplayName: fromMe ? 'Me' : 'Other',
  senderAvatarUrl: null,
  text: 'hello',
  forwardedFrom: null,
  createdAt: 1789321234,
  fromMe: fromMe,
  deliveredCount: deliveredCount,
  readCount: readCount,
);

Widget _harness(RoomDialogStatus child) => MaterialApp(
  home: Scaffold(
    body: Align(alignment: Alignment.topRight, child: child),
  ),
);

void main() {
  test('room summary exposes a public latest-message preview', () {
    final room = _privateRoom(
      lastMessage: {
        'id': 8,
        'payload': '{"v":2,"type":"msg","text":"hello room"}',
      },
    );

    expect(room.lastMessageText, 'hello room');
  });

  test(
    'private-room timestamp and own receipt fall back to cached message',
    () {
      final meta = roomDialogMetaFor(_privateRoom(), _cachedMessage());

      expect(meta.timestampSeconds, 1789321234);
      expect(meta.fromMe, isTrue);
      expect(meta.deliveredCount, 0);
      expect(meta.readCount, 0);
    },
  );

  test(
    'private-room timestamp falls back to room activity when summary is absent',
    () {
      final meta = roomDialogMetaFor(_privateRoom(), null);

      expect(meta.timestampSeconds, 1789320000);
      expect(meta.fromMe, isFalse);
    },
  );

  testWidgets(
    'status indicator stays visible and uses a single check for delivery',
    (tester) async {
      final meta = roomDialogMetaFor(
        _privateRoom(),
        _cachedMessage(deliveredCount: 1),
      );
      await tester.pumpWidget(
        _harness(RoomDialogStatus(meta: meta, timeLabel: '20:30')),
      );

      expect(find.text('20:30'), findsOneWidget);
      final receipt = tester.widget<Icon>(
        find.byKey(const ValueKey('room-dialog-receipt')),
      );
      expect(receipt.icon, Icons.done_rounded);
      expect(receipt.size, 15);
    },
  );

  testWidgets(
    'status indicator uses two checks when a private-room message was read',
    (tester) async {
      final meta = roomDialogMetaFor(
        _privateRoom(),
        _cachedMessage(deliveredCount: 1, readCount: 1),
      );
      await tester.pumpWidget(
        _harness(RoomDialogStatus(meta: meta, timeLabel: '20:30')),
      );

      final receipt = tester.widget<Icon>(
        find.byKey(const ValueKey('room-dialog-receipt')),
      );
      expect(receipt.icon, Icons.done_all_rounded);
      expect(receipt.size, 15);
    },
  );
}
