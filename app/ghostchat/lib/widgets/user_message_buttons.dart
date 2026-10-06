import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/models/message_button.dart';
import '../theme.dart';

class UserMessageButtons extends StatelessWidget {
  final List<MessageButton> buttons;
  final Color foregroundColor;
  final Future<void> Function(MessageButton button)? onTextTap;
  final Future<void> Function(String url)? onLinkTap;

  const UserMessageButtons({
    super.key,
    required this.buttons,
    required this.foregroundColor,
    this.onTextTap,
    this.onLinkTap,
  });

  @override
  Widget build(BuildContext context) {
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final button in buttons)
            OutlinedButton.icon(
              onPressed: button.kind == MessageButtonKind.text
                  ? (onTextTap == null ? null : () => onTextTap!(button))
                  : (onLinkTap == null || button.url == null
                        ? null
                        : () => onLinkTap!(button.url!)),
              icon: Icon(
                button.kind == MessageButtonKind.link
                    ? CupertinoIcons.link
                    : CupertinoIcons.chat_bubble_text,
                size: 14,
              ),
              label: Text(
                button.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: foregroundColor,
                side: BorderSide(color: foregroundColor.withValues(alpha: 0.4)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(GE.radiusSm),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
