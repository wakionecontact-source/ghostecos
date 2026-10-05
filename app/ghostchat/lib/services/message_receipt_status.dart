import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

enum MessageReceiptStatus { sending, read, delivered, saved }

MessageReceiptStatus messageReceiptStatus({
  required bool pending,
  required bool delivered,
  required bool read,
}) {
  if (pending) return MessageReceiptStatus.sending;
  if (read) return MessageReceiptStatus.read;
  if (delivered) return MessageReceiptStatus.delivered;
  return MessageReceiptStatus.saved;
}

IconData messageReceiptIcon(MessageReceiptStatus status) => switch (status) {
  MessageReceiptStatus.sending => CupertinoIcons.clock,
  MessageReceiptStatus.read => Icons.done_all,
  MessageReceiptStatus.delivered => CupertinoIcons.checkmark,
  MessageReceiptStatus.saved => CupertinoIcons.floppy_disk,
};
