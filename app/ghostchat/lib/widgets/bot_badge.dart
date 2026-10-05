import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Compact bot identity marker used as a lower-left avatar overlay.
/// Bot identity always comes from the server's `is_bot` field.
class BotBadge extends StatelessWidget {
  final double size;

  const BotBadge({super.key, this.size = 18});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Бот',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: GE.bgDeep,
          shape: BoxShape.circle,
          border: Border.all(color: GE.bg, width: 1.5),
          boxShadow: [
            BoxShadow(color: GE.primary.withValues(alpha: 0.32), blurRadius: 7),
          ],
        ),
        child: Icon(
          Icons.smart_toy_rounded,
          size: size * 0.66,
          color: GE.primary,
        ),
      ),
    );
  }
}

/// Official GhostEcos marker. It is rendered before a username/display name;
/// bot status and emoji status remain separate signals.
class OfficialBadge extends StatelessWidget {
  final double size;

  const OfficialBadge({super.key, this.size = 18});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Официальный аккаунт GhostEcos',
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: GE.blue,
        shape: BoxShape.circle,
        border: Border.all(color: GE.bgDeep, width: 1.5),
      ),
      child: Icon(
        CupertinoIcons.checkmark,
        color: Colors.white,
        size: size * 0.62,
      ),
    ),
  );
}

/// Human-readable presence for a server-reported bot connection state.
class BotStatusLabel extends StatelessWidget {
  final String? status;
  final bool compact;

  const BotStatusLabel({super.key, required this.status, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final known = status == 'online' || status == 'offline';
    final online = status == 'online';
    final label = online
        ? (compact ? 'онлайн' : 'в сети')
        : status == 'offline'
        ? (compact ? 'офлайн' : 'не в сети')
        : (compact ? '—' : 'статус не загружен');
    final color = !known
        ? GE.muted
        : online
        ? GE.green
        : GE.sub;

    return Semantics(
      label: known ? label : 'Статус бота не загружен',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 5 : 6,
            height: compact ? 5 : 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          SizedBox(width: compact ? 4 : 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: compact ? 10 : 12,
              height: 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
