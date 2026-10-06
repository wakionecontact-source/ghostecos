import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/call_service.dart';
import '../services/chat_repo.dart';
import '../services/profile_cache.dart';
import '../theme.dart';
import 'avatar.dart';
import 'glass.dart';

enum CallWidgetPlacement { top, bottom }

enum CallWidgetStyle { compact, card }

typedef CallWidgetOpenCall = void Function(BuildContext context, String peer);

/// Keeps call controls in the current screen's normal layout flow. Each screen
/// chooses the slot and visual density through its MeshBackground settings.
class CallWidgetSlot extends StatelessWidget {
  static CallWidgetOpenCall? onOpenCall;

  const CallWidgetSlot({
    super.key,
    required this.child,
    required this.placement,
    this.style = CallWidgetStyle.compact,
    this.openCallScreenAfterAnswer = true,
  });

  final Widget child;
  final CallWidgetPlacement placement;
  final CallWidgetStyle style;
  final bool openCallScreenAfterAnswer;

  @override
  Widget build(BuildContext context) {
    final calls = CallService.instance;
    final callState = Listenable.merge([
      calls.state,
      calls.incoming,
      calls.heldCallState,
    ]);
    return ListenableBuilder(
      listenable: callState,
      builder: (context, _) {
        final snapshot = calls.state.value;
        final invite = calls.incoming.value;
        final held = calls.heldCallState.value;
        Widget? panel;
        if (invite != null) {
          panel = _incomingPanel(context, invite, calls);
        } else if (snapshot.minimized && calls.isActive) {
          panel = _activePanel(context, snapshot, calls);
        } else if (held != null) {
          panel = _heldPanel(context, held, calls);
        }

        final slot = panel == null
            ? const SizedBox.shrink()
            : SafeArea(
                top: placement == CallWidgetPlacement.top,
                bottom: placement == CallWidgetPlacement.bottom,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: panel,
                ),
              );
        final stableChild = KeyedSubtree(
          key: const ValueKey('call_widget_screen_child'),
          child: child,
        );
        return Column(
          children: placement == CallWidgetPlacement.top
              ? [slot, Expanded(child: stableChild)]
              : [Expanded(child: stableChild), slot],
        );
      },
    );
  }

  Widget _incomingPanel(
    BuildContext context,
    CallInvite invite,
    CallService calls,
  ) {
    final waiting = calls.hasWaitingIncoming;
    final compact = style == CallWidgetStyle.compact;
    final padding = compact
        ? const EdgeInsets.fromLTRB(11, 8, 8, 8)
        : const EdgeInsets.fromLTRB(15, 12, 12, 12);
    return GlassCard(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              GhostAvatar(
                avatarUrl: _avatarFor(invite.peer),
                fallbackText: invite.peer,
                size: compact ? 38 : 44,
                fallbackIcon: invite.video
                    ? CupertinoIcons.video_camera_solid
                    : CupertinoIcons.phone_fill,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      waiting
                          ? 'Второй входящий вызов'
                          : invite.video
                          ? 'Входящий видеозвонок'
                          : 'Входящий звонок',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: GE.text,
                        fontWeight: FontWeight.w800,
                        fontSize: compact ? 13 : 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${invite.peer} · ${invite.video ? 'видео' : 'аудио'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          if (waiting)
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              runSpacing: 2,
              children: [
                _action(
                  label: 'Отклонить',
                  icon: CupertinoIcons.phone_down_fill,
                  color: GE.red,
                  onPressed: () => unawaited(calls.rejectIncoming()),
                ),
                _action(
                  label: 'Завершить текущий и принять новый',
                  icon: CupertinoIcons.phone_fill,
                  color: GE.text,
                  onPressed: () => _accept(
                    context,
                    calls,
                    invite,
                    CallAcceptAction.finishCurrent,
                  ),
                ),
                _action(
                  label: 'Удержать текущий и принять новый',
                  icon: CupertinoIcons.pause_fill,
                  color: GE.primary,
                  onPressed: calls.canHoldCurrent
                      ? () => _accept(
                          context,
                          calls,
                          invite,
                          CallAcceptAction.holdCurrent,
                        )
                      : null,
                ),
              ],
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _action(
                  label: 'Отклонить',
                  icon: CupertinoIcons.phone_down_fill,
                  color: GE.red,
                  onPressed: () => unawaited(calls.rejectIncoming()),
                ),
                _action(
                  label: 'Принять',
                  icon: CupertinoIcons.phone_fill,
                  color: GE.green,
                  onPressed: () => _accept(
                    context,
                    calls,
                    invite,
                    CallAcceptAction.finishCurrent,
                  ),
                ),
              ],
            ),
          if (waiting && !calls.canHoldCurrent)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  calls.state.value.screenSharing
                      ? 'Остановите показ экрана, чтобы удержать звонок.'
                      : 'Удержание станет доступно после подключения.',
                  style: TextStyle(color: GE.sub, fontSize: 10),
                  textAlign: TextAlign.end,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _activePanel(
    BuildContext context,
    CallSnapshot snapshot,
    CallService calls,
  ) {
    final peer = snapshot.peer;
    if (peer == null || peer.isEmpty) return const SizedBox.shrink();
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        children: [
          GhostAvatar(
            avatarUrl: _avatarFor(peer),
            fallbackText: peer,
            size: 38,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: InkWell(
              onTap: openCallScreenAfterAnswer
                  ? () => _openCall(context, snapshot)
                  : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '@$peer',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: GE.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    snapshot.phase == CallPhase.connected
                        ? snapshot.screenSharing
                              ? 'Показ экрана · ${_duration(snapshot.duration)}'
                              : _duration(snapshot.duration)
                        : snapshot.phase == CallPhase.outgoing
                        ? 'Вызов…'
                        : 'Соединение…',
                    style: TextStyle(color: GE.sub, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          if (calls.hasHeldCall)
            IconButton(
              tooltip: 'Переключиться на удерживаемый звонок',
              visualDensity: VisualDensity.compact,
              onPressed: calls.canHoldCurrent
                  ? () => unawaited(_switchToHeld(context, calls))
                  : null,
              icon: Icon(CupertinoIcons.arrow_2_circlepath, color: GE.primary),
            ),
          IconButton(
            tooltip: 'Завершить звонок',
            visualDensity: VisualDensity.compact,
            onPressed: () => unawaited(calls.end()),
            icon: Icon(CupertinoIcons.phone_down_fill, color: GE.red),
          ),
        ],
      ),
    );
  }

  Widget _heldPanel(
    BuildContext context,
    CallSnapshot held,
    CallService calls,
  ) {
    final peer = held.peer;
    if (peer == null || peer.isEmpty) return const SizedBox.shrink();
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        children: [
          GhostAvatar(
            avatarUrl: _avatarFor(peer),
            fallbackText: peer,
            size: 36,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'На удержании · @$peer',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: GE.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                Text(
                  _duration(held.duration),
                  style: TextStyle(color: GE.sub, fontSize: 11),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: calls.canHoldCurrent
                ? () => unawaited(_switchToHeld(context, calls))
                : null,
            icon: const Icon(CupertinoIcons.arrow_2_circlepath, size: 16),
            label: const Text('Переключиться'),
          ),
        ],
      ),
    );
  }

  Widget _action({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback? onPressed,
  }) => TextButton.icon(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: color,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    icon: Icon(icon, size: 17),
    label: Text(label, style: const TextStyle(fontSize: 11)),
  );

  Future<void> _accept(
    BuildContext context,
    CallService calls,
    CallInvite invite,
    CallAcceptAction action,
  ) async {
    try {
      await calls.acceptIncoming(action: action);
      if (!context.mounted) return;
      final snapshot = calls.state.value;
      if (openCallScreenAfterAnswer && calls.isActive) {
        _openCall(context, snapshot, fallbackPeer: invite.peer);
      }
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось принять вызов: $error')),
      );
    }
  }

  Future<void> _switchToHeld(BuildContext context, CallService calls) async {
    try {
      await calls.switchToHeldCall();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось переключить вызов: $error')),
      );
    }
  }

  void _openCall(
    BuildContext context,
    CallSnapshot snapshot, {
    String? fallbackPeer,
  }) {
    final peer = snapshot.peer ?? fallbackPeer;
    if (peer == null || peer.isEmpty || !openCallScreenAfterAnswer) return;
    CallService.instance.restore();
    CallWidgetSlot.onOpenCall?.call(context, peer);
  }

  static String _duration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return duration.inHours > 0
        ? '${duration.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  static String? _avatarFor(String peer) =>
      ChatRepo.instance.getPeerAvatarCached(peer) ??
      ProfileCache.instance.getProfileSync(peer)?['avatar_url']?.toString();
}
