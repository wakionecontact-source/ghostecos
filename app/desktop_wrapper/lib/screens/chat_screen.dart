// ChatScreen — открытый DM-чат. Native, без WebView.
//
// AUTO-2/AUTO-3: текст + картинки + голосовые, reply/edit/delete/forward/react.
// Все медиа шифруются на клиенте AES-256, blob аплоадится зашифрованным.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:intl/intl.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_filex/open_filex.dart';
import 'package:video_player/video_player.dart';
import 'package:video_compress/video_compress.dart';
import '../theme.dart';
import '../widgets/emoji_picker.dart';
import '../widgets/emoji_text.dart';
import '../mesh_background.dart';
import '../services/chat_repo.dart';
import '../services/db_service.dart';
import '../services/auth_service.dart';
import '../services/ws_client.dart';
import '../services/notification_service.dart';
import '../widgets/attach_sheet.dart';
import '../widgets/glass.dart';
import 'profile_screen.dart';

class ChatScreen extends StatefulWidget {
  final String peer;
  final String displayName;

  /// Если задан — после открытия проскролить и подсветить сообщение с этим sid.
  final int? highlightSid;
  const ChatScreen({
    super.key,
    required this.peer,
    required this.displayName,
    this.highlightSid,
  });
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  // Память позиции скролла по чату: первый заход → низ, далее → где остановился.
  static final Map<String, double> _scrollMemory = {};
  // Черновик per-чат + динамическая высота композера (scroll-up при росте поля).
  SharedPreferences? _prefs;
  final _composerKey = GlobalKey();
  double _composerH = 96;
  String get _draftKey => 'chat_draft_${widget.peer}';
  bool _emojiOpen = false; // инлайн эмодзи-панель снизу (composer над ней)
  static const double _emojiPanelH = 300;
  // Кнопка «вниз» (видна при прокрутке вверх) + замочек авто-скролла на отправке.
  bool _showScrollDown = false;
  bool _scrollLock = false;
  // Стартовая позиция скролла ставится в билдере на ПЕРВОЙ непустой отрисовке
  // (когда сообщения реально загружены), а не в _init (там список ещё пуст).
  bool _didInitialScroll = false;
  // Линия «Новое» + бейдж непрочитанных В ОТКРЫТОМ чате (live).
  int? _newLineSid; // sid соо, НАД которым рисуется ОДНА линия «Новое»
  final GlobalKey _newLineKey = GlobalKey(); // для точного центрирования стрелкой
  double _newLineOpacity = 1.0; // fade-out при любом действии юзера
  int _unreadInChat = 0; // живой счётчик непрочитанных пока чат открыт (badge)
  int _lastMsgCount = 0; // для детекта новых соо в билдере
  int _arrowStage = 0; // 2-stage тап стрелки: 0=центр на линию, 1=в самый низ
  bool _pinnedBottom = true; // юзер у дна → держим прилеплено к низу
  double _lastMaxExtent = 0; // детект reflow (дозагрузка контента двигает низ)

  // Линия «Новое» плавно исчезает при ЛЮБОМ действии юзера (тап/скролл/отправка).
  void _clearNewLine() {
    if (_newLineSid != null && _newLineOpacity != 0.0) {
      setState(() => _newLineOpacity = 0.0);
    }
  }
  final _imagePicker = ImagePicker();
  final _recorder = AudioRecorder();

  bool _sending = false;
  String? _myUsername;
  int? _highlightSid;
  Timer? _highlightTimer;

  StoredMessage? _replyTo;
  StoredMessage? _editing;

  bool _recording = false;
  int _recordStartedAt = 0;
  Timer? _recordTicker;
  Duration _recordDur = Duration.zero;
  final List<double> _recWave = [];
  bool _handsFree = false; // true = тап-запись (ждём кнопку), false = удержание

  // ── Выделение сообщений (множественный выбор) ───────────────────────
  final Set<int> _selSids = {};
  bool get _selectionMode => _selSids.isNotEmpty;
  void _toggleSel(StoredMessage m) {
    _clearNewLine(); // выбор — действие → линия «Новое» уходит
    HapticFeedback.selectionClick();
    setState(() {
      if (!_selSids.remove(m.sid)) _selSids.add(m.sid);
    });
  }

  void _clearSel() => setState(() => _selSids.clear());

  // ── Drag-select: зажал и ведёшь палец вверх/вниз → выделяется ВСЁ на пути ──
  // Long-press взводит флаг, а сами move ловит Listener списка (сырые pointer-
  // события, не конкурируют в арене жестов); на время выделения скролл выключен.
  int? _dragAnchorSid;
  bool _dragSelecting = false;
  bool _dragRemoving = false; // режим по якорю: true = снимаем, false = добавляем
  Set<int> _dragBaseSel = {}; // снимок выбора ДО текущего жеста (range-поведение)
  final Map<int, GlobalKey> _bubbleKeys = {};

  void _startDragSelect(StoredMessage m) {
    _clearNewLine();
    HapticFeedback.selectionClick();
    _dragAnchorSid = m.sid;
    // Telegram-«рисование»: зажал на УЖЕ выбранном → ведение СНИМАЕТ; на
    // невыбранном → добавляет. Режим фиксируем по якорю на старте.
    _dragRemoving = _selSids.contains(m.sid);
    _dragBaseSel = Set<int>.from(_selSids); // снимок СВЕЖИЙ на каждый жест
    setState(() {
      _dragSelecting = true;
      if (_dragRemoving) {
        _selSids.remove(m.sid);
      } else {
        _selSids.add(m.sid);
      }
    });
  }

  double? _lastDragGlobalY;
  Timer? _edgeTimer;
  double _edgeVelocity = 0;

  void _updateDragSelect(Offset globalPos) {
    _applyDragRange(globalPos.dy);
    _dragEdgeAutoscroll(globalPos.dy);
  }

  // Range-поведение (как в TG): выбор = снимок-до-жеста, к диапазону якорь..палец
  // применён режим. Ведёшь дальше — диапазон растёт; ведёшь НАЗАД — сжимается
  // (отменяя промежуточные). Свежий снимок + сброс на новом касании = старый
  // выбор за пределами диапазона не затирается.
  void _applyDragRange(double gy) {
    final anchor = _dragAnchorSid;
    if (anchor == null) return;
    final curSid = _sidAtGlobalY(gy);
    if (curSid == null) return;
    final msgs = ChatRepo.instance.messagesNotifier(widget.peer).value;
    final ai = msgs.indexWhere((m) => m.sid == anchor);
    final ci = msgs.indexWhere((m) => m.sid == curSid);
    if (ai < 0 || ci < 0) return;
    final lo = ai < ci ? ai : ci;
    final hi = ai < ci ? ci : ai;
    final next = Set<int>.from(_dragBaseSel);
    for (var i = lo; i <= hi; i++) {
      if (_dragRemoving) {
        next.remove(msgs[i].sid);
      } else {
        next.add(msgs[i].sid);
      }
    }
    setState(() => _selSids
      ..clear()
      ..addAll(next));
  }

  void _endDragSelect() {
    _stopEdgeTimer();
    _dragAnchorSid = null;
    if (_dragSelecting && mounted) setState(() => _dragSelecting = false);
  }

  // Какое сообщение под пальцем (по глобальной Y) — перебор видимых пузырей.
  int? _sidAtGlobalY(double gy) {
    for (final e in _bubbleKeys.entries) {
      final ctx = e.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      if (gy >= top && gy <= top + box.size.height) return e.key;
    }
    return null;
  }

