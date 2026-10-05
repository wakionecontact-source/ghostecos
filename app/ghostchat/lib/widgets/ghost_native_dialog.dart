import 'package:flutter/cupertino.dart';

/// Native-looking confirmation used by GhostChat actions.
///
/// Keep confirmations short and explicit: one neutral cancel action and one
/// primary or destructive action. The component intentionally uses the
/// platform Cupertino dialog rather than the app's decorative glass surfaces.
Future<bool?> showGhostNativeConfirm({
  required BuildContext context,
  required String title,
  required String message,
  String cancelLabel = 'Отмена',
  String confirmLabel = 'Подтвердить',
  bool destructive = false,
}) {
  return showCupertinoDialog<bool>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      title: Text(title),
      content: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(message),
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel),
        ),
        CupertinoDialogAction(
          isDefaultAction: !destructive,
          isDestructiveAction: destructive,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}
