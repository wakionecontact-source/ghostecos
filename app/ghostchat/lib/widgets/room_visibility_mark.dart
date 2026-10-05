import 'package:flutter/cupertino.dart';

/// Small privacy marker that belongs with a room's subtitle, not its time.
class RoomVisibilityMark extends StatelessWidget {
  const RoomVisibilityMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Приватная комната',
      child: const Icon(
        CupertinoIcons.lock,
        key: ValueKey('room-private-mark'),
        size: 13,
      ),
    );
  }
}