  // Плавный авто-скролл у краёв через ТАЙМЕР (не jumpTo на каждый move — иначе
  // улетало рывком). Скорость ramp-ится от близости пальца к краю.
  void _dragEdgeAutoscroll(double gy) {
    _lastDragGlobalY = gy;
    if (!_scrollCtrl.hasClients) {
      _stopEdgeTimer();
      return;
    }
    final media = MediaQuery.of(context);
    const zone = 90.0; // ширина «горячей» полосы у края
    final topEdge = media.padding.top + 70 + zone;
    final bottomEdge = media.size.height - _composerH - 70 - zone;
    double v = 0;
    if (gy < topEdge) {
      v = -((topEdge - gy) / zone).clamp(0.0, 1.0) * 7.0; // вверх
    } else if (gy > bottomEdge) {
      v = ((gy - bottomEdge) / zone).clamp(0.0, 1.0) * 7.0; // вниз
    }
    _edgeVelocity = v;
    if (v == 0) {
      _stopEdgeTimer();
    } else {
      _edgeTimer ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _edgeTick(),
      );
    }
  }

  void _edgeTick() {
    if (!_dragSelecting || _edgeVelocity == 0 || !_scrollCtrl.hasClients) {
      _stopEdgeTimer();
      return;
    }
    final max = _scrollCtrl.position.maxScrollExtent;
    final target = (_scrollCtrl.offset + _edgeVelocity).clamp(0.0, max);
    if (target == _scrollCtrl.offset) return; // у самого края — больше некуда
    _scrollCtrl.jumpTo(target);
    final y = _lastDragGlobalY;
    if (y != null) _applyDragRange(y); // после прокрутки — расширить выбор
  }

  void _stopEdgeTimer() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _edgeVelocity = 0;
  }

  List<StoredMessage> get _selectedMsgs => ChatRepo.instance
      .messagesNotifier(widget.peer)
      .value
      .where((m) => _selSids.contains(m.sid))
      .toList();

  Future<void> _deleteSelected() async {
    final ids = _selSids.toList();
    _clearSel();
    for (final sid in ids) {
      try {
        await ChatRepo.instance.deleteDmMessage(
          toUsername: widget.peer,
          sid: sid,
        );
      } catch (_) {}
    }
  }

  Future<void> _copySelected() async {
    final txt = _selectedMsgs
        .where((m) => m.text.isNotEmpty)
        .map((m) => m.text)
        .join('\n');
    await Clipboard.setData(ClipboardData(text: txt));
    _clearSel();
    _snack('Скопировано');
  }

  Future<void> _forwardSelected() async {
    final msgs = _selectedMsgs;
    if (msgs.isEmpty) return;
    final target = await _pickForwardTarget();
    if (target == null || !mounted) return;
    _clearSel();
    var ok = 0;
    for (final m in msgs) {
      try {
        await ChatRepo.instance.forwardDmMessage(
          original: m,
          toUsername: target,
        );
        ok++;
      } catch (_) {}
    }
    if (mounted) _snack('Переслано: $ok из ${msgs.length}');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inputCtrl.addListener(_onInputChanged);
    _scrollCtrl.addListener(_onScroll);
    // В чате блокируем переворот экрана (только портрет).
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    // Этот чат открыт → не слать о нём уведомления.
    NotificationService.activePeer = widget.peer;
    _init();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final fromBottom =
        _scrollCtrl.position.maxScrollExtent - _scrollCtrl.position.pixels;
    // «Прилеплен к низу» — пока юзер у дна, билдер держит его внизу при
    // дозагрузке/новых соо; стоит пролистать вверх — отлипаем.
    _pinnedBottom = fromBottom < 100;
    // ЖИВОЙ (пользовательский) скролл → линия «Новое» гаснет (любое действие).
    // Программный авто-скролл userScrollDirection не меняет → линию не трогает.
    if (_scrollCtrl.position.userScrollDirection != ScrollDirection.idle) {
      _clearNewLine();
    }
    // «Вниз» показываем, когда пролистано >~10 сообщений вверх от низа.
    final show = fromBottom > 600;
    if (show != _showScrollDown) setState(() => _showScrollDown = show);
    // Дошёл до низа → «прочитал»: гасим бейдж и сбрасываем стадию стрелки.
    // Линию «Новое» тут НЕ трогаем — иначе авто-доскролл к новому соо (когда
    // юзер у дна) гасил бы её мгновенно. Линия уходит только по ДЕЙСТВИЮ юзера
    // (живой скролл выше — userScrollDirection, тап, отправка).
    if (fromBottom < 80 && (_unreadInChat != 0 || _arrowStage != 0)) {
      setState(() {
        _unreadInChat = 0;
        _arrowStage = 0;
      });
      ChatRepo.instance.markChatRead(widget.peer); // подчистить и БД
    }
  }

  void _onInputChanged() {
    // Черновик per-чат: сохраняем/чистим на каждый ввод (очистка на send —
    // _inputCtrl.clear() тоже сюда попадёт).
    final t = _inputCtrl.text;
    if (t.isEmpty) {
      _prefs?.remove(_draftKey);
    } else {
      _prefs?.setString(_draftKey, t);
    }
    _remeasureComposer(); // рост многострочного поля — подвинуть ленту
  }

  // Меряем композер (его высота растёт при reply-bar / многострочном вводе) и
  // двигаем ленту вверх на дельту, чтобы последнее сообщение не пряталось под
  // ним. animate=true → плавно (easeOutCubic) — для появления reply-bar.
  void _remeasureComposer({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measureComposer(animate);
      // Повторный замер после оседания клавиатуры / анимации reply-bar: первый
      // замер ловит промежуточную высоту → стрелка «вниз» и нижний паддинг не
      // успевают за выросшим reply-bar (reply-bar перекрывал стрелку). #1.
      Future.delayed(const Duration(milliseconds: 330), () {
        if (mounted) _measureComposer(false);
      });
    });
  }

  void _measureComposer(bool animate) {
    final box = _composerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final h = box.size.height;
    if (h == _composerH) return;
    final grew = h > _composerH;
    final delta = h - _composerH;
    setState(() => _composerH = h);
    if (grew && _scrollCtrl.hasClients) {
      final target = (_scrollCtrl.offset + delta).clamp(
        0.0,
        _scrollCtrl.position.maxScrollExtent,
      );
      if (animate) {
        _scrollCtrl.animateTo(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollCtrl.jumpTo(target);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Когда возвращаемся на экран — тянем свежее из обоих каналов.
      ChatRepo.instance.fetchPending();
      ChatRepo.instance.fetchPendingSealed();
    }
  }

  Future<void> _init() async {
    _myUsername = await AuthService.username();
    _prefs = await SharedPreferences.getInstance();
    final draft = _prefs?.getString(_draftKey);
    if (draft != null && draft.isNotEmpty && _inputCtrl.text.isEmpty) {
      _inputCtrl.text = draft;
      _inputCtrl.selection = TextSelection.collapsed(offset: draft.length);
    }
    // Граница «Новое» — ДО markChatRead (тот пометит всё прочитанным).
    _newLineSid = await ChatRepo.instance.firstUnreadSid(widget.peer);
    await ChatRepo.instance.markChatRead(widget.peer);
    // Сразу проверяем свежие сообщения от веба (Sealed Sender 2.0) и legacy.
    ChatRepo.instance.fetchPending();
    ChatRepo.instance.fetchPendingSealed();
    // Прогреваем v2-ключи пира заранее — чтобы ПЕРВАЯ отправка не ждала whois
    // по сети (это и была «медленная отправка»). Группы — мимо.
    if (!widget.peer.startsWith('g:')) {
      ChatRepo.instance.getPeerV2Keys(widget.peer);
    }
    if (!mounted) return;
    setState(() {});
    // Подсветка цели forward/reply — визуальный таймер. Сам СКРОЛЛ к стартовой
    // позиции (низ / сохранённая / к highlightSid) делается в билдере списка на
    // ПЕРВОЙ непустой отрисовке: здесь сообщения ещё грузятся, скроллить некуда.
    if (widget.highlightSid != null) {
      setState(() => _highlightSid = widget.highlightSid);
      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _highlightSid = null);
      });
    }
  }

  void _scrollToSid(int sid) {
    final msgs = ChatRepo.instance.messagesNotifier(widget.peer).value;
    final idx = msgs.indexWhere((m) => m.sid == sid);
    if (idx < 0 || !_scrollCtrl.hasClients) return;
    final approx = (idx * 64.0).clamp(
      0.0,
      _scrollCtrl.position.maxScrollExtent,
    );
    _scrollCtrl.animateTo(
      approx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Этот чат закрыт → снова можно слать о нём уведомления.
    if (NotificationService.activePeer == widget.peer) {
      NotificationService.activePeer = null;
    }
    // Возвращаем все ориентации при выходе из чата.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _highlightTimer?.cancel();
    _recordTicker?.cancel();
    _edgeTimer?.cancel();
    _inputCtrl.dispose();
    // Запоминаем позицию скролла перед закрытием чата.
    if (_scrollCtrl.hasClients) {
      _scrollMemory[widget.peer] = _scrollCtrl.offset;
    }
    _scrollCtrl.dispose();
    try {
      _recorder.dispose();
    } catch (_) {}
    super.dispose();
  }

  void _scrollToBottom(bool animate) {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position.maxScrollExtent;
    if (animate) {
      _scrollCtrl.animateTo(
        pos,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    } else {
      _scrollCtrl.jumpTo(pos);
    }
  }

  // 2-stage тап стрелки: 1-й тап центрирует линию «Новое» (по РЕАЛЬНОМУ контексту
  // через ensureVisible — точно, без оценки idx*высота), 2-й — в самый низ. Если
  // линия не на виду / нет бейджа — сразу в самый низ.
  void _onArrowTap() {
    final ctx = _newLineKey.currentContext;
    // Во время ЖИВОГО скролла не центрируем по контексту (ensureVisible на
    // лету мог дёргать вьюпорт в пустоту) — просто едем вниз.
    final idle = !_scrollCtrl.hasClients ||
        _scrollCtrl.position.userScrollDirection == ScrollDirection.idle;
    if (_unreadInChat > 0 &&
        _newLineSid != null &&
        _arrowStage == 0 &&
        ctx != null &&
        idle) {
      _arrowStage = 1;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5, // 0.5 = по центру экрана
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
      );
    } else {
      _arrowStage = 0;
      _scrollToBottom(true);
    }
  }

  // Горизонтальный разделитель «Новое» (unread separator) — ОДНА линия над
  // первым новым входящим. Появляется на любое входящее (даже у дна), плавно
  // исчезает (fade) при любом действии юзера; по завершении fade — снимается.
  Widget _newMessagesLine() {
    return AnimatedOpacity(
      key: _newLineKey,
      opacity: _newLineOpacity,
      duration: const Duration(milliseconds: 280),
      onEnd: () {
        if (_newLineOpacity == 0.0 && _newLineSid != null && mounted) {
          setState(() => _newLineSid = null);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 1,
                color: GE.primary.withValues(alpha: 0.5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'Новое',
                style: TextStyle(
                  color: GE.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Expanded(
              child: Container(
                height: 1,
                color: GE.primary.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    _clearNewLine(); // отправка — действие → линия «Новое» уходит
    final replyTo = _replyTo;
    final editing = _editing;
    // Чистим поле СРАЗУ: текст уходит в pending-бабл, бар свободен.
    _inputCtrl.clear();
    setState(() {
      _replyTo = null;
      _editing = null;
    });

    // Правка — ждём (модифицирует уже существующее сообщение).
    if (editing != null) {
      setState(() => _sending = true);
      try {
        await ChatRepo.instance.editDmMessage(
          toUsername: widget.peer,
          sid: editing.sid,
          newText: text,
        );
      } catch (e) {
        _inputCtrl.text = text;
        setState(() => _editing = editing);
        _snack('Не сохранилось: $e');
      } finally {
        if (mounted) setState(() => _sending = false);
      }
      return;
    }

    // Отправка: оптимистичный пузырь появляется СРАЗУ внутри sendDmText, доставка
    // идёт В ФОНЕ → кнопка и поле свободны мгновенно (не ждём ~5с round-trip,
    // можно слать следующее сразу). Ошибка — пузырь остаётся pending + снэк.
    ChatRepo.instance
        .sendDmText(
          widget.peer,
          text,
          replyTo: replyTo?.sid,
          replyPreview: replyTo == null ? null : _msgPreview(replyTo),
        )
        .catchError((Object e) {
          if (mounted) _snack('Не отправилось: $e');
        });
    // Замочек ЗАКРЫТ → не дёргаем скролл при отправке своего сообщения.
    if (!_scrollLock) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToBottom(true),
      );
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // Эмодзи-панель выезжает СНИЗУ, composer остаётся НАД ней (как клавиатура).
  void _toggleEmoji() {
    setState(() => _emojiOpen = !_emojiOpen);
    if (_emojiOpen) {
      FocusScope.of(context).unfocus(); // прячем системную клаву — панель вместо
    }
    _remeasureComposer();
  }

  void _insertEmoji(String e) {
    final text = _inputCtrl.text;
    final sel = _inputCtrl.selection;
    final start = sel.start < 0 ? text.length : sel.start;
    final end = sel.end < 0 ? text.length : sel.end;
    final next = text.replaceRange(start, end, e);
    _inputCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + e.length),
    );
    setState(() {});
  }

  Future<void> _pickAndSendImage(ImageSource src) async {
    // Лист закрывает AttachSheet — здесь НЕ popаем (иначе закроется чат).
    try {
      // W5b: ограничиваем разрешение (до 1920px) + качество 85 — фото меньше,
      // аплоад быстрее и надёжнее (особенно на слабой сети), визуально без потерь.
      final x = await _imagePicker.pickImage(
        source: src,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      );
      if (x == null) return;
      final bytes = await x.readAsBytes();
      await ChatRepo.instance.sendDmFile(
        toUsername: widget.peer,
        bytes: bytes,
        mime: 'image/jpeg',
        fileName: x.name,
        localPath: x.path, // показываем фото СРАЗУ (превью) пока грузится
      );
    } catch (e) {
      _snack('Картинка не отправилась: $e');
    }
  }

  Future<void> _pickAndSendVideo() async {
    try {
      final x = await _imagePicker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
      if (x == null) return;
      final bytes = await x.readAsBytes();
      // Первый кадр (превью) — показываем в чате ДО окончания загрузки.
      Uint8List? thumb;
      try {
        thumb = await VideoCompress.getByteThumbnail(x.path, quality: 60);
      } catch (_) {}
      // Крупное видео сожмётся ВНУТРИ sendDmFile (прогресс 0-50%); путь нужен
      // компрессору. Гард 80МБ — на совсем гигантские.
      if (bytes.length > 80 * 1024 * 1024) {
        final mb = (bytes.length / 1024 / 1024).toStringAsFixed(0);
        _snack('Видео очень большое ($mb МБ) — выбери покороче.');
        return;
      }
      await ChatRepo.instance.sendDmFile(
        toUsername: widget.peer,
        bytes: bytes,
        mime: 'video/mp4',
        fileName: x.name,
        sourcePath: x.path,
        thumbnail: thumb,
      );
    } catch (e) {
      _snack('Видео не отправилось: $e');
    }
  }

  // Отправка ПРОИЗВОЛЬНОГО файла (любой тип) через системный пикер.
  Future<void> _pickAndSendFile() async {
    try {
      final file = await openFile();
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final mime = file.mimeType ?? _guessMime(file.name);
      await ChatRepo.instance.sendDmFile(
        toUsername: widget.peer,
        bytes: bytes,
        mime: mime,
        fileName: file.name,
        localPath: file.path, // аудио можно слушать пока грузится
      );
    } catch (e) {
      _snack('Файл не отправился: $e');
    }
  }

  String _guessMime(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pdf')) return 'application/pdf';
    if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
    if (n.endsWith('.png')) return 'image/png';
    if (n.endsWith('.gif')) return 'image/gif';
    if (n.endsWith('.webp')) return 'image/webp';
    if (n.endsWith('.mp4')) return 'video/mp4';
    if (n.endsWith('.mov')) return 'video/quicktime';
    if (n.endsWith('.mp3')) return 'audio/mpeg';
    if (n.endsWith('.m4a')) return 'audio/m4a';
    if (n.endsWith('.zip')) return 'application/zip';
    if (n.endsWith('.doc') || n.endsWith('.docx')) return 'application/msword';
    if (n.endsWith('.txt')) return 'text/plain';
    return 'application/octet-stream';
  }

  Future<void> _openAttachSheet() async {
    HapticFeedback.selectionClick();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true, // высокий лист — грид галереи занимает ~80%
      backgroundColor: Colors.transparent,
      builder: (_) => AttachSheet(
        onPickedSend: _sendPickedItems,
        onGallery: () => _pickAndSendImage(ImageSource.gallery),
        onFile: _pickAndSendFile,
        onCamera: () => _pickAndSendImage(ImageSource.camera),
        onGeo: () => _snack('Геопозиция — скоро'),
        onWallet: () => _snack('Кошелёк — после интеграции GhostBank'),
      ),
    );
  }

  // Отправить выбранные в гриде элементы по очереди (фото/видео).
  Future<void> _sendPickedItems(List<AttachItem> items) async {
    for (final it in items) {
      if (it.isVideo) {
        await _sendVideoFile(it.file);
      } else {
        await _sendImageFile(it.file);
      }
    }
  }

  Future<void> _sendImageFile(File f) async {
    try {
      final bytes = await f.readAsBytes();
      await ChatRepo.instance.sendDmFile(
        toUsername: widget.peer,
        bytes: bytes,
        mime: 'image/jpeg',
        fileName: f.path.split('/').last,
        localPath: f.path,
      );
    } catch (e) {
      _snack('Фото не отправилось: $e');
    }
  }

  Future<void> _sendVideoFile(File f) async {
    try {
      final bytes = await f.readAsBytes();
      if (bytes.length > 80 * 1024 * 1024) {
        _snack('Видео очень большое — выбери покороче.');
        return;
      }
      Uint8List? thumb;
      try {
        thumb = await VideoCompress.getByteThumbnail(f.path, quality: 60);
      } catch (_) {}
      await ChatRepo.instance.sendDmFile(
        toUsername: widget.peer,
        bytes: bytes,
        mime: 'video/mp4',
        fileName: f.path.split('/').last,
        sourcePath: f.path,
        thumbnail: thumb,
        localPath: f.path,
      );
    } catch (e) {
      _snack('Видео не отправилось: $e');
    }
  }

  Widget _attachTile(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(GE.radiusMd),
        onTap: onTap, // pick-методы сами закрывают лист (Navigator.maybePop)
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: LinearGradient(
                    colors: [
                      Color.alphaBlend(Colors.white.withValues(alpha: 0.12), color),
                      color,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 26),
              ),
              const SizedBox(height: 7),
              Text(
                label,
                style: TextStyle(color: GE.text, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startRecording({bool handsFree = false}) async {
    if (_recording) return;
    try {
      final has = await _recorder.hasPermission();
      if (!has) {
        _snack('Нет разрешения на микрофон');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/ghost_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      // Сжатие на устройстве: голосу хватает 24кГц/32кбит — файл в разы меньше.
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 24000,
          numChannels: 1,
          bitRate: 32000,
        ),
        path: path,
      );
      _recordStartedAt = DateTime.now().millisecondsSinceEpoch;
      setState(() {
        _recording = true;
        _handsFree = handsFree;
        _recordDur = Duration.zero;
        _recWave.clear();
      });
      HapticFeedback.lightImpact();
      _recordTicker?.cancel();
      // 100мс: тикаем длительность + копим амплитуду для вейвформы.
      _recordTicker = Timer.periodic(const Duration(milliseconds: 100), (
        _,
      ) async {
        if (!mounted) return;
        double norm = 0.25;
        try {
          final amp = await _recorder.getAmplitude();
          norm = ((amp.current.clamp(-45.0, 0.0)) + 45.0) / 45.0;
        } catch (_) {}
        if (!mounted) return;
        setState(() {
          _recordDur = Duration(
            milliseconds:
                DateTime.now().millisecondsSinceEpoch - _recordStartedAt,
          );
          _recWave.add(norm);
        });
      });
    } catch (e) {
      _snack('Запись не стартовала: $e');
    }
  }

  Future<void> _stopAndSendRecording({bool cancel = false}) async {
    if (!_recording) return;
    _recordTicker?.cancel();
    try {
      final path = await _recorder.stop();
      setState(() => _recording = false);
      if (cancel || path == null) return;
      final file = File(path);
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();
      final durSec = (_recordDur.inMilliseconds / 1000).round();
      final waveform = _downsampleWave(_recWave, 40);
      await ChatRepo.instance.sendDmFile(
        toUsername: widget.peer,
        bytes: bytes,
        mime: 'audio/m4a',
        fileName: 'voice.m4a',
        voice: true,
        duration: durSec,
        waveform: waveform,
        localPath: path, // слушать пока грузится (файл жив весь pending-период)
      );
      try {
        await file.delete();
      } catch (_) {}
    } catch (e) {
      _snack('Голосовое не отправилось: $e');
    }
  }

  /// Усредняем сырые амплитуды в [target] полосок (компактная вейвформа в payload).
  List<double> _downsampleWave(List<double> raw, int target) {
    if (raw.isEmpty) return const [];
    if (raw.length <= target) {
      return raw.map((v) => double.parse(v.toStringAsFixed(2))).toList();
    }
    final out = <double>[];
    final bucket = raw.length / target;
    for (var i = 0; i < target; i++) {
      final start = (i * bucket).floor();
      final end = ((i + 1) * bucket).floor().clamp(start + 1, raw.length);
      double sum = 0;
      for (var j = start; j < end; j++) {
        sum += raw[j];
      }
      out.add(double.parse((sum / (end - start)).toStringAsFixed(2)));
    }
    return out;
  }

  Future<void> _openBubbleMenu(StoredMessage m, Offset pos) async {
    _clearNewLine(); // тап по сообщению — действие → линия «Новое» уходит
    HapticFeedback.mediumImpact();
    final mine = m.fromMe;
    final isText = m.filePayload == null && !m.deleted;
    final canEdit = mine && isText;
    // «Копировать» — только для текста (на телефоне копировать аудио/медиа
    // бессмысленно), «Редактировать» — только свой текст.
    final canCopy = isText && m.text.isNotEmpty;
    final actions = <_MenuAction>[
      const _MenuAction('reply', Icons.reply, 'Ответить'),
      const _MenuAction('forward', Icons.forward, 'Переслать'),
      if (canCopy) const _MenuAction('copy', Icons.copy, 'Копировать'),
      if (canEdit) const _MenuAction('edit', Icons.edit, 'Редактировать'),
      const _MenuAction('select', Icons.check_circle_outline, 'Выбрать'),
      if (mine && !m.deleted)
        const _MenuAction(
          'delete',
          Icons.delete_outline,
          'Удалить',
          danger: true,
        ),
    ];
    // Надёжное меню У ПАЛЬЦА: showDialog + Positioned (showMenu давал зависание).
    final res = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.2),
      builder: (dctx) {
        final size = MediaQuery.of(dctx).size;
        const menuW = 236.0;
        final menuH = 60.0 + actions.length * 46.0 + 14;
        final left = (pos.dx - menuW).clamp(8.0, size.width - menuW - 8);
        final top = (pos.dy - menuH).clamp(
          MediaQuery.of(dctx).padding.top + 8,
          size.height - menuH - 8,
        );
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: menuW,
              child: _BubbleMenuCard(
                actions: actions,
                onPick: (v) => Navigator.pop(dctx, v),
              ),
            ),
          ],
        );
      },
    );
    if (res == null || !mounted) return;
    if (res.startsWith('react:')) {
      final emoji = res.substring('react:'.length);
      try {
        await ChatRepo.instance.reactDmMessage(
          toUsername: widget.peer,
          sid: m.sid,
          emoji: emoji,
        );
      } catch (e) {
        _snack('Не вышло: $e');
      }
      return;
    }
    switch (res) {
      case 'reply':
        setState(() => _replyTo = m);
        _remeasureComposer(animate: true); // доскролл под выросший reply-bar
        break;
      case 'edit':
        setState(() {
          _editing = m;
          _inputCtrl.text = m.text;
          _inputCtrl.selection = TextSelection.collapsed(offset: m.text.length);
        });
        _remeasureComposer(animate: true);
        break;
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        _snack('Скопировано');
        break;
      case 'delete':
        try {
          await ChatRepo.instance.deleteDmMessage(
            toUsername: widget.peer,
            sid: m.sid,
          );
        } catch (e) {
          _snack('Не удалилось: $e');
        }
        break;
      case 'forward':
        await _showForwardPicker(m);
        break;
      case 'select':
        _toggleSel(m);
        break;
    }
  }

  PopupMenuItem<String> _popupItem(
    String value,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: 44,
      child: Row(
        children: [
          Icon(icon, size: 18, color: danger ? GE.red : GE.primary),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(color: danger ? GE.red : GE.text, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Future<void> _showForwardPicker(StoredMessage m) async {
    final target = await _pickForwardTarget();
    if (target == null || !mounted) return;
    try {
      await ChatRepo.instance.forwardDmMessage(original: m, toUsername: target);
      _snack('Переслано в @$target');
    } catch (e) {
      _snack('Не переслалось: $e');
    }
  }

  Future<String?> _pickForwardTarget() async {
    final dialogs = ChatRepo.instance.dialogsNotifier.value
        .where((d) => d.username != widget.peer && !d.username.startsWith('g:'))
        .toList();
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            radius: GE.radiusLg,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Переслать кому?',
                      style: TextStyle(
                        color: GE.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                for (final d in dialogs)
                  InkWell(
                    onTap: () => Navigator.pop(ctx, d.username),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: GE.primary2,
                            child: const Icon(
                              Icons.person,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '@${d.username}',
                              style: TextStyle(color: GE.text),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (dialogs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'Нет других чатов',
                      style: TextStyle(color: GE.sub),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notif = ChatRepo.instance.messagesNotifier(widget.peer);
    final isGroup = widget.peer.startsWith('g:');
    // Прозрачная фрост-шапка: контент скроллит ЗА неё (extendBodyBehindAppBar),
    // верхний отступ ленты = статус-бар + высота шапки.
    final headerPad = MediaQuery.of(context).padding.top + 64 + 8;
    return MeshBackground(
      // Mesh-обои: механика 1-в-1 с web mesh.js (частицы + сеть линий +
      // 3-слойный градиент). Шапка/композер-стекло размывают его сверху.
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        // Контент скроллит ЗА шапку → фрост размывает его = прозрачное стекло.
        extendBodyBehindAppBar: true,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          // Прозрачная фрост-шапка (лакшери): глубокий тинт, тает книзу + тёплый
          // золотистый разделитель снизу.
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 9, sigmaY: 9),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Color(0x2BD4B88C), width: 0.7),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xB31C1530),
                      Color(0x661C1530),
                      Color(0x001C1530),
                    ],
                    stops: [0.0, 0.6, 1.0],
                  ),
                ),
                child: _selectionMode
                    ? _SelectionHeader(
                        count: _selSids.length,
                        canCopy: _selectedMsgs.any((m) => m.text.isNotEmpty),
                        onClose: _clearSel,
                        onCopy: _copySelected,
                        onForward: _forwardSelected,
                        onDelete: _deleteSelected,
                      )
                    : _ChatHeader(
                        peer: widget.peer,
                        displayName: widget.displayName,
                        isGroup: isGroup,
                      ),
              ),
            ),
          ),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    Expanded(
                      // Матовая подложка над mesh: mesh просвечивает, но сообщения читаемы.
                      // Без BackdropFilter на большом скролле — оптимизация (фрост даёт
                      // композер ниже + бабблы-стекло поверх).
                      child: ColoredBox(
                        color: GE.bg.withValues(alpha: 0.0),
                        child: ValueListenableBuilder<List<StoredMessage>>(
                          valueListenable: notif,
                          builder: (_, msgs, __) {
                            if (msgs.isEmpty) return _empty();
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!mounted || !_scrollCtrl.hasClients) return;
                              if (!_didInitialScroll) {
                                // Первая непустая отрисовка: контент есть,
                                // maxScrollExtent валиден — ставим старт.
                                _didInitialScroll = true;
                                _lastMsgCount = msgs.length;
                                if (widget.highlightSid != null) {
                                  _scrollToSid(widget.highlightSid!);
                                  _pinnedBottom = false;
                                } else {
                                  final saved = _scrollMemory[widget.peer];
                                  if (saved != null) {
                                    _scrollCtrl.jumpTo(saved.clamp(
                                      0.0,
                                      _scrollCtrl.position.maxScrollExtent,
                                    ));
                                    _pinnedBottom = false;
                                  } else {
                                    _scrollToBottom(false); // первый заход → низ
                                    _pinnedBottom = true;
                                  }
                                }
                                _lastMaxExtent =
                                    _scrollCtrl.position.maxScrollExtent;
                                return;
                              }
                              final grew = msgs.length > _lastMsgCount;
                              final incoming = grew
                                  ? msgs
                                        .sublist(_lastMsgCount)
                                        .where((m) => !m.fromMe)
                                        .toList()
                                  : const <StoredMessage>[];
                              final max = _scrollCtrl.position.maxScrollExtent;
                              final dragging =
                                  _scrollCtrl.position.userScrollDirection !=
                                  ScrollDirection.idle;
                              final reflowed = max > _lastMaxExtent + 1;
                              final lastMine =
                                  msgs.isNotEmpty && msgs.last.fromMe;
                              // Держим у дна ТОЛЬКО когда прилеплен, юзер НЕ тянет
                              // сам, и есть реальная причина (новые соо / reflow).
                              // Иначе jumpTo на каждую перерисовку клинил скролл
                              // ВВЕРХ. Замочек закрыт + последнее соо МОЁ → не
                              // пиннить (иначе reflow доскраллит к своему соо даже
                              // при закрытом замке / при его выключении).
                              if (_pinnedBottom &&
                                  !dragging &&
                                  (grew || reflowed) &&
                                  !(_scrollLock && lastMine)) {
                                _scrollToBottom(grew);
                              }
                              if (incoming.isNotEmpty) {
                                if (_pinnedBottom) {
                                  // У дна — бейдж НЕ копим (markPeerSeen), но линию
                                  // «Новое» показываем (уйдёт fade при действии).
                                  ChatRepo.instance.markPeerSeen(widget.peer);
                                  setState(() {
                                    _newLineSid ??= incoming.first.sid;
                                    _newLineOpacity = 1.0;
                                  });
                                } else {
                                  // Пролистан вверх → бейдж + ОДНА линия «Новое».
                                  setState(() {
                                    _newLineSid ??= incoming.first.sid;
                                    _newLineOpacity = 1.0;
                                    _unreadInChat += incoming.length;
                                  });
                                }
                              }
                              _lastMaxExtent = max;
                              _lastMsgCount = msgs.length;
                            });
                            return Listener(
                              // Новое касание — сбрасываем возможный «зависший»
                              // drag (если onPointerUp был пропущен), чтобы
                              // стейл-снимок не затирал выбор. Long-press потом
                              // переармирует через _startDragSelect.
                              onPointerDown: (_) {
                                _dragSelecting = false;
                                _dragAnchorSid = null;
                              },
                              // Сырые pointer-move во время drag-select — надёжно,
                              // мимо арены жестов.
                              onPointerMove: (e) {
                                if (_dragSelecting) {
                                  _updateDragSelect(e.position);
                                }
                              },
                              onPointerUp: (_) => _endDragSelect(),
                              onPointerCancel: (_) => _endDragSelect(),
                              child: TweenAnimationBuilder<double>(
                              // #b: нижний паддинг ленты гонится за высотой
                              // композера ПЛАВНО → отмена reply не прыгает, чат
                              // синхронно занимает освободившееся место.
                              tween: Tween<double>(
                                end:
                                    _composerH +
                                    (_emojiOpen ? _emojiPanelH : 0) +
                                    12,
                              ),
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              builder: (_, padBottom, __) => ListView.builder(
                              // physics НЕ переключаем на лету: пересборка
                              // Scrollable посреди long-press сбрасывала жест.
                              // Скролл и так заблокирован (long-press выиграл арену).
                              controller: _scrollCtrl,
                              padding: EdgeInsets.fromLTRB(
                                12,
                                headerPad,
                                12,
                                padBottom,
                              ),
                              itemCount: msgs.length,
                              itemBuilder: (_, i) {
                                final m = msgs[i];
                                final prev = i > 0 ? msgs[i - 1] : null;
                                // Линия при смене автора + пилюля-дата при смене дня.
                                final newSender =
                                    prev != null && prev.fromMe != m.fromMe;
                                final newDay =
                                    prev == null ||
                                    !_msgSameDay(m.createdAt, prev.createdAt);
                                final selected = _selSids.contains(m.sid);
                                final inner = _Bubble(
                                  m,
                                  myUsername: _myUsername,
                                  highlighted: m.sid == _highlightSid,
                                  prevSame:
                                      i > 0 && msgs[i - 1].fromMe == m.fromMe,
                                );
                                // Тап → меню у пальца; зажатие → выделить.
                                // Структура НЕ меняется при входе в режим выбора
                                // (Dismissible/AbsorbPointer всегда на месте) —
                                // иначе _MediaPart пересоздаётся и медиа мигает.
                                final gestured = GestureDetector(
                                  behavior: HitTestBehavior.deferToChild,
                                  // Callbacks ВСЕГДА присутствуют (режим проверяем
                                  // внутри) — иначе смена _selectionMode прямо в
                                  // onLongPressStart переконфигурировала бы
                                  // GestureDetector посреди жеста и теряла бы
                                  // move-апдейты (drag-select не работал).
                                  onTap: () {
                                    if (_selectionMode) _toggleSel(m);
                                  },
                                  onTapUp: (d) {
                                    if (!_selectionMode) {
                                      _openBubbleMenu(m, d.globalPosition);
                                    }
                                  },
                                  // Зажатие → начать выбор + drag-select. Само
                                  // ведение ловит Listener списка (надёжнее, чем
                                  // onLongPressMoveUpdate в скролл-листе).
                                  onLongPressStart: (_) => _startDragSelect(m),
                                  // В режиме выбора гасим внутренние тапы медиа.
                                  child: AbsorbPointer(
                                    absorbing: _selectionMode,
                                    child: inner,
                                  ),
                                );
                                final bubble = AnimatedContainer(
                                  key: _bubbleKeys.putIfAbsent(
                                    m.sid,
                                    () => GlobalKey(),
                                  ),
                                  duration: const Duration(milliseconds: 160),
                                  curve: Curves.easeOut,
                                  color: selected
                                      ? GE.primary.withValues(alpha: 0.14)
                                      : Colors.transparent,
                                  child: Dismissible(
                                    key: ValueKey(
                                      'msg_${m.sid}_${m.tempSid ?? ""}',
                                    ),
                                    // Свайп-ответ выключаем в режиме выбора, но
                                    // сам Dismissible оставляем (стабильность).
                                    direction: _selectionMode
                                        ? DismissDirection.none
                                        : DismissDirection.startToEnd,
                                    confirmDismiss: (_) async {
                                      setState(() => _replyTo = m);
                                      HapticFeedback.selectionClick();
                                      _remeasureComposer(animate: true);
                                      return false;
                                    },
                                    background: Container(
                                      alignment: Alignment.centerLeft,
                                      padding: const EdgeInsets.only(left: 24),
                                      child: Icon(
                                        Icons.reply,
                                        color: GE.primary,
                                        size: 22,
                                      ),
                                    ),
                                    child: gestured,
                                  ),
                                );
                                final showNewLine =
                                    _newLineSid != null && m.sid == _newLineSid;
                                if (!newSender && !newDay && !showNewLine) {
                                  return bubble;
                                }
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (showNewLine) _newMessagesLine(),
                                    if (newDay) _dateChip(m.createdAt),
                                    if (newSender && !newDay)
                                      Center(
                                        child: Container(
                                          width: 44,
                                          height: 1,
                                          margin: const EdgeInsets.symmetric(
                                            vertical: 7,
                                          ),
                                          color: GE.borderStrong,
                                        ),
                                      ),
                                    bubble,
                                  ],
                                );
                              },
                            ),
                            ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Фрост-композер снизу: лента уходит ЗА него → стекло размывает (как шапка).
            // При открытой эмодзи-панели composer приподнят НАД ней (как клавиатура).
            Positioned(
              left: 0,
              right: 0,
              bottom: _emojiOpen ? _emojiPanelH : 0,
              child: SafeArea(
                top: false,
                bottom: !_emojiOpen, // над панелью bottom-inset не нужен
                child: Column(
                  key: _composerKey,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // reply/edit-превью теперь ВНУТРИ _composer() (единый блок).
                    _composer(),
                  ],
                ),
              ),
            ),
            // Эмодзи-панель — выезжает снизу, composer сидит НАД ней.
            if (_emojiOpen)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: _emojiPanelH,
                child: EmojiPicker(onPick: _insertEmoji),
              ),
            // Кнопка «вниз» + замочек (TG-style): видна при прокрутке вверх ИЛИ
            // когда есть непрочитанные в этом чате (бейдж).
            if (_showScrollDown || _unreadInChat > 0)
              Positioned(
                right: 14,
                bottom:
                    MediaQuery.of(context).padding.bottom + _composerH + 14,
                child: _scrollDownButton(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _scrollDownButton() {
    // Вариант B: круг-стрелка с бейджем непрочитанных (как в TG) + мини-замочек
    // над ней. Тап стрелки = 2-stage (1-й центрирует линию «Новое», 2-й — вниз).
    // Замочек = «не дёргать мой scroll при отправке своего сообщения».
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _scrollLock = !_scrollLock),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _scrollLock
                      ? GE.primary.withValues(alpha: 0.85)
                      : GE.bgDeep.withValues(alpha: 0.55),
                  border: Border.all(color: GE.glassBorder),
                ),
                child: Icon(
                  _scrollLock ? Icons.lock : Icons.lock_open,
                  size: 14,
                  color: _scrollLock ? Colors.white : GE.sub,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onArrowTap,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(23),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: GE.bgDeep.withValues(alpha: 0.6),
                      border: Border.all(color: GE.glassBorder),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.30),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 27,
                      color: GE.text,
                    ),
                  ),
                ),
              ),
              if (_unreadInChat > 0)
                Positioned(
                  top: -4,
                  right: -2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    constraints: const BoxConstraints(minWidth: 20),
                    decoration: BoxDecoration(
                      color: GE.primary,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: GE.bgDeep, width: 1.5),
                    ),
                    child: Text(
                      _unreadInChat > 99 ? '99+' : '$_unreadInChat',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // «Мыло» под шапкой: BackdropFilter размывает сообщения, уезжающие вверх под
  // шапку, + градиент-тинт для мягкого края (не резкая прямая линия). Раньше
  // дико лагало НЕ из-за этого блюра (он мелкий), а из-за расшифровки фото на
  // главном потоке — её вынесли в изолят, так что блюр теперь по карману.
  // Стекло-фон ПОД шапкой. ВИДИМЫЙ слой: светлый тинт (тёмное-на-тёмном не
  // читается, фон чата тёмный) + BackdropFilter для frost. Низ ПЛАВНО
  // растворяется 4-ступенчатым градиентом альфы (без ShaderMask — он на этой
  // сборке гасит сам блюр, стекло пропадало).
  Widget _topBlurFade() {
    final tint = Color.alphaBlend(
      Colors.white.withValues(alpha: 0.10),
      GE.bgDeep,
    );
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: 58,
      child: IgnorePointer(
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    tint.withValues(alpha: 0.95),
                    tint.withValues(alpha: 0.62),
                    tint.withValues(alpha: 0.26),
                    tint.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.4, 0.72, 1.0],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _replyEditBar() {
    final m = _editing ?? _replyTo;
    final isEdit = _editing != null;
    // Внутри стекла композера: без своей карточки, снизу — 1px-разделитель,
    // чтобы reply-превью и поле ввода читались как единый блок.
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: GE.glassBorder, width: 1)),
      ),
      child: Row(
        children: [
            Icon(
              isEdit ? Icons.edit : Icons.reply,
              size: 16,
              color: GE.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEdit ? 'Редактирование' : 'Ответ',
                    style: TextStyle(
                      color: GE.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _msgPreview(m),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: GE.sub, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, size: 18, color: GE.sub),
              onPressed: () {
                setState(() {
                  _replyTo = null;
                  if (isEdit) {
                    _editing = null;
                    _inputCtrl.clear();
                  }
                });
              },
            ),
          ],
        ),
    );
  }

  Widget _empty() {
    return Center(
      child: GlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 40, color: GE.primary),
            const SizedBox(height: 10),
            Text(
              'Напиши первое сообщение',
              style: TextStyle(color: GE.text, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Всё шифруется на твоём устройстве',
              style: TextStyle(color: GE.sub, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    final hasText = _inputCtrl.text.trim().isNotEmpty;
    // НЕ добавляем viewInsets.bottom: Scaffold с resizeToAvoidBottomInset=true
    // (default) уже сжимает body над клавиатурой. Если добавить bottomInset
    // тут — composer улетает на высоту клавиатуры дважды.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            // Стекло как шапка: тёмный тинт тает кверху + золотистая кромка сверху.
            border: Border(
              top: BorderSide(color: Color(0x2BD4B88C), width: 0.7),
            ),
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xCC1C1530), Color(0x801C1530), Color(0x141C1530)],
              stops: [0.0, 0.6, 1.0],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Reply/edit-превью ВНУТРИ стекла композера → единый блок,
              // разделитель — тонкая 1px-линия (см. _replyEditBar).
              if (_replyTo != null || _editing != null) _replyEditBar(),
              Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Лево: при записи — отмена (delete), иначе — вложения.
                _recording
                    ? IconButton(
                        icon: Icon(Icons.delete, color: GE.red),
                        onPressed: () => _stopAndSendRecording(cancel: true),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              _emojiOpen
                                  ? Icons.keyboard_outlined
                                  : Icons.emoji_emotions_outlined,
                              color: _emojiOpen ? GE.primary : GE.sub,
                            ),
                            onPressed: _toggleEmoji,
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: Icon(Icons.attach_file, color: GE.sub),
                            onPressed: _sending ? null : _openAttachSheet,
                          ),
                        ],
                      ),
                // Середина: при записи — таймер+живая вейвформа, иначе поле ввода.
                Expanded(
                  child: _recording
                      ? _recordingMiddle()
                      : TextField(
                          controller: _inputCtrl,
                          minLines: 1,
                          maxLines: 6,
                          style: TextStyle(color: GE.text, fontSize: 15),
                          cursorColor: GE.primary,
                          textInputAction: TextInputAction.newline,
                          onTap: () {
                            // Тап по полю → клавиатура вместо эмодзи-панели.
                            if (_emojiOpen) setState(() => _emojiOpen = false);
                          },
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'Сообщение',
                            hintStyle: TextStyle(color: GE.sub),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 10,
                            ),
                          ),
                        ),
                ),
                // Право: текст→отправка; запись-hands-free→отправка голосового;
                // иначе микрофон (тап=hands-free; удержание→отпуск=отправка).
                Material(
                  color: Colors.transparent,
                  child: hasText
                      ? InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _sending ? null : _send,
                          child: _circleBtn(
                            _sending
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.send,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                          ),
                        )
                      : (_recording && _handsFree)
                      ? GestureDetector(
                          onTap: () => _stopAndSendRecording(),
                          child: _circleBtn(
                            const Icon(
                              Icons.send,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        )
                      : GestureDetector(
                          onTap: () {
                            if (!_recording) _startRecording(handsFree: true);
                          },
                          onLongPressStart: (_) {
                            if (!_recording) _startRecording(handsFree: false);
                          },
                          onLongPressEnd: (_) {
                            if (_recording && !_handsFree) {
                              _stopAndSendRecording();
                            }
                          },
                          child: _circleBtn(
                            const Icon(
                              Icons.mic,
                              color: Colors.white,
                              size: 20,
                            ),
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

  Widget _circleBtn(Widget child) => Container(
    width: 42,
    height: 42,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(colors: [GE.primary2, GE.primary]),
    ),
    alignment: Alignment.center,
    child: child,
  );

  // Середина композера при записи: точка + таймер + живая вейвформа.
  // delete (отмена) — левая кнопка, send — правая (см. _composer).
  Widget _recordingMiddle() {
    final mm = _recordDur.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = _recordDur.inSeconds.remainder(60).toString().padLeft(2, '0');
    final recent = _recWave.length > 40
        ? _recWave.sublist(_recWave.length - 40)
        : _recWave;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(Icons.fiber_manual_record, color: GE.red, size: 12),
          const SizedBox(width: 6),
          Text(
            '$mm:$ss',
            style: TextStyle(
              color: GE.text,
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 24,
              child: CustomPaint(
                painter: _WaveformPainter(
                  bars: recent.isEmpty ? const [0.1] : recent,
                  progress: 1.0,
                  bg: GE.primary.withValues(alpha: 0.4),
                  fill: GE.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
class _ReactionsBar extends StatelessWidget {
  final void Function(String emoji) onPick;
  const _ReactionsBar({required this.onPick});
  // Server-сторона хранит raw-emoji строкой — сохраняем совместимость.
  // Визуально рендерим Material иконку для каждого (одинаково на всех ОС).
  static const _picks = <_Pick>[
    _Pick('❤', Icons.favorite, Color(0xFFef4444)),
    _Pick('👍', Icons.thumb_up, Color(0xFF60a5fa)),
    _Pick('😂', Icons.sentiment_very_satisfied, Color(0xFFfacc15)),
    _Pick('😮', Icons.sentiment_neutral, Color(0xFFfb923c)),
    _Pick('😢', Icons.sentiment_dissatisfied, Color(0xFF60a5fa)),
    _Pick('🔥', Icons.local_fire_department, Color(0xFFf97316)),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemBuilder: (_, i) => InkWell(
          onTap: () => onPick(_picks[i].emoji),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            // Twemoji-картинка вместо Material-иконки (тот же набор эмодзи).
            child: EmojiText(
              _picks[i].emoji,
              style: const TextStyle(fontSize: 26),
            ),
          ),
        ),
        separatorBuilder: (_, _) => const SizedBox(width: 2),
        itemCount: _picks.length,
      ),
    );
  }
}

class _Pick {
  final String emoji;
  final IconData icon;
  final Color color;
  const _Pick(this.emoji, this.icon, this.color);
}

// ────────────────────────────────────────────────────────────────────────
/// Маппинг raw-emoji → Material иконка для отображения реакции на сообщении.
/// Сохраняет совместимость с сервером (он хранит raw-symbol), но рендерит
/// стилистически единый Material набор поверх любой ОС.
// Реакция рендерится тем же Twemoji-набором, что и эмодзи (а не Material-иконкой).
Widget _chatReactionIcon(String key, {double size = 12, required Color color}) {
  return EmojiText(key, style: TextStyle(color: color, fontSize: size));
}

/// Парсит created_at (наивная UTC-строка / unix int) → локальное DateTime.
/// Сервер шлёт UTC без 'Z' — помечаем как UTC, иначе время уезжает на TZ.
DateTime _msgLocal(dynamic at) {
  if (at is int) {
    return DateTime.fromMillisecondsSinceEpoch(at * 1000).toLocal();
  }
  final p = DateTime.parse(at.toString());
  final utc = p.isUtc
      ? p
      : DateTime.utc(
          p.year,
          p.month,
          p.day,
          p.hour,
          p.minute,
          p.second,
          p.millisecond,
        );
  return utc.toLocal();
}

bool _msgSameDay(dynamic a, dynamic b) {
  final la = _msgLocal(a), lb = _msgLocal(b);
  return la.year == lb.year && la.month == lb.month && la.day == lb.day;
}

/// «Сегодня» / «Вчера» / «12 июня» / «12 июня 2024».
String _msgDateLabel(dynamic at) {
  final d = _msgLocal(at);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Сегодня';
  if (diff == 1) return 'Вчера';
  const months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  final base = '${d.day} ${months[d.month - 1]}';
  return d.year == now.year ? base : '$base ${d.year}';
}

/// Премиум-пилюля даты-разделителя между днями.
Widget _dateChip(dynamic at) {
  return Center(
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 0.5,
        ),
      ),
      child: Text(
        _msgDateLabel(at),
        style: TextStyle(
          color: GE.sub,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

/// Текстовое превью сообщения для reply-бара и reply-превью: текст, либо
/// «Голосовое сообщение» / «Фото» / «Видео» / «Файл: …» для медиа.
String _msgPreview(StoredMessage? m, {int max = 100}) {
  if (m == null) return '';
  if (m.text.isNotEmpty) {
    return m.text.length > max ? '${m.text.substring(0, max)}…' : m.text;
  }
  final fp = m.filePayload;
  if (fp != null) {
    if (fp['voice'] == true || fp['voice'] == 1) return 'Голосовое сообщение';
    final mime = fp['mime'] as String? ?? '';
    if (mime.startsWith('image/')) return 'Фото';
    if (mime.startsWith('video/')) return 'Видео';
    final name = fp['file_name'] as String?;
    return name != null && name.isNotEmpty ? 'Файл: $name' : 'Файл';
  }
  return '';
}

class _Bubble extends StatelessWidget {
  final StoredMessage m;
  final String? myUsername;
  final bool highlighted;
  final bool prevSame;
  const _Bubble(
    this.m, {
    this.myUsername,
    this.highlighted = false,
    this.prevSame = false,
  });

  @override
  Widget build(BuildContext context) {
    final mine = m.fromMe;
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;
    // Тёмный лакшери: свои — глубокий фиолет-градиент, чужие — solid (фон ниже).
    final bg = mine
        ? const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF6A4FD0), Color(0xFF3F2E9C)],
          )
        : const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1C1726), Color(0xFF131019)],
          );
    final textColor = mine ? Colors.white : const Color(0xFFD7D2DE);
    final isImg = _isImage(m);
    // Подряд идущие сообщения одного автора — теснее (верх 1), их размытие
    // соединяется; на смене автора — отступ больше (верх 5).
    final vPad = EdgeInsets.only(top: prevSame ? 1.0 : 5.0, bottom: 1.0);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: align,
      decoration: highlighted
          ? BoxDecoration(
              color: GE.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(GE.radiusMd),
              border: Border.all(
                color: GE.primary.withValues(alpha: 0.75),
                width: 1.5,
              ),
            )
          : null,
      padding: highlighted ? const EdgeInsets.all(4) : EdgeInsets.zero,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Container(
          margin: vPad,
          padding: m.filePayload != null && isImg
              ? const EdgeInsets.all(4)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            // Тёмный лакшери: чужие — тёмный градиент, свои — фиолет-градиент;
            // тонкая светлая кромка (у своих ярче = inset-блик) + одна мягкая
            // тень для премиум-объёма (лёгкая, без перегруза GPU).
            gradient: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(mine ? 16 : 6),
              bottomRight: Radius.circular(mine ? 6 : 16),
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: mine ? 0.16 : 0.07),
              width: 0.7,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),

          child: IntrinsicWidth(
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.forwardedFrom != null) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.share,
                      size: 11,
                      color: textColor.withValues(alpha: 0.65),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '@${m.forwardedFrom}',
                      style: TextStyle(
                        color: textColor.withValues(alpha: 0.75),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
              ],
              if (m.replyPreview != null && m.replyPreview!.isNotEmpty) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: textColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(7),
                    border: Border(
                      left: BorderSide(
                        color: mine
                            ? Colors.white.withValues(alpha: 0.65)
                            : GE.primary,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Text(
                    m.replyPreview!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.85),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              if (m.deleted)
                Text(
                  '🗑 удалено',
                  style: TextStyle(
                    color: textColor.withValues(alpha: 0.55),
                    fontStyle: FontStyle.italic,
                    fontSize: 13,
                  ),
                )
              else ...[
                if (m.filePayload != null)
                  _MediaPart(m: m, textColor: textColor),
                if (m.text.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(
                      top: m.filePayload != null ? 4 : 0,
                    ),
                    child: EmojiText(
                      m.text,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 15,
                        height: 1.35,
                      ),
                    ),
                  ),
              ],
              if (m.reactions != null && m.reactions!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      for (final e in m.reactions!.entries)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: textColor.withValues(alpha: 0.28),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: textColor.withValues(alpha: 0.35),
                              width: 0.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _chatReactionIcon(
                                e.key,
                                size: 14,
                                color: textColor,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '${e.value.length}',
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 2),
              // #7: время+галочки к краю — у своих справа, у чужих слева.
              Align(
                alignment:
                    mine ? Alignment.centerRight : Alignment.centerLeft,
                child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (m.edited) ...[
                    Icon(
                      Icons.edit,
                      size: 10,
                      color: textColor.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 3),
                  ],
                  Text(
                    _formatTime(m.createdAt),
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.65),
                      fontSize: 10,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (mine) ...[const SizedBox(width: 4), _ticks(m)],
                ],
                ),
              ),
            ],
          )),
        ),
      ),
    );
  }

  bool _isImage(StoredMessage m) {
    final mime = m.filePayload?['mime'] as String?;
    return mime != null && mime.startsWith('image/');
  }

  Widget _ticks(StoredMessage m) {
    if (m.pending) {
      return const Icon(Icons.access_time, size: 11, color: Colors.white70);
    }
    if (m.read) {
      return Icon(Icons.done_all, size: 14, color: GE.blue); // 2 cyan — прочитано
    }
    if (m.delivered) {
      return const Icon(Icons.done, size: 13, color: Colors.white70); // 1 — доставлено
    }
    // На сервере, но получатель ещё не подтвердил доставку — дискета
    // (промежуточное состояние, по просьбе waki вернули 4-м статусом).
    return const Icon(Icons.save_outlined, size: 12, color: Colors.white54);
  }

  String _formatTime(dynamic at) {
    if (at == null) return '';
    DateTime dt;
    try {
      if (at is int) {
        dt = DateTime.fromMillisecondsSinceEpoch(at * 1000);
      } else {
        final p = DateTime.parse(at.toString());
        // Сервер шлёт created_at наивной UTC-строкой (без 'Z') → DateTime.parse
        // трактовал её как локаль и время уезжало на TZ-смещение (−3ч МСК).
        // Помечаем как UTC, потом toLocal даёт верное местное время.
        dt = p.isUtc
            ? p
            : DateTime.utc(
                p.year,
                p.month,
                p.day,
                p.hour,
                p.minute,
                p.second,
                p.millisecond,
              );
      }
    } catch (_) {
      return '';
    }
    return DateFormat('HH:mm').format(dt.toLocal());
  }
}

