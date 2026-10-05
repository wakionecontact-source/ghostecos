import 'package:flutter/material.dart';

import '../theme.dart';
import 'glass.dart';

class BotChatWelcome extends StatelessWidget {
  static const startCommand = '/start';

  final String displayName;

  const BotChatWelcome({super.key, required this.displayName});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: GE.primary.withValues(alpha: 0.14),
                border: Border.all(color: GE.primary.withValues(alpha: 0.32)),
                boxShadow: [
                  BoxShadow(
                    color: GE.primary.withValues(alpha: 0.16),
                    blurRadius: 26,
                  ),
                ],
              ),
              child: Icon(Icons.smart_toy_rounded, color: GE.primary, size: 36),
            ),
            const SizedBox(height: 18),
            Text(
              'Начни диалог с $displayName',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: GE.text,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Нажми «Начать» внизу — боту отправится команда /start.',
              textAlign: TextAlign.center,
              style: TextStyle(color: GE.sub, fontSize: 13, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}

/// Replaces the composer until a bot conversation has been started.
class BotStartPrompt extends StatelessWidget {
  final bool sending;
  final VoidCallback onTap;

  const BotStartPrompt({super.key, required this.sending, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: PressScale(
        onTap: sending ? null : onTap,
        child: GlassCard(
          lite: true,
          isListSection: true,
          radius: 22,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: GE.primary.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  sending
                      ? Icons.hourglass_top_rounded
                      : Icons.play_arrow_rounded,
                  color: GE.primary,
                  size: 21,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      sending ? 'Отправляю…' : 'Начать',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Отправить /start',
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.send_rounded,
                color: sending ? GE.muted : GE.primary,
                size: 19,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
