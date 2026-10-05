import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/notification_service.dart';

void main() {
  test('incoming media gets a distinct notification presentation', () {
    expect(
      classifyNotificationKind(mime: 'image/jpeg'),
      NotificationMessageKind.photo,
    );
    expect(
      classifyNotificationKind(mime: 'video/mp4'),
      NotificationMessageKind.video,
    );
    expect(
      classifyNotificationKind(mime: 'audio/ogg', voice: true),
      NotificationMessageKind.voice,
    );
    expect(NotificationMessageKind.photo.fallbackText, 'Новое фото');
    expect(NotificationMessageKind.photo.isMedia, isTrue);
  });

  test('unknown attachment falls back to a file notification', () {
    expect(
      classifyNotificationKind(mime: 'application/pdf'),
      NotificationMessageKind.file,
    );
    expect(classifyNotificationKind(), NotificationMessageKind.text);
  });
}