// ────────────────────────────────────────────────────────────────────────
class _MediaPart extends StatefulWidget {
  final StoredMessage m;
  final Color textColor;
  const _MediaPart({required this.m, required this.textColor});

  @override
  State<_MediaPart> createState() => _MediaPartState();
}

class _MediaPartState extends State<_MediaPart> {
  Uint8List? _bytes;
  bool _loading = false;
  bool _failed = false;

  bool get _isImage =>
      (widget.m.filePayload?['mime'] as String?)?.startsWith('image/') ?? false;
  bool get _isVoice =>
      widget.m.filePayload?['voice'] == true ||
      widget.m.filePayload?['voice'] == 1;
  bool get _isVideo =>
      (widget.m.filePayload?['mime'] as String?)?.startsWith('video/') ?? false;
  // Аудио-ФАЙЛ (mp3 и т.п.), не голосовое — свой плеер как у voice + имя/размер.
  bool get _isAudioFile =>
      !_isVoice &&
      ((widget.m.filePayload?['mime'] as String?)?.startsWith('audio/') ??
          false);

  @override
  void initState() {
    super.initState();
    // Пока сообщение pending (своё изображение грузится на сервер) — НЕ грузим:
    // blob ещё не на сервере, расшифровка упадёт. Загрузим после промоушена
    // (баббл пересоздастся с новым sid → initState снова, уже не pending).
    if (_isImage && !widget.m.pending) _load();
  }

