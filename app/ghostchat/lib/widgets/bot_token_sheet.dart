// Шторка с одноразовым показом bot-токена — общая для создания (через
// GhostBot в чате, см. bots_screen.dart empty-state) и перевыпуска токена
// (bot_detail_screen.dart). Токен больше нигде не восстановить.
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';

Future<void> showBotTokenSheet(
  BuildContext context, {
  required String username,
  required String token,
}) {
  return showGlassSheet(
    context,
    child: Builder(
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(CupertinoIcons.checkmark_seal, color: GE.primary, size: 32),
            const SizedBox(height: 12),
            Text('Токен @$username',
                style: TextStyle(color: GE.text, fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              'Показывается ОДИН РАЗ. Сохрани его сейчас — восстановить потом '
              'не получится, только перевыпустить новый (старый перестанет работать).',
              style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: GE.glassFill,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: GE.borderStrong),
              ),
              child: SelectableText(
                token,
                style: TextStyle(color: GE.text, fontSize: 13, fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 14),
            GlassButton(
              label: 'Скопировать токен',
              icon: CupertinoIcons.doc_on_clipboard,
              primary: true,
              fullWidth: true,
              onTap: () {
                Clipboard.setData(ClipboardData(text: token));
                toast.show('Токен скопирован');
              },
            ),
            const SizedBox(height: 8),
            GlassButton(
              label: 'Готово',
              fullWidth: true,
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    ),
  );
}
