import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/database_backup_service.dart';

Uint8List _sqliteLikeSnapshot() {
  final bytes = Uint8List(256);
  bytes.setRange(0, 16, utf8.encode('SQLite format 3\u0000'));
  // A minimal page-size field makes the fixture look like a real SQLite
  // header without requiring a platform database in this pure crypto test.
  bytes[16] = 0x10;
  bytes[17] = 0x00;
  return bytes;
}

void main() {
  final backup = DatabaseBackupService.instance;

  test('database backup round-trips and is randomized', () async {
    final snapshot = _sqliteLikeSnapshot();
    final first = await backup.encryptSnapshot(
      snapshot,
      account: 'Alice',
      password: 'a strong backup password',
    );
    final second = await backup.encryptSnapshot(
      snapshot,
      account: 'Alice',
      password: 'a strong backup password',
    );

    expect(first, isNot(equals(second)));
    expect(
      await backup.decryptSnapshot(
        first,
        account: 'alice',
        password: 'a strong backup password',
      ),
      equals(snapshot),
    );
  });

  test('database backup rejects wrong password and account binding', () async {
    final container = await backup.encryptSnapshot(
      _sqliteLikeSnapshot(),
      account: 'alice',
      password: 'correct password',
    );

    expect(
      backup.decryptSnapshot(
        container,
        account: 'alice',
        password: 'wrong password',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      backup.decryptSnapshot(
        container,
        account: 'another-account',
        password: 'correct password',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('database backup rejects tampering and malformed containers', () async {
    final container = await backup.encryptSnapshot(
      _sqliteLikeSnapshot(),
      account: 'alice',
      password: 'correct password',
    );
    final tampered = Uint8List.fromList(container);
    tampered[tampered.length - 1] ^= 0x01;

    expect(
      backup.decryptSnapshot(
        tampered,
        account: 'alice',
        password: 'correct password',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      backup.decryptSnapshot(
        Uint8List.fromList(List<int>.filled(20, 0)),
        account: 'alice',
        password: 'correct password',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