  Future<Uint8List?> _load() async {
    if (_loading) return _bytes;
    if (_bytes != null) return _bytes;
    setState(() => _loading = true);
    try {
      final b = await ChatRepo.instance.decryptMediaBlob(widget.m);
      if (!mounted) return b;
      setState(() {
        _bytes = b;
        _failed = b == null;
        _loading = false;
      });
      return b;
    } catch (_) {
      if (!mounted) return null;
      setState(() {
        _failed = true;
        _loading = false;
      });
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isImage) return _imageView();
    if (_isVideo) return _videoView(); // видео само рисует прогресс/превью
    final Widget media = _isVoice
        ? _voiceView()
        : _isAudioFile
        ? _audioFileView()
        : _fileView();
    // #2/#3: пока файл/аудио ГРУЗИТСЯ — тонкий бар прогресса снизу.
    if (widget.m.pending) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [media, const SizedBox(height: 5), _pendingUploadBar()],
      );
    }
    return media;
  }

  // Тонкая полоса загрузки + % для file/audio во время отправки (как в TG).
  Widget _pendingUploadBar() {
    return ValueListenableBuilder<double>(
      valueListenable: ChatRepo.instance.uploadProgress(widget.m.tempSid ?? ''),
      builder: (_, p, __) {
        final done = p >= 1.0;
        final pct = (p * 100).clamp(0, 100).round();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 120,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: done ? null : (p > 0 ? p : null),
                  minHeight: 4,
                  backgroundColor: widget.textColor.withValues(alpha: 0.2),
                  color: GE.primary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              done ? 'Обработка…' : 'Отправка $pct%',
              style: TextStyle(
                color: widget.textColor.withValues(alpha: 0.7),
                fontSize: 10,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _imageView() {
    if (widget.m.pending) {
      // Превью: само фото СРАЗУ (из локального файла) под оверлеем с прогрессом.
      final localPath = widget.m.filePayload?['_local'] as String?;
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 240,
          height: 180,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (localPath != null)
                Image.file(
                  File(localPath),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) =>
                      const ColoredBox(color: Colors.black26),
                )
              else
                const ColoredBox(color: Colors.black26),
              const ColoredBox(color: Color(0x55000000)),
              Center(child: _uploadProgressIndicator()),
            ],
          ),
        ),
      );
    }
    if (_loading) {
      return Container(
        width: 240,
        height: 180,
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: CircularProgressIndicator(strokeWidth: 2, color: GE.primary),
      );
    }
    if (_failed || _bytes == null) {
      return Container(
        width: 240,
        height: 80,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(
          'Не удалось расшифровать картинку',
          textAlign: TextAlign.center,
          style: TextStyle(color: GE.red, fontSize: 12),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          PageRouteBuilder<void>(
            opaque: false,
            barrierColor: Colors.black,
            pageBuilder: (_, _, _) => _PhotoViewer(bytes: _bytes!),
          ),
        ),
        // cacheWidth: декодим фото в ~2x от ширины показа (240), а не в полном
        // разрешении — иначе большой снимок жрёт десятки МБ и дико лагает.
        child: Image.memory(
          _bytes!,
          width: 240,
          fit: BoxFit.cover,
          cacheWidth: 480,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
        ),
      ),
    );
  }

  Widget _voiceView() {
    final dur = (widget.m.filePayload?['duration'] as int?) ?? 0;
    final wf = widget.m.filePayload?['waveform'];
    final waveform = wf is List
        ? wf.map((e) => (e as num).toDouble()).toList()
        : const <double>[];
    return _VoiceTile(
      durationSec: dur,
      bytes: _bytes,
      loading: _loading,
      onLoad: _load,
      textColor: widget.textColor,
      waveform: waveform,
      localPath: widget.m.filePayload?['_local'] as String?,
    );
  }

  // Аудио-файл (mp3 и т.п.): хедер «имя · размер» + плеер как у голосового.
  Widget _audioFileView() {
    final fp = widget.m.filePayload!;
    final name = fp['file_name'] as String? ?? 'аудио';
    final size = (fp['size'] as int?) ?? 0;
    // Расширение для проигрывателя — из имени файла (mp3/flac/ogg…), иначе mp3.
    final dot = name.lastIndexOf('.');
    final ext = (dot > 0 && name.length - dot <= 6)
        ? name.substring(dot + 1).toLowerCase()
        : 'mp3';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 270),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2, bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.audiotrack,
                  size: 15,
                  color: widget.textColor.withValues(alpha: 0.75),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: widget.textColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _humanSize(size),
                  style: TextStyle(
                    color: widget.textColor.withValues(alpha: 0.55),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          _VoiceTile(
            durationSec: 0,
            bytes: _bytes,
            loading: _loading,
            onLoad: _load,
            textColor: widget.textColor,
            waveform: const <double>[],
            ext: ext,
            localPath: widget.m.filePayload?['_local'] as String?,
          ),
        ],
      ),
    );
  }

  // Спиннер с процентами загрузки медиа (как в TG) — прогресс по tempSid.
  Widget _uploadProgressIndicator() {
    return ValueListenableBuilder<double>(
      valueListenable: ChatRepo.instance.uploadProgress(
        widget.m.tempSid ?? '',
      ),
      builder: (_, p, __) {
        // Загрузка завершена (100%), но ещё ждём ack сервера → «Обработка…»
        // (раньше залипало на «Отправка 100%»).
        final done = p >= 1.0;
        final pct = (p * 100).clamp(0, 100).round();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 42,
              height: 42,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: done ? null : (p > 0 ? p : null),
                    strokeWidth: 3,
                    color: GE.primary,
                    backgroundColor: Colors.white24,
                  ),
                  if (!done)
                    Text(
                      '$pct',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              done ? 'Обработка…' : 'Отправка $pct%',
              style: TextStyle(color: GE.sub, fontSize: 11),
            ),
          ],
        );
      },
    );
  }

  Widget _videoView() {
    final fp = widget.m.filePayload!;
    final name = fp['file_name'] as String? ?? 'видео';
    final size = (fp['size'] as int?) ?? 0;
    final thumbB64 = fp['thumb'] as String?;
    Uint8List? thumb;
    if (thumbB64 != null) {
      try {
        thumb = base64Decode(thumbB64);
      } catch (_) {}
    }
    // Плашка видео с превью-кадром (первый кадр) под оверлеем.
    Widget shell(Widget overlay) => ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 240,
        height: 150,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumb != null)
              Image.memory(
                thumb,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
              )
            else
              const ColoredBox(color: Colors.black54),
            const ColoredBox(color: Color(0x55000000)),
            Center(child: overlay),
          ],
        ),
      ),
    );
    if (widget.m.pending) {
      return shell(_uploadProgressIndicator());
    }
    // Тап — ВСТРОЕННЫЙ плеер (приватность).
    return GestureDetector(
      onTap: _openVideoInternal,
      child: shell(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white24,
              ),
              child: Icon(
                _loading ? Icons.hourglass_top : Icons.play_arrow,
                color: Colors.white,
                size: 30,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            Text(
              _humanSize(size),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Расшифровать (если ещё нет) и открыть медиа/файл системным приложением.
  Future<void> _openExternally() async {
    var b = _bytes;
    if (b == null) {
      await _load();
      b = _bytes;
    }
    if (b == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть файл')),
        );
      }
      return;
    }
    try {
      final fp = widget.m.filePayload!;
      final mime = (fp['mime'] as String?) ?? '';
      var name = (fp['file_name'] as String?) ?? 'file';
      // Расширение берём по MIME (а не по имени из запроса) — иначе система не
      // поймёт, чем открыть (например аудио, присланное «как файл»).
      final ext = _extFromMime(mime);
      if (ext != null && !name.toLowerCase().endsWith(ext)) {
        final dot = name.lastIndexOf('.');
        if (dot > 0 && name.length - dot <= 5) name = name.substring(0, dot);
        name = '$name$ext';
      }
      final safe = name.replaceAll(RegExp(r'[^\w.\-]'), '_');
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/$safe';
      await File(path).writeAsBytes(b);
      // type=MIME помогает Android выбрать правильное приложение (плеер и т.п.).
      await OpenFilex.open(path, type: mime.isNotEmpty ? mime : null);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не открылось: $e')),
        );
      }
    }
  }

  /// Расшифровать видео в temp-файл и открыть ВСТРОЕННЫЙ плеер (приватность:
  /// видео НЕ уходит во внешнее приложение, которое могло бы его логировать).
  Future<void> _openVideoInternal() async {
    var b = _bytes;
    if (b == null) {
      setState(() => _loading = true);
      await _load();
      b = _bytes;
      if (mounted) setState(() => _loading = false);
    }
    if (b == null || !mounted) return;
    try {
      final fp = widget.m.filePayload!;
      final mime = (fp['mime'] as String?) ?? 'video/mp4';
      final ext = _extFromMime(mime) ?? '.mp4';
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/ghost_vid_${widget.m.sid}$ext';
      await File(path).writeAsBytes(b);
      if (!mounted) return;
      Navigator.of(context).push(
        PageRouteBuilder<void>(
          opaque: false,
          barrierColor: Colors.black,
          pageBuilder: (_, _, _) => _VideoViewer(path: path),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не открылось видео: $e')),
        );
      }
    }
  }

  /// Расширение файла по MIME-типу (для корректного открытия системой).
  String? _extFromMime(String mime) {
    switch (mime) {
      case 'video/mp4':
        return '.mp4';
      case 'video/quicktime':
        return '.mov';
      case 'video/x-matroska':
        return '.mkv';
      case 'video/webm':
        return '.webm';
      case 'video/3gpp':
        return '.3gp';
      case 'audio/mpeg':
        return '.mp3';
      case 'audio/mp4':
      case 'audio/aac':
        return '.m4a';
      case 'audio/ogg':
      case 'audio/opus':
        return '.ogg';
      case 'audio/wav':
      case 'audio/x-wav':
        return '.wav';
      case 'audio/flac':
        return '.flac';
      case 'image/jpeg':
        return '.jpg';
      case 'image/png':
        return '.png';
      case 'image/gif':
        return '.gif';
      case 'image/webp':
        return '.webp';
      case 'application/pdf':
        return '.pdf';
      case 'application/zip':
        return '.zip';
      default:
        // Общий случай: подтип после '/' если похож на расширение.
        final slash = mime.indexOf('/');
        if (slash > 0 && slash < mime.length - 1) {
          final sub = mime.substring(slash + 1);
          if (RegExp(r'^[a-z0-9]{1,5}$').hasMatch(sub)) return '.$sub';
        }
        return null;
    }
  }

  Widget _fileView() {
    final fp = widget.m.filePayload!;
    final name = fp['file_name'] as String? ?? 'файл';
    final size = (fp['size'] as int?) ?? 0;
    return InkWell(
      onTap: _openExternally,
      child: Container(
        constraints: const BoxConstraints(minWidth: 200),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: widget.textColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _loading ? Icons.hourglass_top : Icons.insert_drive_file,
                color: widget.textColor,
                size: 18,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: widget.textColor, fontSize: 13),
                  ),
                  Text(
                    _humanSize(size),
                    style: TextStyle(
                      color: widget.textColor.withValues(alpha: 0.7),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _humanSize(int b) {
    if (b < 1024) return '$b Б';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} КБ';
    return '${(b / 1024 / 1024).toStringAsFixed(2)} МБ';
  }
}

// ────────────────────────────────────────────────────────────────────────
/// Полноэкранный просмотр фото (как в Telegram): чёрный фон, пинч-зум,
/// свайп вниз закрывает с затуханием, крестик — закрыть.
class _PhotoViewer extends StatefulWidget {
  final Uint8List bytes;
  const _PhotoViewer({required this.bytes});
  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  final _tc = TransformationController();
  double _dragY = 0;

  bool get _zoomed => _tc.value.getMaxScaleOnAxis() > 1.01;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final op = (1 - (_dragY.abs() / 400)).clamp(0.0, 1.0);
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: op),
      body: Stack(
        children: [
          GestureDetector(
            // Свайп вниз закрывает — только пока не увеличено (иначе это пан).
            onVerticalDragUpdate: (d) {
              if (!_zoomed) setState(() => _dragY += d.delta.dy);
            },
            onVerticalDragEnd: (_) {
              if (!_zoomed && _dragY.abs() > 110) {
                Navigator.of(context).pop();
              } else {
                setState(() => _dragY = 0);
              }
            },
            child: Transform.translate(
              offset: Offset(0, _dragY),
              child: InteractiveViewer(
                transformationController: _tc,
                minScale: 1,
                maxScale: 5,
                onInteractionUpdate: (_) => setState(() {}),
                child: Center(child: Image.memory(widget.bytes)),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
/// Рисует полоски-вейвформу голосового (как в Telegram): закрашены слева по
/// прогрессу воспроизведения, остальные — приглушённые.
class _WaveformPainter extends CustomPainter {
  final List<double> bars;
  final double progress;
  final Color bg;
  final Color fill;
  _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.bg,
    required this.fill,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final n = bars.length;
    const gap = 2.0;
    final barW = ((size.width - gap * (n - 1)) / n).clamp(0.5, double.infinity);
    final filled = (progress * n).round();
    final bgPaint = Paint()..color = bg;
    final fillPaint = Paint()..color = fill;
    for (var i = 0; i < n; i++) {
      final h = (bars[i].clamp(0.08, 1.0)) * size.height;
      final x = i * (barW + gap);
      final y = (size.height - h) / 2;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, barW, h),
        Radius.circular(barW / 2),
      );
      canvas.drawRRect(r, i < filled ? fillPaint : bgPaint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.bars != bars ||
      old.fill != fill ||
      old.bg != bg;
}

// Полноэкранный ВСТРОЕННЫЙ видео-плеер: play/pause, перемотка, свайп-вниз для
// закрытия, тап — показать/скрыть управление. Видео уже расшифровано в temp-файл.
class _VideoViewer extends StatefulWidget {
  final String path;
  const _VideoViewer({required this.path});
  @override
  State<_VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<_VideoViewer> {
  VideoPlayerController? _ctrl;
  bool _ready = false;
  bool _showControls = true;
  double _dragY = 0;

  @override
  void initState() {
    super.initState();
    final c = VideoPlayerController.file(File(widget.path));
    _ctrl = c;
    c.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      c.play();
    }).catchError((Object e) {
      // Без этого при сбое декодера экран висит чёрным («не играет»).
      if (!mounted) return;
      Navigator.of(context).maybePop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Видео не воспроизводится: $e')),
      );
    });
    c.addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ctrl?.removeListener(_onTick);
    _ctrl?.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    final bgAlpha = (1 - (_dragY.abs() / 400)).clamp(0.0, 1.0);
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: bgAlpha),
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        onVerticalDragUpdate: (d) => setState(() => _dragY += d.delta.dy),
        onVerticalDragEnd: (_) {
          if (_dragY.abs() > 120) {
            Navigator.of(context).pop();
          } else {
            setState(() => _dragY = 0);
          }
        },
        child: Stack(
          children: [
            Center(
              child: Transform.translate(
                offset: Offset(0, _dragY),
                child: (c != null && _ready)
                    ? AspectRatio(
                        aspectRatio: c.value.aspectRatio == 0
                            ? 16 / 9
                            : c.value.aspectRatio,
                        child: VideoPlayer(c),
                      )
                    : const CircularProgressIndicator(color: Colors.white),
              ),
            ),
            if (_showControls)
              Positioned(
                top: MediaQuery.of(context).padding.top + 6,
                left: 6,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            if (_showControls && c != null && _ready) _controls(c),
          ],
        ),
      ),
    );
  }

  Widget _controls(VideoPlayerController c) {
    final pos = c.value.position;
    final dur = c.value.duration;
    final maxMs = dur.inMilliseconds <= 0 ? 1.0 : dur.inMilliseconds.toDouble();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          8,
          14,
          12,
          MediaQuery.of(context).padding.bottom + 14,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black87],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              icon: Icon(
                c.value.isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 30,
              ),
              onPressed: () => setState(
                () => c.value.isPlaying ? c.pause() : c.play(),
              ),
            ),
            Text(
              _fmt(pos),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            Expanded(
              child: Slider(
                value: pos.inMilliseconds.clamp(0, maxMs.toInt()).toDouble(),
                max: maxMs,
                activeColor: GE.primary,
                inactiveColor: Colors.white24,
                onChanged: (v) =>
                    c.seekTo(Duration(milliseconds: v.round())),
              ),
            ),
            Text(
              _fmt(dur),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceTile extends StatefulWidget {
  final int durationSec;
  final Uint8List? bytes;
  final bool loading;
  final Future<Uint8List?> Function() onLoad; // возвращает байты после загрузки
  final Color textColor;
  final List<double> waveform;
  final String ext; // расширение temp-файла для проигрывателя (m4a/mp3/…)
  final String? localPath; // локальный файл — играть ПОКА грузится (без decrypt)
  const _VoiceTile({
    required this.durationSec,
    required this.bytes,
    required this.loading,
    required this.onLoad,
    required this.textColor,
    this.waveform = const [],
    this.ext = 'm4a',
    this.localPath,
  });

  @override
  State<_VoiceTile> createState() => _VoiceTileState();
}

class _VoiceTileState extends State<_VoiceTile> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _audioDur = Duration.zero;
  double _speed = 1.0;
  String? _tmpPath;
  bool _fromLocal = false; // _tmpPath указывает на локальный файл — не удалять
  Uint8List? _loaded; // байты, полученные через onLoad (если widget.bytes ещё null)
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _durSub;

  @override
  void initState() {
    super.initState();
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _audioDur = d);
    });
    _stateSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _pos = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _durSub?.cancel();
    _player.dispose();
    final p = _tmpPath;
    if (p != null && !_fromLocal) {
      try {
        File(p).delete();
      } catch (_) {}
    }
    super.dispose();
  }

  Future<void> _ensureFile() async {
    if (_tmpPath != null) return;
    // Пока сообщение ГРУЗИТСЯ (нет своих/расшифрованных байт) — играем напрямую
    // из локального файла, без скачивания/decrypt. Его НЕ удаляем в dispose.
    if (widget.bytes == null && _loaded == null && widget.localPath != null) {
      _tmpPath = widget.localPath;
      _fromLocal = true;
      return;
    }
    final data = widget.bytes ?? _loaded;
    if (data == null) return;
    // Играем из ВРЕМЕННОГО ФАЙЛА с ПРАВИЛЬНЫМ расширением (mp3/m4a/…) — иначе
    // нативный плеер не декодит (mp3, записанный в .m4a, не играл).
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/gc_play_${widget.hashCode}.${widget.ext}');
    await f.writeAsBytes(data);
    _tmpPath = f.path;
  }

  Future<void> _toggle() async {
    // localPath != null → играем из локального файла (отправка), onLoad не нужен.
    if (widget.bytes == null && _loaded == null && widget.localPath == null) {
      // Первый тап: грузим blob и СРАЗУ играем (без второго тапа).
      final b = await widget.onLoad();
      if (!mounted || b == null) return;
      setState(() => _loaded = b);
    }
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
    } else {
      await _ensureFile();
      await _player.play(DeviceFileSource(_tmpPath!));
      if (_speed != 1.0) {
        try {
          await _player.setPlaybackRate(_speed);
        } catch (_) {}
      }
      setState(() => _playing = true);
    }
  }

  Future<void> _cycleSpeed() async {
    const speeds = [1.0, 1.5, 2.0];
    final next = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
    setState(() => _speed = next);
    try {
      await _player.setPlaybackRate(next);
    } catch (_) {}
  }

  // Визуал перемотки — МГНОВЕННО (без ожидания аудио-seek): полоски прыгают
  // сразу, аудио догоняет в фоне. Иначе UI ждал ~600мс пока seek на AAC отработает.
  void _seekVisual(double f) {
    final total = _audioDur.inMilliseconds > 0
        ? _audioDur
        : Duration(seconds: widget.durationSec);
    if (total.inMilliseconds == 0) return;
    setState(() {
      _pos = Duration(
        milliseconds: (total.inMilliseconds * f.clamp(0.0, 1.0)).round(),
      );
    });
  }

  // Реальный аудио-seek на текущую визуальную позицию — на тап / отпуск драга
  // (не на каждый drag-update, иначе очередь seek'ов = лаг).
  Future<void> _seekCommit() async {
    try {
      await _player.seek(_pos);
    } catch (_) {}
  }

  // Реальная вейвформа из payload (или мягкий дефолт для старых гс),
  // РАСТЯНУТАЯ интерполяцией до фикс. числа полосок → всегда во всю ширину.
  List<double> get _bars {
    final raw = widget.waveform.isNotEmpty
        ? widget.waveform
        : List<double>.generate(28, (i) => 0.25 + 0.2 * (((i * 13) % 7) / 6));
    return _resample(raw, 40);
  }

  static List<double> _resample(List<double> src, int target) {
    if (src.length <= 1) return List<double>.filled(target, 0.3);
    if (src.length == target) return src;
    final out = <double>[];
    for (var i = 0; i < target; i++) {
      final pos = i * (src.length - 1) / (target - 1);
      final lo = pos.floor();
      final hi = pos.ceil().clamp(0, src.length - 1);
      final t = pos - lo;
      out.add(src[lo] * (1 - t) + src[hi] * t);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final total = _audioDur.inMilliseconds > 0
        ? _audioDur
        : Duration(seconds: widget.durationSec);
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final started = _playing || _pos > Duration.zero;
    return SizedBox(
      width: 246,
      child: Row(
        children: [
          InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(23),
            child: Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.textColor.withValues(alpha: 0.96),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.20),
                    blurRadius: 7,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: widget.loading
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF2A1E50),
                      ),
                    )
                  : Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: const Color(0xFF2A1E50),
                      size: 28,
                    ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 26,
                    child: LayoutBuilder(
                      builder: (ctx, c) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) {
                          _seekVisual(d.localPosition.dx / c.maxWidth);
                          _seekCommit();
                        },
                        onHorizontalDragUpdate: (d) =>
                            _seekVisual(d.localPosition.dx / c.maxWidth),
                        onHorizontalDragEnd: (_) => _seekCommit(),
                        child: CustomPaint(
                          size: Size(c.maxWidth, 26),
                          painter: _WaveformPainter(
                            bars: _bars,
                            progress: progress,
                            bg: widget.textColor.withValues(alpha: 0.30),
                            fill: widget.textColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        _fmt(started ? _pos : total),
                        style: TextStyle(
                          color: widget.textColor.withValues(alpha: 0.7),
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const Spacer(),
                      if (started)
                        GestureDetector(
                          onTap: _cycleSpeed,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: widget.textColor.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              _speed == _speed.roundToDouble()
                                  ? '${_speed.toInt()}x'
                                  : '${_speed}x',
                              style: TextStyle(
                                color: widget.textColor,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final mm = d.inMinutes.toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}

// ────────────────────────────────────────────────────────────────────────
/// Шапка чата: avatar + display_name + @username + online-индикатор.
/// Тап → ProfileScreen (для DM). Презенс через ChatRepo.watchPresence.
// ── Меню действий над сообщением (всплывает у пальца) ──────────────────
class _MenuAction {
  final String value;
  final IconData icon;
  final String label;
  final bool danger;
  const _MenuAction(this.value, this.icon, this.label, {this.danger = false});
}

class _BubbleMenuCard extends StatelessWidget {
  final List<_MenuAction> actions;
  final ValueChanged<String> onPick;
  const _BubbleMenuCard({required this.actions, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Бар реакций — отдельной «пилюлей».
          Container(
            decoration: BoxDecoration(
              color: GE.bgDeep,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: GE.glassBorder),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: _ReactionsBar(onPick: (e) => onPick('react:$e')),
          ),
          const SizedBox(height: 6),
          // Карточка действий.
          Container(
            decoration: BoxDecoration(
              color: GE.bgDeep,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: GE.glassBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final a in actions)
                  InkWell(
                    onTap: () => onPick(a.value),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            a.icon,
                            size: 18,
                            color: a.danger ? GE.red : GE.primary,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            a.label,
                            style: TextStyle(
                              color: a.danger ? GE.red : GE.text,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Шапка режима выбора (вместо _ChatHeader) ──────────────────────────
class _SelectionHeader extends StatelessWidget {
  final int count;
  final bool canCopy;
  final VoidCallback onClose;
  final VoidCallback onCopy;
  final VoidCallback onForward;
  final VoidCallback onDelete;
  const _SelectionHeader({
    required this.count,
    required this.canCopy,
    required this.onClose,
    required this.onCopy,
    required this.onForward,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.close, color: GE.text),
              onPressed: onClose,
            ),
            const SizedBox(width: 4),
            Text(
              '$count',
              style: TextStyle(
                color: GE.text,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            // «Копировать» только если в выборе есть текст (файл не копируем).
            if (canCopy)
              IconButton(
                icon: Icon(Icons.copy_outlined, color: GE.text),
                tooltip: 'Копировать',
                onPressed: onCopy,
              ),
            IconButton(
              icon: Icon(Icons.forward, color: GE.text),
              tooltip: 'Переслать',
              onPressed: onForward,
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: GE.red),
              tooltip: 'Удалить',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  final String peer;
  final String displayName;
  final bool isGroup;
  const _ChatHeader({
    required this.peer,
    required this.displayName,
    required this.isGroup,
  });

  @override
  Widget build(BuildContext context) {
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    return SafeArea(
      bottom: false,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isGroup
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ProfileScreen(username: peer),
                  ),
                ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
            child: Row(
              children: [
                // #2: вся левая зона (край экрана → аватарка) = одна большая
                // tap-зона «назад» (прямоугольник), а не маленький круглый IconButton.
                InkWell(
                  onTap: () => Navigator.of(context).maybePop(),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 11, 18, 11),
                    child: Icon(Icons.arrow_back, color: GE.text),
                  ),
                ),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [GE.primary2, GE.primary],
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        initial,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    if (!isGroup)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: ChatRepo.instance.watchPresence(
                            peer,
                          ),
                          builder: (_, online, __) => Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: online ? GE.green : GE.muted,
                              border: Border.all(color: GE.bg, width: 2),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          shadows: const [
                            Shadow(color: Color(0xCC000000), blurRadius: 5),
                          ],
                        ),
                      ),
                      if (!isGroup)
                        StreamBuilder<bool>(
                          stream: WsClient.instance.onConnectionChange,
                          initialData: WsClient.instance.isConnected,
                          builder: (_, wsSnap) {
                            // Сначала МОЁ соединение (WS+heartbeat): если лежит —
                            // «соединение…», иначе статус собеседника.
                            if (wsSnap.data != true) {
                              return Row(
                                children: [
                                  Text(
                                    '@$peer',
                                    style: TextStyle(
                                      color: GE.sub,
                                      fontSize: 11,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '·',
                                    style: TextStyle(
                                      color: GE.sub,
                                      fontSize: 11,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  const SizedBox(
                                    width: 9,
                                    height: 9,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.4,
                                      color: Color(0xFFE5B567),
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  const Text(
                                    'соединение…',
                                    style: TextStyle(
                                      color: Color(0xFFE5B567),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              );
                            }
                            return ValueListenableBuilder<bool>(
                              valueListenable: ChatRepo.instance.watchPresence(
                                peer,
                              ),
                              builder: (_, online, __) => Row(
                                children: [
                                  Text(
                                    '@$peer',
                                    style: TextStyle(
                                      color: GE.sub,
                                      fontSize: 11,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '·',
                                    style: TextStyle(
                                      color: GE.sub,
                                      fontSize: 11,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    online ? 'в сети' : 'не в сети',
                                    style: TextStyle(
                                      color: online ? GE.green : GE.muted,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      shadows: const [
                                        Shadow(
                                          color: Color(0xCC000000),
                                          blurRadius: 5,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      if (isGroup)
                        Text(
                          peer,
                          style: TextStyle(color: GE.sub, fontSize: 11),
                        ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: GE.sub, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
