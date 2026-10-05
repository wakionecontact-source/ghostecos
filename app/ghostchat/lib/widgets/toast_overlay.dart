// Внутренние (in-app) уведомления — тосты как в 1.19.3, в дизайне Ghost.
// Очередь + уровни (info/warn/error) + авто-скрытие + свайп-вверх + счётчик «+N».
//
// Показать из любого места:
//   toast.show('Текст', level: ToastLevel.error);
//   toastInfo('...'); toastWarn('...'); toastError('...');
// Оверлей подключён один раз в main.dart (MaterialApp.builder), поверх экранов.
import 'dart:async';
import 'dart:collection';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../theme.dart';
import '../services/theme_service.dart';
import '../services/notification_settings.dart';
import '../services/ghost_sound_effects.dart';
import 'glass.dart';

enum ToastLevel { info, warn, error }

class ToastAction {
  final String label;
  final VoidCallback onPressed;
  const ToastAction({required this.label, required this.onPressed});
}

class _ToastEntry {
  final String message;
  final ToastLevel level;
  final DateTime time;
  final ToastAction? action;
  final int? logId;
  _ToastEntry(this.message, this.level, this.time, this.action, this.logId);
  String get key => '$level|$message';
}

class ToastManager {
  ToastManager._();
  static final ToastManager _i = ToastManager._();
  factory ToastManager() => _i;

  final _queue = Queue<_ToastEntry>();
  final _ctrl = StreamController<void>.broadcast();
  Stream<void> get onChange => _ctrl.stream;

  /// Открыть экран логов — выставляется один раз в main.dart. Кнопка "Логи"
  /// на тосте видна, только если этот колбэк задан.
  void Function(int? logId)? onNavigateToLogs;

  _ToastEntry? get _current => _queue.isNotEmpty ? _queue.first : null;
  int get length => _queue.length;

  /// Показать тост. Дедуп: убирает из очереди такие же (тот же уровень+текст).
  void show(
    String message, {
    ToastLevel level = ToastLevel.info,
    ToastAction? action,
    int? logId,
  }) {
    if (message.trim().isEmpty) return;
    // Настройки → Уведомления → "Внутренние уведомления" (перенесено из
    // 1.19.3) — общий тумблер + по уровню. Гасим централизованно тут, а не
    // в каждом месте вызова toast.show/toastInfo/toastWarn/toastError.
    // Тосты с action (кнопка "Повторить"/"Подтвердить" и т.п.) НЕ гасим по
    // уровню — юзеру реально нужно на них отреагировать, а не просто
    // уведомление к сведению (найдено ревью 2026-07-20: раньше action-тост
    // на уровне info тихо пропадал, если юзер выключил именно info-тосты).
    // Общий тумблер (toastEnabled) всё ещё главный — если тосты выключены
    // совсем, это применимо и к action-тостам тоже.
    final ns = NotificationSettings.instance;
    if (!ns.toastEnabledNotifier.value) return;
    if (action == null) {
      final levelAllowed = switch (level) {
        ToastLevel.error => ns.toastShowErrorsNotifier.value,
        ToastLevel.warn => ns.toastShowWarningsNotifier.value,
        ToastLevel.info => ns.toastShowInfoNotifier.value,
      };
      if (!levelAllowed) return;
    }
    final k = '$level|$message';
    _queue.removeWhere((e) => e.key == k);
    _queue.addLast(_ToastEntry(message, level, DateTime.now(), action, logId));
    _ctrl.add(null);
  }

  void dismiss() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst();
      _ctrl.add(null);
    }
  }

  void clearAll() {
    _queue.clear();
    _ctrl.add(null);
  }
}

final toast = ToastManager();

void toastInfo(String m) => toast.show(m, level: ToastLevel.info);
void toastWarn(String m) => toast.show(m, level: ToastLevel.warn);
void toastError(String m) => toast.show(m, level: ToastLevel.error);

class ToastOverlay extends StatefulWidget {
  final Widget child;
  const ToastOverlay({super.key, required this.child});
  @override
  State<ToastOverlay> createState() => _ToastOverlayState();
}

