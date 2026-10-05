import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../mesh_background.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/glass.dart';

/// Feature flag for the integrated Ghost Calls engine.
const bool callEntryPointEnabled = true;

/// Themed call-screen UI foundation only; this screen intentionally does not
/// connect, ring, or claim that a call is active.
class CallPreviewScreen extends StatelessWidget {
  final String username;
  final String displayName;
  final String? avatarUrl;

  const CallPreviewScreen({
    super.key,
    required this.username,
    required this.displayName,
    this.avatarUrl,
  });

  @override
  Widget build(BuildContext context) => MeshBackground(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 4,
              left: 8,
              child: IconButton(
                tooltip: 'Закрыть',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(CupertinoIcons.chevron_down, color: GE.text),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 72, 28, 30),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'GHOST  ·  CALLS',
                        style: TextStyle(
                          color: GE.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2.0,
                        ),
                      ),
                      const SizedBox(height: 36),
                      _CallAvatar(
                        avatarUrl: avatarUrl,
                        displayName: displayName,
                      ),
                      const SizedBox(height: 26),
                      Text(
                        displayName,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 27,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '@$username',
                        style: TextStyle(color: GE.sub, fontSize: 14),
                      ),
                      const SizedBox(height: 23),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: GE.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: GE.primary.withValues(alpha: 0.24),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.waveform,
                              color: GE.primary,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Звонки доступны',
                              style: TextStyle(
                                color: GE.text,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 38),
                      _CallControls(),
                      const SizedBox(height: 30),
                      GlassCard(
                        lite: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 13,
                        ),
                        child: Text(
                          'Аудио- и видеозвонки работают через защищённую WebRTC-связь. Начните звонок из шапки диалога.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: GE.sub,
                            fontSize: 12,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _CallAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String displayName;

  const _CallAvatar({required this.avatarUrl, required this.displayName});

  @override
  Widget build(BuildContext context) => Container(
    width: 184,
    height: 184,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: SweepGradient(
        colors: [
          GE.primary.withValues(alpha: 0.1),
          GE.primary,
          GE.blue.withValues(alpha: 0.85),
          GE.primary2,
          GE.primary.withValues(alpha: 0.1),
        ],
      ),
      boxShadow: [
        BoxShadow(
          color: GE.primary.withValues(alpha: 0.25),
          blurRadius: 52,
          spreadRadius: 5,
        ),
        BoxShadow(
          color: GE.blue.withValues(alpha: 0.12),
          blurRadius: 90,
          spreadRadius: 12,
        ),
      ],
    ),
    padding: const EdgeInsets.all(3),
    child: DecoratedBox(
      decoration: BoxDecoration(shape: BoxShape.circle, color: GE.bgDeep),
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: GhostAvatar(
          avatarUrl: avatarUrl,
          fallbackText: displayName,
          size: 168,
        ),
      ),
    ),
  );
}

class _CallControls extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      _CallControl(icon: CupertinoIcons.mic, label: 'Микрофон'),
      const SizedBox(width: 20),
      _CallControl(icon: CupertinoIcons.video_camera, label: 'Камера'),
      const SizedBox(width: 20),
      _CallControl(icon: CupertinoIcons.speaker_2, label: 'Звук'),
    ],
  );
}

class _CallControl extends StatelessWidget {
  final IconData icon;
  final String label;

  const _CallControl({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          color: GE.glassFill,
          shape: BoxShape.circle,
          border: Border.all(color: GE.glassBorder),
        ),
        child: Icon(icon, color: GE.muted, size: 23),
      ),
      const SizedBox(height: 7),
      Text(label, style: TextStyle(color: GE.muted, fontSize: 11)),
    ],
  );
}
