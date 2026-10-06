import 'package:flutter/material.dart';

import '../core/models/message_button.dart';
import '../services/public_page_link.dart';
import '../theme.dart';

Future<MessageButton?> showAddMessageButtonDialog(BuildContext context) async {
  final labelController = TextEditingController();
  final urlController = TextEditingController();
  var kind = MessageButtonKind.text;
  String? errorText;
  try {
    return await showDialog<MessageButton>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: GE.bgDeep,
          title: const Text('Кнопка под сообщением'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Отправить текст'),
                      selected: kind == MessageButtonKind.text,
                      onSelected: (_) => setDialogState(() {
                        kind = MessageButtonKind.text;
                        errorText = null;
                      }),
                    ),
                    ChoiceChip(
                      label: const Text('Открыть ссылку'),
                      selected: kind == MessageButtonKind.link,
                      onSelected: (_) => setDialogState(() {
                        kind = MessageButtonKind.link;
                        errorText = null;
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: labelController,
                  autofocus: true,
                  maxLength: 80,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: kind == MessageButtonKind.text
                        ? 'Текст кнопки и сообщения'
                        : 'Название кнопки',
                    helperText: kind == MessageButtonKind.text
                        ? 'Текст отправится в чат только после нажатия'
                        : null,
                  ),
                ),
                if (kind == MessageButtonKind.link) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: urlController,
                    maxLength: 2048,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'HTTPS-ссылка',
                      hintText: 'example.com/page',
                    ),
                  ),
                ],
                if (errorText != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      errorText!,
                      style: TextStyle(color: GE.red, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final button = kind == MessageButtonKind.text
                    ? MessageButton.text(labelController.text)
                    : MessageButton.link(
                        label: labelController.text,
                        url: urlController.text,
                      );
                final safeLink =
                    kind != MessageButtonKind.link ||
                    PublicPageLink.parse(urlController.text) != null;
                if (!button.isValid || !safeLink) {
                  setDialogState(() {
                    errorText = safeLink
                        ? 'Заполни текст кнопки (до 80 символов)'
                        : 'Ссылка недопустима: нужны безопасная публичная HTTPS-страница';
                  });
                  return;
                }
                Navigator.of(dialogContext).pop(button);
              },
              child: const Text('Добавить'),
            ),
          ],
        ),
      ),
    );
  } finally {
    labelController.dispose();
    urlController.dispose();
  }
}
