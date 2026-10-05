import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/message_record_merge.dart';

void main() {
  group('message history replay receipt state', () {
    test('keeps read and delivered flags already stored locally', () {
      final merged = mergePersistedReceiptFlags(
        incoming: {'sid': 42, 'peer': 'support', 'read': 0, 'delivered': 0},
        existing: {'read': 1, 'delivered': 1},
      );

      expect(merged['read'], 1);
      expect(merged['delivered'], 1);
      expect(merged['sid'], 42);
    });

    test('new history messages stay unread and undelivered by default', () {
      final merged = mergePersistedReceiptFlags(
        incoming: {'sid': 43, 'peer': 'support', 'read': 0, 'delivered': 0},
      );

      expect(merged['read'], 0);
      expect(merged['delivered'], 0);
    });

    test('new receipt values can still advance existing flags', () {
      final merged = mergePersistedReceiptFlags(
        incoming: {'read': 1, 'delivered': 1},
        existing: {'read': 0, 'delivered': 0},
      );

      expect(merged['read'], 1);
      expect(merged['delivered'], 1);
    });
  });
}
