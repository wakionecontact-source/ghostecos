import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/message_receipt_status.dart';

void main() {
  test('maps message flags to the correct receipt icon', () {
    expect(
      messageReceiptIcon(
        messageReceiptStatus(pending: true, delivered: false, read: false),
      ),
      CupertinoIcons.clock,
    );
    expect(
      messageReceiptIcon(
        messageReceiptStatus(pending: false, delivered: true, read: false),
      ),
      CupertinoIcons.checkmark,
    );
    expect(
      messageReceiptIcon(
        messageReceiptStatus(pending: false, delivered: true, read: true),
      ),
      Icons.done_all,
    );
  });

  test('keeps the floppy disk for messages not yet acknowledged', () {
    final status = messageReceiptStatus(
      pending: false,
      delivered: false,
      read: false,
    );

    expect(status, MessageReceiptStatus.saved);
    expect(messageReceiptIcon(status), CupertinoIcons.floppy_disk);
  });
}