class _ToastOverlayState extends State<ToastOverlay>
    with TickerProviderStateMixin {
  StreamSubscription? _sub;
  late final AnimationController _anim;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;
  // Второй, отдельный контроллер добавляет squash-and-stretch поверх
  // обычных slide+fade — только на появлении ("enter=pop/spring"), скрытие
  // (_anim.reverse()) остаётся простым, без пружины.
  late final AnimationController _springCtrl;
  _ToastEntry? _showing;
  Timer? _autoHide;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.30),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _springCtrl = AnimationController.unbounded(vsync: this);
    _sub = toast.onChange.listen((_) => _onChange());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _autoHide?.cancel();
    _anim.dispose();
    _springCtrl.dispose();
    super.dispose();
  }

  void _playPop() {
    _springCtrl.stop();
    _springCtrl.animateWith(GhostSpring.run());
  }

  void _onChange() {
    final next = toast._current;
    if (next == null) {
      if (_showing != null) {
        _anim.reverse().then((_) {
          if (mounted) setState(() => _showing = null);
        });
      }
    } else if (_showing == null || _showing!.key != next.key) {
      _autoHide?.cancel();
      setState(() => _showing = next);
      _anim.forward(from: 0);
      _playPop();
      _playToastSound(next.level);
      if (next.action == null) {
        _autoHide = Timer(const Duration(seconds: 6), () {
          if (mounted && _showing != null) toast.dismiss();
        });
      }
    } else {
      // Тот же тост уже показан (совпал key) — раньше тут был голый
      // setState(() {}), который ничего не меняет: повторный тап по
      // источнику (напр. бейдж связи) выглядел так, будто вообще ничего не
      // произошло. Теперь продлеваем автоскрытие и коротко "подпрыгиваем"
      // анимацией — видимый отклик на каждый тап, а не только на первый.
      setState(() => _showing = next);
      _anim.stop();
      _anim.value = 0.85;
      _anim.forward();
      _playPop();
      _playToastSound(next.level);
      if (next.action == null) {
        _autoHide?.cancel();
        _autoHide = Timer(const Duration(seconds: 6), () {
          if (mounted && _showing != null) toast.dismiss();
        });
      }
    }
  }

  void _playToastSound(ToastLevel level) {
    switch (level) {
      case ToastLevel.info:
        unawaited(GhostSoundEffects.instance.playSuccess());
        break;
      case ToastLevel.warn:
        unawaited(GhostSoundEffects.instance.playWarning());
        break;
      case ToastLevel.error:
        unawaited(GhostSoundEffects.instance.playError());
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Stack(
      children: [
        widget.child,
        if (_showing != null)
          Positioned(
            top: top + 8,
            left: 10,
            right: 10,
            child: SlideTransition(
              position: _slide,
              child: FadeTransition(
                opacity: _fade,
                child: AnimatedBuilder(
                  animation: _springCtrl,
                  builder: (_, child) {
                    double sx = 1, sy = 1;
                    if (_springCtrl.isAnimating) {
                      final v = _springCtrl.velocity;
                      final speed = (v.abs() / GhostSpring.maxAbsV).clamp(
                        0.0,
                        1.0,
                      );
                      // Появление идёт по Y — растяжение вдоль движения,
                      // сжатие поперёк, та же формула, что у PressScale.
                      sy = 1 + speed * 0.16 * GhostSpring.squashStrong * 0.33;
                      sx = 1 - speed * 0.10 * GhostSpring.squashStrong * 0.33;
                    }
                    return Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.diagonal3Values(sx, sy, 1),
                      child: child,
                    );
                  },
                  child: Dismissible(
                    key: ValueKey(_showing!.key),
                    direction: DismissDirection.up,
                    onDismissed: (_) => toast.dismiss(),
                    child: Material(
                      type: MaterialType.transparency,
                      child: _ToastCard(
                        entry: _showing!,
                        queue: toast.length,
                        onClose: toast.dismiss,
                        onLogs: toast.onNavigateToLogs,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ToastCard extends StatelessWidget {
  final _ToastEntry entry;
  final int queue;
  final VoidCallback onClose;
  final void Function(int? logId)? onLogs;
  const _ToastCard({
    required this.entry,
    required this.queue,
    required this.onClose,
    this.onLogs,
  });

  Color get _accent => switch (entry.level) {
    ToastLevel.error => GE.red,
    ToastLevel.warn => GE.yellow,
    ToastLevel.info => GE.primary,
  };
  IconData get _icon => switch (entry.level) {
    ToastLevel.error => CupertinoIcons.exclamationmark_circle,
    ToastLevel.warn => CupertinoIcons.exclamationmark_triangle,
    ToastLevel.info => CupertinoIcons.info_circle,
  };
  String get _label => switch (entry.level) {
    ToastLevel.error => 'Ошибка',
    ToastLevel.warn => 'Внимание',
    ToastLevel.info => 'Инфо',
  };

  @override
  Widget build(BuildContext context) {
    final t = entry.time;
    final timeStr =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: GE.glassBlur, sigmaY: GE.glassBlur),
        child: Container(
          decoration: BoxDecoration(
            color: Color.alphaBlend(GE.surface, GE.bg).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(14),
            border: ThemeService.isMinimal
                ? null
                : Border.all(color: _accent.withValues(alpha: 0.45)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.32),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 6, 0),
                child: Row(
                  children: [
                    Icon(_icon, color: _accent, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      _label,
                      style: TextStyle(
                        color: _accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      timeStr,
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                    if (queue > 1) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _accent.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '+${queue - 1}',
                          style: TextStyle(
                            color: _accent,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 17,
                        icon: Icon(CupertinoIcons.xmark, color: GE.sub),
                        onPressed: onClose,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  4,
                  12,
                  (entry.action == null && onLogs == null) ? 12 : 6,
                ),
                child: Text(
                  entry.message,
                  style: TextStyle(color: GE.text, fontSize: 13, height: 1.4),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (entry.action != null || onLogs != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 10, 8),
                  child: Row(
                    children: [
                      const Spacer(),
                      if (entry.action != null)
                        SizedBox(
                          height: 28,
                          child: TextButton(
                            onPressed: () {
                              onClose();
                              entry.action!.onPressed();
                            },
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              backgroundColor: _accent.withValues(alpha: 0.16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: Text(
                              entry.action!.label,
                              style: TextStyle(
                                color: _accent,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      if (entry.action != null && onLogs != null)
                        const SizedBox(width: 6),
                      if (onLogs != null)
                        SizedBox(
                          height: 28,
                          child: TextButton.icon(
                            onPressed: () {
                              onClose();
                              onLogs!(entry.logId);
                            },
                            icon: Icon(
                              Icons.terminal_rounded,
                              size: 13,
                              color: GE.sub,
                            ),
                            label: Text(
                              'Логи',
                              style: TextStyle(color: GE.sub, fontSize: 11.5),
                            ),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
