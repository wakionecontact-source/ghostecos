// Тесты FeedPost.fromMap: парсинг ответа /post/feed.
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/feed_repo.dart';

void main() {
  test('FeedPost.fromMap парсит минимальный пост', () {
    final p = FeedPost.fromMap({
      'id': 42,
      'content': 'Привет лента',
      'username': 'alice',
      'display_name': 'Alice',
      'created_at': '2026-06-03T20:00:00Z',
      'is_nsfw': 0,
    });
    expect(p.id, equals(42));
    expect(p.content, equals('Привет лента'));
    expect(p.authorUsername, equals('alice'));
    expect(p.authorDisplayName, equals('Alice'));
    expect(p.isNsfw, isFalse);
    expect(p.reactions, isEmpty);
  });

  test('FeedPost.fromMap корректно обрабатывает NSFW флаг', () {
    final p = FeedPost.fromMap({
      'id': 1,
      'content': 'x',
      'username': 'u',
      'is_nsfw': 1,
    });
    expect(p.isNsfw, isTrue);
  });

  test('FeedPost.fromMap пустые поля → дефолты', () {
    final p = FeedPost.fromMap({'id': 5});
    expect(p.content, equals(''));
    expect(p.authorUsername, equals('anon'));
    expect(p.authorDisplayName, equals('anon'));
    expect(p.commentsCount, equals(0));
  });

  test('FeedPost.fromMap парсит реакции из Map', () {
    final p = FeedPost.fromMap({
      'id': 1,
      'username': 'u',
      'reactions': {'❤': 3, '🔥': 1},
    });
    expect(p.reactions['❤'], equals(3));
    expect(p.reactions['🔥'], equals(1));
  });
}
