// Единый вид пустого чата — карточка с иконкой + заголовок + подпись.
// Раньше в каждом экране (сервер/LAN/закладки) была своя вёрстка (где-то
// просто текст без карточки/иконки) — теперь одна точка правды.
import 'package:flutter/cupertino.dart';
import '../theme.dart';
import '../services/theme_service.dart';
import 'glass.dart';

class EmptyChatState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const EmptyChatState({
    super.key,
    this.icon = CupertinoIcons.chat_bubble,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: GE.primary),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(color: GE.text, fontWeight: FontWeight.w600),
            ),
            ValueListenableBuilder<bool>(
              valueListenable:
                  ThemeService.instance.detailedDescriptionsNotifier,
              builder: (_, show, __) => show
                  ? Column(
                      children: [
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: GE.sub, fontSize: 12),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
