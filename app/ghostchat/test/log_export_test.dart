import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/core/local/app_logger.dart';

void main() {
  final entries = [
    LogEntry(
      time: DateTime(2026, 8, 31, 12, 30, 1, 5),
      category: 'flutter',
      level: 'error',
      message: 'layout failed',
    ),
    LogEntry(
      time: DateTime(2026, 8, 31, 12, 30, 2),
      category: 'chat',
      level: 'info',
      message: 'message sent',
    ),
    LogEntry(
      time: DateTime(2026, 8, 31, 12, 30, 3),
      category: 'flutter',
      level: 'debug',
      message: 'frame built',
    ),
  ];

  test('all export keeps every category and level', () {
    expect(filterLogEntries(entries, 'all'), hasLength(3));
  });

  test('category export keeps only the selected category', () {
    final flutterEntries = filterLogEntries(entries, 'flutter');
    expect(flutterEntries, hasLength(2));
    expect(
      flutterEntries.every((entry) => entry.category == 'flutter'),
      isTrue,
    );
  });

  test('export format is plain text and preserves the level', () {
    final text = formatLogEntries(filterLogEntries(entries, 'flutter'));
    expect(
      text,
      contains('2026-08-31T12:30:01.005 [flutter] [error] layout failed'),
    );
    expect(text, contains('[flutter] [debug] frame built'));
    expect(text.endsWith('\n'), isTrue);
  });
}
