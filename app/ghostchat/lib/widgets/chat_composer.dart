// Единый композер всех чатов: фрост-стекло + скрепка (AttachSheet) + эмодзи +
// поле ввода + круглая кнопка-самолётик. Визуально 1:1 с chat_screen.dart
// (_composer/_circleBtn) — вынесен сюда, чтобы LAN- и bookmark-чаты выглядели
// и ощущались так же, как основной чат (единая моторика/стекло/кнопки).
//
// Fly-анимацию отправки (flySendAnimation) дёргает САМ экран в своём onSend —
// так же, как chat_screen: [sendKey] вешается на кнопку, экран берёт из неё
// точку вылета баблы.
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../theme.dart';
import '../services/performance_service.dart';
import '../services/theme_service.dart';

class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool emojiOpen;
  final bool sending;
  final String hint;
  final GlobalKey sendKey;
  final VoidCallback onAttach;
  final VoidCallback onToggleEmoji;
  final VoidCallback onSend;
  final VoidCallback? onFieldTap;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.emojiOpen,
    required this.sendKey,
    required this.onAttach,
    required this.onToggleEmoji,
    required this.onSend,
    this.sending = false,
    this.hint = 'Сообщение',
    this.onFieldTap,
    this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    // Тот же рецепт стекла, что у chat_screen._composer: blur + тёмный тинт,
    // тающий кверху, + акцентная кромка сверху (подхватывает палитру темы).
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: GE.primary.withValues(alpha: 0.17),
            width: 0.7,
          ),
        ),
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            GE.bgDeep.withValues(alpha: 0.80),
            GE.bgDeep.withValues(alpha: 0.50),
            GE.bgDeep.withValues(alpha: 0.08),
          ],
          stops: const [0.0, 0.6, 1.0],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Скрепка слева, эмодзи справа (порядок как в chat_screen).
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(CupertinoIcons.paperclip, color: GE.sub),
              onPressed: !enabled || sending ? null : onAttach,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(
                emojiOpen ? CupertinoIcons.keyboard : CupertinoIcons.smiley,
                color: emojiOpen ? GE.primary : GE.sub,
              ),
              onPressed: enabled ? onToggleEmoji : null,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 6,
                style: TextStyle(color: GE.text, fontSize: 15),
                cursorColor: GE.primary,
                textInputAction: TextInputAction.newline,
                onTap: onFieldTap,
                onChanged: onChanged,
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: TextStyle(color: GE.sub),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            Material(
              key: sendKey,
              color: Colors.transparent,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: !enabled || sending ? null : onSend,
                child: _circleBtn(
                  sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(
                          CupertinoIcons.paperplane_fill,
                          color: Colors.white,
                          size: 18,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return ClipRect(
      child: PerformanceService.instance.reducedEffects
          ? surface
          : BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: surface,
            ),
    );
  }

  // 1:1 с chat_screen._circleBtn — круглая кнопка с фиолетовым градиентом.
  Widget _circleBtn(Widget child) {
    final traditional =
        ThemeService.instance.styleNotifier.value == ThemeStyle.traditional;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: traditional ? GE.primary : null,
        gradient: traditional
            ? null
            : LinearGradient(colors: [GE.primary2, GE.primary]),
      ),
      alignment: Alignment.center,
      child: IconTheme(
        data: const IconThemeData(color: Colors.white),
        child: child,
      ),
    );
  }
}
