import 'package:flutter/material.dart';

import '../services/room_service.dart';
import '../theme.dart';

class RoomDialogStatus extends StatelessWidget {
  final String timeLabel;
  final RoomDialogMeta meta;

  const RoomDialogStatus({
    super.key,
    required this.timeLabel,
    required this.meta,
  });

  @override
  Widget build(BuildContext context) {
    final receipt = roomReceiptState(
      deliveredCount: meta.deliveredCount,
      readCount: meta.readCount,
    );
    final icon = switch (receipt) {
      RoomReceiptState.read => Icons.done_all_rounded,
      RoomReceiptState.delivered => Icons.done_rounded,
      RoomReceiptState.saved => Icons.save_outlined,
    };
    return SizedBox(
      key: const ValueKey('room-dialog-status'),
      width: 44,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            timeLabel,
            key: const ValueKey('room-dialog-time'),
            maxLines: 1,
            style: TextStyle(color: GE.sub, fontSize: 10.5),
          ),
          if (meta.fromMe) ...[
            const SizedBox(height: 2),
            Icon(
              icon,
              key: const ValueKey('room-dialog-receipt'),
              size: 15,
              color: receipt == RoomReceiptState.read ? GE.primary : GE.sub,
            ),
          ],
        ],
      ),
    );
  }
}
