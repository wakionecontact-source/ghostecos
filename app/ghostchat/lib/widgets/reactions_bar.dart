// ReactionsBar — горизонтальная "пилюля" быстрых реакций (Twemoji), общая
// для ЛС/LAN/закладок. Тап по эмодзи → onPick(emoji).
import 'package:flutter/material.dart';
import '../theme.dart';
import 'emoji_text.dart';

class ReactionsBar extends StatelessWidget {
  final void Function(String emoji) onPick;
  const ReactionsBar({super.key, required this.onPick});

  static const _picks = <String>['❤', '👍', '😂', '😮', '😢', '🔥'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemBuilder: (_, i) => InkWell(
          onTap: () => onPick(_picks[i]),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: EmojiText(_picks[i], style: const TextStyle(fontSize: 26)),
          ),
        ),
        separatorBuilder: (_, _) => const SizedBox(width: 2),
        itemCount: _picks.length,
      ),
    );
  }
}

/// Модальная "палитра" реакций снизу экрана — для чатов без полного меню
/// действий у пузыря (LAN, закладки): долгое нажатие на сообщение → эта
/// шторка вместо позиционированного меню, как в ЛС.
Future<String?> showReactionPalette(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Container(
          decoration: BoxDecoration(
            color: GE.bgDeep,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: GE.glassBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: ReactionsBar(onPick: (e) => Navigator.pop(ctx, e)),
        ),
      ),
    ),
  );
}
