// "Механика майнкрафта" — общий паттерн для всех действий, которые меняют
// что-то на сервере: применяем локально СРАЗУ (кнопка/тоггл/счётчик реагируют
// без задержки), запрос на сервер уходит в фоне. Если сервер не ответил за
// 5с или вернул ошибку — откатываем локальное изменение и сообщаем тостом
// (auto-cancel; для лайка/реакции/голоса бесконечный ретрай-в-фоне не нужен —
// пользователь просто нажмёт ещё раз, если реально хотел).
import 'dart:async';
import '../widgets/toast_overlay.dart';

Future<void> optimisticAction({
  required void Function() apply,
  required Future<void> Function() request,
  required void Function() undo,
  String? failureMessage,
  Duration timeout = const Duration(seconds: 5),
}) async {
  apply();
  try {
    await request().timeout(timeout);
  } catch (e) {
    undo();
    toast.show(failureMessage ?? 'Не удалось: $e', level: ToastLevel.warn);
    rethrow;
  }
}
