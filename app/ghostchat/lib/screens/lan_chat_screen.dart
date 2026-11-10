// LanChatScreen — переписка с устройством поблизости (LAN/BLE/Wi-Fi Direct).
// Текст + файлы (лучше всего работает по LAN — TCP; BLE/Wi-Fi Direct без
// chunking на нативной стороне periферии, крупные файлы могут не дойти —
// см. комментарий в bluetooth_transport.dart). Работает, только пока пир
// реально на связи прямо сейчас — доставка не гарантируется офлайн-пиру.
// История хранится в LanChatStore — привязана к устройству, не к аккаунту.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../widgets/marquee_text.dart';
import '../widgets/attach_sheet.dart';
import '../widgets/chat_composer.dart';
import '../widgets/emoji_picker.dart';
import '../widgets/emoji_text.dart';
import '../widgets/empty_chat_state.dart';
import '../widgets/reactions_bar.dart';
import '../widgets/send_fly_animation.dart';
import '../widgets/toast_overlay.dart';
import '../widgets/video_player_viewer.dart';
import '../services/lan_chat_store.dart';
import '../services/chat_repo.dart';
import '../core/local/app_logger.dart';
import '../core/local/lan_settings.dart';
import '../core/local/local_hub.dart';
import '../core/local/local_transport.dart';
import '../core/local/lan_message_codec.dart';
import 'custom_camera_screen.dart';
import 'chat_picker_screen.dart';

const _maxLanFileBytes =
    10 * 1024 * 1024; // 10MB — best-effort P2P, без прогресс-бара

class LanChatScreen extends StatefulWidget {
  final String deviceId;
  final String displayName;
  const LanChatScreen({
    super.key,
    required this.deviceId,
    required this.displayName,
  });

  /// device_id чата, открытого ПРЯМО СЕЙЧАС — MainShell смотрит сюда, чтобы
  /// не дублировать тост "снова на связи" карточкой на этом же экране (тут и
  /// так видно по бейджу/пропаже офлайн-баннера).
  static String? currentOpenDeviceId;

  @override
  State<LanChatScreen> createState() => _LanChatScreenState();
}

class _LanChatScreenState extends State<LanChatScreen> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<LanChatMessage> _messages = [];
  final Set<String> _seenMsgIds = {};
  final Set<String> _selectedIds = {};
  LanChatMessage? _replyTo;
  LanChatMessage? _editing;
  StreamSubscription? _msgSub;
  StreamSubscription? _onlineSub;
  StreamSubscription? _ackSub;
  StreamSubscription? _seenSub;
  bool _sending = false;
  late String _name;
  bool _online = false;
  bool _emojiOpen = false;
  final _sendBtnKey = GlobalKey();
  final _imagePicker = ImagePicker();
  static const double _emojiPanelH = 300;
  // Мало сообщений — держим ленту у низа, рядом с полем ввода, а не
  // приклеенной к шапке с пустотой снизу (см. тот же приём в chat_screen.dart).
  static const int _bottomAnchorMaxMsgs = 40;

  bool get _selectionMode => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    LanChatScreen.currentOpenDeviceId = widget.deviceId;
    _name = widget.displayName;
    _online =
        localHub.isOnline(widget.deviceId) ||
        localHub.hasSession(widget.deviceId);
    _load();
    _msgSub = localHub.onMessage.listen(_onIncoming);
    // Событийно, а не поллингом раз в 3с — быстрее реагирует и не крутит
    // setState() впустую, когда ничего не изменилось.
    _onlineSub = localHub.onOnlineChanged.listen((e) {
      if (e.key != widget.deviceId || !mounted) return;
      final wasOnline = _online;
      setState(() => _online = e.value);
      // Идея "уведомлять о разрыве": именно в ЭТОМ чате достаточно тихого
      // тоста, баннер офлайн и так появится — не дублируем текстом дважды.
      if (wasOnline && !e.value) {
        toast.show('Устройство отключилось');
      }
    });
    // Статусы галочек (delivered/read) пишет в БД глобальный обработчик в
    // MainShell (_lanAckSub/_lanSeenSub) — сам этот экран о новой записи не
    // узнаёт (объекты в _messages final, setState никто не звал), поэтому
    // галочка не появлялась, пока не перезайти в чат. Перечитываем статусы
    // из БД на каждый ack/seen для ЭТОГО устройства.
    _ackSub = localHub.onAck.listen((e) {
      if (e.fromUsername != widget.deviceId) return;
      _refreshStatuses();
    });
    _seenSub = localHub.onSeen.listen((e) {
      if (e.fromUsername != widget.deviceId) return;
      _refreshStatuses();
    });
    // Автопопытка при открытии чата — юзеру не нужно тыкать кнопку самому,
    // если сессия уже потерялась (сессии транспортов живут только в памяти
    // и пропадают при перезапуске приложения).
    if (!_online) {
      localHub.discoverAll();
    }
  }

  Future<void> _load() async {
    await LanChatStore.instance.markRead(widget.deviceId);
    final msgs = await LanChatStore.instance.getMessages(widget.deviceId);
    if (!mounted) return;
    setState(() {
      _messages.addAll(msgs);
      _seenMsgIds.addAll(msgs.map((m) => m.msgId));
    });
    _scrollToBottom();
    _notifySeen(msgs.where((m) => !m.fromMe).map((m) => m.msgId).toList());
  }

  /// Перечитать статусы (delivered/read) из БД — вызывается на onAck/onSeen,
  /// т.к. эти события пишут в LanChatStore глобально (MainShell), а не в
  /// уже загруженные объекты этого экрана.
  Future<void> _refreshStatuses() async {
    final msgs = await LanChatStore.instance.getMessages(widget.deviceId);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(msgs);
    });
  }

  // Сообщаем собеседнику, что его сообщения прочитаны (двойная галочка у него).
  // Шлём при каждом открытии чата на всю историю, а не только "новое" —
  // повтор безвреден (markMessagesRead на его стороне — идемпотентный UPDATE),
  // а трекать "уже слали seen для этого id" отдельным полем ради P2P-чата
  // избыточно.
  void _notifySeen(List<String> msgIds) {
    if (msgIds.isEmpty || !localHub.hasSession(widget.deviceId)) return;
    localHub.sendSeen(widget.deviceId, msgIds);
  }

  // ВАЖНО: расшифровку и запись в БД делает ТОЛЬКО глобальный обработчик в
  // MainShell (_onLanMessage). Здесь после короткой задержки перечитываем
  // БД: так экран получает новые сообщения и отражает edit/delete-действия,
  // не расшифровывая событие повторно и не создавая гонку за msg_id.
  void _onIncoming(LocalMessageEvent m) {
    if (m.fromUsername != widget.deviceId) return;
    _reloadNewMessages();
  }

  Future<void> _reloadNewMessages() async {
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    final msgs = await LanChatStore.instance.getMessages(widget.deviceId);
    final fresh = msgs.where((m) => !_seenMsgIds.contains(m.msgId)).toList();
    final newIncoming = fresh.where((m) => !m.fromMe).toList();
    if (newIncoming.isNotEmpty) {
      await LanChatStore.instance.markRead(widget.deviceId);
    }
    if (!mounted) return;
    final byId = {for (final message in msgs) message.msgId: message};
    setState(() {
      _seenMsgIds
        ..clear()
        ..addAll(byId.keys);
      _messages
        ..clear()
        ..addAll(msgs);
      _selectedIds.removeWhere((id) => !byId.containsKey(id));
      if (_replyTo != null) _replyTo = byId[_replyTo!.msgId];
      if (_editing != null && !byId.containsKey(_editing!.msgId)) {
        _editing = null;
      } else if (_editing != null) {
        _editing = byId[_editing!.msgId];
      }
    });
    if (fresh.isNotEmpty) _scrollToBottom();
    _notifySeen(newIncoming.map((m) => m.msgId).toList());
  }

  void _toggleEmoji() {
    setState(() => _emojiOpen = !_emojiOpen);
    if (_emojiOpen) FocusScope.of(context).unfocus();
  }

  void _insertEmoji(String e) {
    final text = _msgCtrl.text;
    final sel = _msgCtrl.selection;
    final start = sel.start < 0 ? text.length : sel.start;
    final end = sel.end < 0 ? text.length : sel.end;
    final next = text.replaceRange(start, end, e);
    _msgCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + e.length),
    );
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    final replyTo = _replyTo;
    final replyPreview = replyTo == null ? null : _messagePreview(replyTo);
    final editing = _editing;
    flySendAnimation(context, _sendBtnKey);

    setState(() => _sending = true);
    try {
      if (editing != null) {
        await LanChatStore.instance.editMessageText(
          widget.deviceId,
          editing.msgId,
          text,
          fromMe: true,
        );
        try {
          await _sendControlAction(
            action: 'edit',
            targetMsgId: editing.msgId,
            text: text,
          );
        } catch (error) {
          toast.show('Изменение сохранено только на этом устройстве: $error');
        }
        final messages = await LanChatStore.instance.getMessages(
          widget.deviceId,
        );
        if (!mounted) return;
        setState(() {
          _messages
            ..clear()
            ..addAll(messages);
          _msgCtrl.clear();
          _editing = null;
          _replyTo = null;
        });
        return;
      }
      final peerPubB64 = await LanChatStore.instance.getPeerPub(
        widget.deviceId,
      );
      if (peerPubB64 == null) throw StateError('Нет ключа собеседника');

      final msgId = const Uuid().v4();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final encB64 = await encodeLanEnvelope(
        peerPubB64: peerPubB64,
        text: text,
        replyPreview: replyPreview,
      );
      // Офлайн — не блокируем отправку: шифруем и кладём в очередь, реально
      // уйдёт при переподключении (см. флаш очереди в MainShell).
      final online = localHub.hasSession(widget.deviceId);
      if (online) {
        await localHub.sendMessage(
          widget.deviceId,
          msgId,
          encB64,
          nowMs,
          replyToMsgId: replyTo?.msgId ?? '',
        );
      }
      await LanChatStore.instance.addMessage(
        deviceId: widget.deviceId,
        msgId: msgId,
        fromMe: true,
        text: text,
        createdAtSec: nowMs ~/ 1000,
        queued: !online,
        replyToMsgId: replyTo?.msgId,
        replyPreview: replyPreview,
      );
      if (!mounted) return;
      _seenMsgIds.add(msgId);
      setState(() {
        _messages.add(
          LanChatMessage(
            msgId: msgId,
            deviceId: widget.deviceId,
            fromMe: true,
            text: text,
            createdAt: nowMs ~/ 1000,
            queued: !online,
            replyToMsgId: replyTo?.msgId,
            replyPreview: replyPreview,
          ),
        );
        _msgCtrl.clear();
        _replyTo = null;
      });
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendControlAction({
    required String action,
    required String targetMsgId,
    String? text,
  }) async {
    final controlMsgId = const Uuid().v4();
    final sentAt = DateTime.now().millisecondsSinceEpoch;
    final peerPubB64 = await LanChatStore.instance.getPeerPub(widget.deviceId);
    if (peerPubB64 == null) throw StateError('Нет ключа собеседника');
    if (!localHub.hasSession(widget.deviceId)) {
      await LanChatStore.instance.queueControlAction(
        deviceId: widget.deviceId,
        msgId: controlMsgId,
        action: action,
        targetMsgId: targetMsgId,
        text: text,
      );
      return;
    }
    try {
      final encB64 = await encodeLanControlEnvelope(
        peerPubB64: peerPubB64,
        action: action,
        targetMsgId: targetMsgId,
        text: text,
      );
      await localHub.sendMessage(widget.deviceId, controlMsgId, encB64, sentAt);
    } catch (_) {
      await LanChatStore.instance.queueControlAction(
        deviceId: widget.deviceId,
        msgId: controlMsgId,
        action: action,
        targetMsgId: targetMsgId,
        text: text,
      );
    }
  }

  // Единый лист вложений (та же «скрепка», что в основном чате). Грид
  // галереи/фото/видео/файл; гео и кошелёк — заглушки до готового бэкенда
  // (как в chat_screen). P2P-канал не резиновый — крупные файлы отсекаем в
  // _sendLanBytes (10MB).
  Future<void> _openAttachSheet() async {
    if (_editing != null) {
      toast.show('Текст сообщения редактируется отдельно от вложений');
      return;
    }
    HapticFeedback.selectionClick();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AttachSheet(
        onPickedSend: _sendPickedItems,
        onGallery: () => _pickImageAndSend(ImageSource.gallery),
        onFile: _pickFileAndSend,
        onCamera: _openCustomCamera,
        onGeo: () => toast.show('Геопозиция — скоро'),
        onWallet: () => toast.show('Кошелёк — после интеграции GhostBank'),
      ),
    );
  }

  Future<void> _sendPickedItems(List<AttachItem> items) async {
    for (final it in items) {
      try {
        final bytes = await it.file.readAsBytes();
        await _sendLanBytes(
          bytes,
          p.basename(it.file.path),
          it.isVideo ? 'video/mp4' : 'image/jpeg',
        );
      } catch (e) {
        toast.show('Не удалось отправить: $e');
      }
    }
  }

  Future<void> _pickImageAndSend(ImageSource src) async {
    try {
      final x = await _imagePicker.pickImage(
        source: src,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      );
      if (x == null) return;
      await _sendLanBytes(await x.readAsBytes(), x.name, 'image/jpeg');
    } catch (e) {
      toast.show('Не удалось отправить фото: $e');
    }
  }

  Future<void> _openCustomCamera() async {
    final file = await Navigator.of(
      context,
    ).push<File>(MaterialPageRoute(builder: (_) => const GhostCameraScreen()));
    if (file == null || !mounted) return;
    try {
      await _sendLanBytes(
        await file.readAsBytes(),
        p.basename(file.path),
        'image/jpeg',
      );
    } catch (e) {
      toast.show('Фото не отправилось: $e');
    }
  }

  Future<void> _pickFileAndSend() async {
    final file = await openFile();
    if (file == null) return;
    try {
      await _sendLanBytes(await file.readAsBytes(), file.name, file.mimeType);
    } catch (e) {
      toast.show('Не удалось отправить файл: $e');
    }
  }

  // Общая отправка байтов файла по P2P (шифрование + очередь + оптимистичный
  // пузырь) — используется всеми ветками листа вложений.
  Future<void> _sendLanBytes(Uint8List bytes, String name, String? mime) async {
    if (bytes.length > _maxLanFileBytes) {
      toast.show('Файл больше 10MB — P2P-канал не резиновый');
      return;
    }
    final peerPubB64 = await LanChatStore.instance.getPeerPub(widget.deviceId);
    if (peerPubB64 == null) {
      toast.show('Нет ключа собеседника');
      return;
    }
    final msgId = const Uuid().v4();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final replyTo = _replyTo;
    final replyPreview = replyTo == null ? null : _messagePreview(replyTo);
    final encB64 = await encodeLanEnvelope(
      peerPubB64: peerPubB64,
      fileName: name,
      fileMime: mime,
      fileBytes: bytes,
      replyPreview: replyPreview,
    );
    final online = localHub.hasSession(widget.deviceId);
    if (online) {
      await localHub.sendMessage(
        widget.deviceId,
        msgId,
        encB64,
        nowMs,
        replyToMsgId: replyTo?.msgId ?? '',
      );
    }
    await LanChatStore.instance.addMessage(
      deviceId: widget.deviceId,
      msgId: msgId,
      fromMe: true,
      createdAtSec: nowMs ~/ 1000,
      fileName: name,
      fileMime: mime,
      fileBytes: bytes,
      queued: !online,
      replyToMsgId: replyTo?.msgId,
      replyPreview: replyPreview,
    );
    if (!mounted) return;
    _seenMsgIds.add(msgId);
    setState(() {
      _messages.add(
        LanChatMessage(
          msgId: msgId,
          deviceId: widget.deviceId,
          fromMe: true,
          text: '',
          createdAt: nowMs ~/ 1000,
          fileName: name,
          fileMime: mime,
          fileBytes: bytes,
          queued: !online,
          replyToMsgId: replyTo?.msgId,
          replyPreview: replyPreview,
        ),
      );
      _replyTo = null;
    });
    _scrollToBottom();
  }

  Future<void> _openLanFile(LanChatMessage m) async {
    if (!m.hasFile) return;
    try {
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path, m.fileName!);
      final f = File(path);
      await f.writeAsBytes(m.fileBytes!, flush: true);
      final mime = m.fileMime ?? '';
      if (mime.startsWith('video/')) {
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GhostVideoViewer(
              path: path,
              deleteWhenClosed: true,
              title: m.fileName,
            ),
          ),
        );
        return;
      }
      if (mime.startsWith('image/')) {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          barrierColor: GE.scrimStrong,
          builder: (_) => Dialog(
            backgroundColor: GE.shadow,
            insetPadding: EdgeInsets.zero,
            child: InteractiveViewer(child: Image.file(f, fit: BoxFit.contain)),
          ),
        );
        return;
      }
      await OpenFilex.open(path);
    } catch (e) {
      toast.show('Не удалось открыть файл: $e');
    }
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Переименовать', style: TextStyle(color: GE.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: GE.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    await LanChatStore.instance.renameChat(widget.deviceId, newName);
    if (mounted) setState(() => _name = newName);
  }

  Future<void> _deleteChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Удалить чат?', style: TextStyle(color: GE.text)),
        content: Text(
          'Переписка с $_name по LAN удалится с этого устройства. Отменить нельзя.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text('Удалить', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await LanChatStore.instance.clearChat(widget.deviceId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openChatMenu() async {
    final action = await showGlassSheet<String>(
      context,
      // Без фиксированной height — 140 не хватало на некоторых устройствах
      // (RenderFlex overflow), высота меню сама подстраивается под контент.
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _menuRow(
              CupertinoIcons.pencil,
              'Переименовать',
              GE.primary,
              'rename',
            ),
            _menuRow(CupertinoIcons.trash, 'Удалить чат', GE.red, 'delete'),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (action == 'rename') await _rename();
    if (action == 'delete') await _deleteChat();
  }

  Widget _menuRow(IconData icon, String label, Color color, String value) {
    return InkWell(
      onTap: () => Navigator.pop(context, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color: color == GE.red ? GE.red : GE.text,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _pinging = false;

  /// Кнопка активна ВСЕГДА (не только пока "в сети") — именно в момент,
  /// когда чат выглядит офлайн, юзеру и нужна кнопка "попробовать снова".
  /// Если живой транспортной сессии нет (например, приложение перезапускали
  /// — сессии живут только в памяти) — сессии пинговать нечем, вместо этого
  /// шлём широковещательный discover: если это устройство ещё помнит нас
  /// (см. автопереподключение в local_hub.dart), оно само отзовётся.
  Future<void> _manualPing() async {
    if (_pinging) return;
    await LanSettings().load();
    if (!LanSettings().lanPingEnabled) {
      toast.show('LAN-пинг выключен в настройках');
      return;
    }
    setState(() => _pinging = true);
    try {
      if (localHub.hasSession(widget.deviceId)) {
        await localHub.pingNow(widget.deviceId);
        if (!mounted) return;
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        final isOnline = localHub.isOnline(widget.deviceId);
        final pingMs = localHub.getPingMs(widget.deviceId);
        toast.show(
          isOnline
              ? (pingMs != null ? 'Понг получен — $pingMs мс' : 'Понг получен')
              : 'Нет ответа — устройство недоступно',
        );
      } else {
        // Событийно ждём accept ИМЕННО от этого устройства, а не фиксированную
        // паузу — на другой стороне окно сбора сигналов 5 сек (см.
        // local_hub.dart), фиксированные 3с раньше давали ложный "не
        // отозвалось" даже когда реконнект вот-вот произойдёт.
        final completer = Completer<bool>();
        late StreamSubscription sub;
        sub = localHub.onAccept.listen((peer) {
          if (peer.deviceId == widget.deviceId && !completer.isCompleted) {
            completer.complete(true);
          }
        });
        await localHub.discoverAll();
        final reconnected = await completer.future.timeout(
          const Duration(seconds: 9),
          onTimeout: () => false,
        );
        await sub.cancel();
        if (!mounted) return;
        toast.show(
          reconnected
              ? 'Подключение восстановлено'
              : 'Устройство не отозвалось — попробуйте ещё раз позже',
        );
      }
    } finally {
      if (mounted) setState(() => _pinging = false);
    }
  }

  void _toggleSelect(String msgId) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedIds.contains(msgId)) {
        _selectedIds.remove(msgId);
      } else {
        _selectedIds.add(msgId);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final ids = _selectedIds.toList();
    final selected = _messages
        .where((message) => ids.contains(message.msgId))
        .toList(growable: false);
    for (final message in selected.where((message) => message.fromMe)) {
      try {
        await _sendControlAction(action: 'delete', targetMsgId: message.msgId);
      } catch (error) {
        toast.show('Не удалось подготовить удаление для собеседника: $error');
      }
    }
    await LanChatStore.instance.deleteMessages(widget.deviceId, ids);
    if (!mounted) return;
    setState(() {
      _messages.removeWhere((m) => ids.contains(m.msgId));
      _selectedIds.clear();
    });
  }

  Future<void> _forwardSelected() async {
    final selected = _messages
        .where(
          (message) =>
              _selectedIds.contains(message.msgId) && !message.isControl,
        )
        .toList(growable: false);
    if (selected.isEmpty) return;
    final targets = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(
        builder: (_) => const ChatPickerScreen(title: 'Переслать в чат'),
      ),
    );
    if (!mounted || targets == null || targets.isEmpty) return;
    var sent = 0;
    var failed = 0;
    for (final target in targets) {
      // Local LAN and bookmark chats have their own message stores and cannot
      // be addressed through the account DM endpoint.
      if (target.startsWith('lan:') || target.startsWith('bm:')) continue;
      for (final message in selected) {
        try {
          final label = '↪ ${widget.displayName}';
          if (message.hasFile) {
            final caption = message.text.trim().isEmpty
                ? label
                : '$label\n${message.text.trim()}';
            await ChatRepo.instance.sendDmFile(
              toUsername: target,
              bytes: message.fileBytes!,
              mime: message.fileMime ?? 'application/octet-stream',
              fileName: message.fileName!,
              caption: caption,
            );
          } else if (message.text.trim().isNotEmpty) {
            await ChatRepo.instance.sendDmText(
              target,
              '$label\n${message.text.trim()}',
            );
          } else {
            continue;
          }
          sent++;
        } catch (error) {
          failed++;
          appLog.warn('lan', 'Forward from LAN chat failed: $error');
        }
      }
    }
    if (!mounted) return;
    setState(() => _selectedIds.clear());
    toast.show(
      sent > 0
          ? 'Переслано сообщений: $sent${failed > 0 ? ', ошибок: $failed' : ''}'
          : 'Не удалось переслать выбранные сообщения',
      level: failed > 0 && sent == 0 ? ToastLevel.error : ToastLevel.info,
    );
  }

  bool get _allSelectedPinned {
    final selected = _messages.where(
      (message) => _selectedIds.contains(message.msgId),
    );
    return selected.isNotEmpty && selected.every((message) => message.isPinned);
  }

  Future<void> _togglePinnedSelected() async {
    final selected = _messages
        .where((message) => _selectedIds.contains(message.msgId))
        .toList(growable: false);
    if (selected.isEmpty) return;
    final pin = selected.any((message) => !message.isPinned);
    for (final message in selected) {
      if (message.isPinned != pin) {
        await LanChatStore.instance.setMessagePinned(
          widget.deviceId,
          message.msgId,
          pin,
        );
      }
    }
    final messages = await LanChatStore.instance.getMessages(widget.deviceId);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(messages);
      _selectedIds.clear();
    });
    toast.show(
      pin ? 'Сообщение закреплено на этом устройстве' : 'Закрепление снято',
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    if (LanChatScreen.currentOpenDeviceId == widget.deviceId) {
      LanChatScreen.currentOpenDeviceId = null;
    }
    _msgSub?.cancel();
    _onlineSub?.cancel();
    _ackSub?.cancel();
    _seenSub?.cancel();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  IconData _barsIcon(int bars) {
    switch (bars) {
      case 0:
        return Icons.signal_cellular_0_bar;
      case 1:
        return Icons.signal_cellular_alt_1_bar;
      case 2:
        return Icons.signal_cellular_alt_2_bar;
      default:
        return Icons.signal_cellular_alt;
    }
  }

  @override
  Widget build(BuildContext context) {
    final online =
        localHub.isOnline(widget.deviceId) ||
        localHub.hasSession(widget.deviceId);
    final pingMs = localHub.getPingMs(widget.deviceId);
    final available = localHub.availableTransportsFor(widget.deviceId);
    final bars = localHub.signalBars(widget.deviceId);
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _selectionMode
            ? _selectionAppBar()
            : _normalAppBar(online, pingMs, available, bars),
        body: Column(
          children: [
            if (!online)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 6,
                  horizontal: 12,
                ),
                color: GE.yellow.withValues(alpha: 0.12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      // Разные формулировки: "уже было соединение и пропало"
                      // читается иначе, чем "с начала запуска ещё не
                      // подключались" — второе не обязательно означает
                      // проблему (например только что перезапустили телефон).
                      child: Text(
                        localHub.getPingMs(widget.deviceId) != null
                            ? 'Связь потеряна — сообщения не дойдут'
                            : 'Ещё не было соединения в этом запуске приложения',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: GE.yellow, fontSize: 11.5),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _pinging ? null : _manualPing,
                      child: Text(
                        _pinging ? 'Ищем…' : 'Попробовать',
                        style: TextStyle(
                          color: GE.yellow,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _messages.isEmpty
                  ? const EmptyChatState(
                      icon: CupertinoIcons.antenna_radiowaves_left_right,
                      title: 'Сообщений нет',
                      subtitle:
                          'Видно только вам двоим — сообщения идут напрямую, без сервера',
                    )
                  : Builder(
                      builder: (_) {
                        final bottomAnchor =
                            _messages.length <= _bottomAnchorMaxMsgs;
                        final list = ListView.builder(
                          shrinkWrap: bottomAnchor,
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.all(12),
                          itemCount: _messages.length,
                          itemBuilder: (_, i) => _bubble(_messages[i]),
                        );
                        return bottomAnchor
                            ? Align(
                                alignment: Alignment.bottomCenter,
                                child: list,
                              )
                            : list;
                      },
                    ),
            ),
            SafeArea(
              top: false,
              bottom: !_emojiOpen,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_replyTo != null || _editing != null) _replyBar(),
                  ChatComposer(
                    controller: _msgCtrl,
                    emojiOpen: _emojiOpen,
                    sending: _sending,
                    sendKey: _sendBtnKey,
                    hint: _editing != null
                        ? 'Изменить сообщение…'
                        : online
                        ? 'Сообщение…'
                        : 'Сообщение… (уйдёт при подключении)',
                    onAttach: _openAttachSheet,
                    onToggleEmoji: _toggleEmoji,
                    onSend: _send,
                    onFieldTap: () {
                      if (_emojiOpen) setState(() => _emojiOpen = false);
                    },
                  ),
                ],
              ),
            ),
            if (_emojiOpen)
              SizedBox(
                height: _emojiPanelH,
                child: EmojiPicker(onPick: _insertEmoji),
              ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _selectionAppBar() {
    return GlassAppBar(
      leading: IconButton(
        icon: Icon(CupertinoIcons.xmark, color: GE.text),
        onPressed: () => setState(() => _selectedIds.clear()),
      ),
      titleText: '${_selectedIds.length}',
      actions: [
        if (_selectedIds.length == 1)
          IconButton(
            icon: Icon(CupertinoIcons.reply, color: GE.primary),
            tooltip: 'Ответить',
            onPressed: _replyToSelected,
          ),
        if (_canEditSelected)
          IconButton(
            icon: Icon(CupertinoIcons.pencil, color: GE.primary),
            tooltip: 'Редактировать',
            onPressed: _editSelected,
          ),
        IconButton(
          icon: Icon(
            CupertinoIcons.arrowshape_turn_up_right,
            color: GE.primary,
          ),
          tooltip: 'Переслать',
          onPressed: _forwardSelected,
        ),
        IconButton(
          icon: Icon(
            _allSelectedPinned ? CupertinoIcons.pin_slash : CupertinoIcons.pin,
            color: GE.primary,
          ),
          tooltip: _allSelectedPinned ? 'Открепить' : 'Закрепить',
          onPressed: _togglePinnedSelected,
        ),
        IconButton(
          icon: Icon(CupertinoIcons.trash, color: GE.red),
          onPressed: _deleteSelected,
        ),
      ],
    );
  }

  PreferredSizeWidget _normalAppBar(
    bool online,
    int? pingMs,
    Set<TransportType>? available,
    int bars,
  ) {
    return GlassAppBar(
      showBack: true,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          MarqueeText(
            text: _name,
            style: TextStyle(
              color: GE.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          _pinging
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'соединение',
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                    const SizedBox(width: 3),
                    GlassDots(color: GE.sub),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _barsIcon(bars),
                      size: 12,
                      color: online ? GE.green : GE.sub,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      online
                          ? (pingMs != null ? 'в сети · $pingMs мс' : 'в сети')
                          : 'офлайн',
                      style: TextStyle(color: GE.sub, fontSize: 11),
                    ),
                    if (available != null && available.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      ...TransportType.values.map((t) {
                        final on = available.contains(t);
                        return Padding(
                          padding: const EdgeInsets.only(left: 2),
                          child: Icon(
                            switch (t) {
                              TransportType.lan => CupertinoIcons.wifi,
                              TransportType.wifiDirect =>
                                CupertinoIcons.antenna_radiowaves_left_right,
                              TransportType.bluetooth =>
                                CupertinoIcons.bluetooth,
                            },
                            size: 12,
                            color: on
                                ? GE.primary
                                : GE.sub.withValues(alpha: 0.35),
                          ),
                        );
                      }),
                    ],
                  ],
                ),
        ],
      ),
      actions: [
        IconButton(
          icon: _pinging
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: GE.sub,
                  ),
                )
              : Icon(
                  CupertinoIcons.antenna_radiowaves_left_right,
                  color: GE.sub,
                ),
          tooltip: 'Пинг / переподключиться',
          onPressed: _pinging ? null : _manualPing,
        ),
        IconButton(
          icon: Icon(CupertinoIcons.ellipsis_vertical, color: GE.sub),
          tooltip: 'Ещё',
          onPressed: _openChatMenu,
        ),
      ],
    );
  }

  // Как в обычном чате (chat_screen.dart._ticks), но без дискеты — у LAN нет
  // промежуточного "на сервере", только очередь/доставлено/прочитано.
  Widget _ticks(LanChatMessage m) {
    switch (m.status) {
      // Дискета = "лежит в локальной очереди, ждёт подключения" (пир офлайн,
      // таймаут отправки). У LAN нет сервера-посредника, поэтому это не
      // промежуточный шаг перед доставкой, а сам финальный смысл дискеты —
      // тут нет отдельного "часиков"-состояния.
      case LanMsgStatus.queued:
        return const Icon(
          CupertinoIcons.floppy_disk,
          size: 12,
          color: GE.muted,
        );
      case LanMsgStatus.delivered:
        return const Icon(
          CupertinoIcons.checkmark,
          size: 13,
          color: GE.sub,
        );
      case LanMsgStatus.read:
        return Icon(Icons.done_all, size: 14, color: GE.blue);
    }
  }

  // Долгое нажатие занято выбором сообщений (см. _toggleSelect) — реакция
  // вешается на двойной тап, чтобы не отбирать жест у уже настроенного
  // мультивыбора (тот же принцип, что и в ЛС/закладках, просто другой триггер).
  Future<void> _react(LanChatMessage m) async {
    final emoji = await showReactionPalette(context);
    if (emoji == null) return;
    await LanChatStore.instance.setReaction(widget.deviceId, m.msgId, emoji);
    final msgs = await LanChatStore.instance.getMessages(widget.deviceId);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(msgs);
    });
  }

  void _replyToSelected() {
    if (_selectedIds.length != 1) return;
    final id = _selectedIds.single;
    LanChatMessage? message;
    for (final item in _messages) {
      if (item.msgId == id) {
        message = item;
        break;
      }
    }
    if (message == null) return;
    setState(() {
      _editing = null;
      _replyTo = message;
      _selectedIds.clear();
      _msgCtrl.clear();
    });
  }

  bool get _canEditSelected {
    if (_selectedIds.length != 1) return false;
    final id = _selectedIds.single;
    for (final message in _messages) {
      if (message.msgId == id) {
        return message.fromMe && !message.hasFile && message.text.isNotEmpty;
      }
    }
    return false;
  }

  void _editSelected() {
    if (!_canEditSelected) return;
    final id = _selectedIds.single;
    LanChatMessage? message;
    for (final item in _messages) {
      if (item.msgId == id) {
        message = item;
        break;
      }
    }
    if (message == null) return;
    final selectedMessage = message;
    setState(() {
      _replyTo = null;
      _editing = selectedMessage;
      _selectedIds.clear();
      _msgCtrl.text = selectedMessage.text;
      _msgCtrl.selection = TextSelection.collapsed(
        offset: selectedMessage.text.length,
      );
    });
  }

  String _messagePreview(LanChatMessage message) {
    if (message.text.isNotEmpty) return message.text;
    if (message.fileName != null) return '📎 ${message.fileName}';
    return 'Сообщение';
  }

  Widget _replyBar() {
    final editing = _editing;
    final message = editing ?? _replyTo!;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: GE.glassFill,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: GE.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  editing == null ? 'Ответ' : 'Редактирование',
                  style: TextStyle(
                    color: GE.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _messagePreview(message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: GE.sub, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Отмена',
            onPressed: () => setState(() {
              _replyTo = null;
              _editing = null;
              _msgCtrl.clear();
            }),
            icon: Icon(CupertinoIcons.xmark, color: GE.sub, size: 17),
          ),
        ],
      ),
    );
  }

  Widget _bubble(LanChatMessage m) {
    final time = DateTime.fromMillisecondsSinceEpoch(m.createdAt * 1000);
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final selected = _selectedIds.contains(m.msgId);
    return GestureDetector(
      onLongPress: () => _toggleSelect(m.msgId),
      onDoubleTap: _selectionMode ? null : () => _react(m),
      onTap: _selectionMode ? () => _toggleSelect(m.msgId) : null,
      child: Container(
        color: selected
            ? GE.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        child: Align(
          alignment: m.fromMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: const BoxConstraints(maxWidth: 280),
            decoration: BoxDecoration(
              color: m.fromMe
                  ? GE.primary.withValues(alpha: 0.85)
                  : GE.glassFill,
              borderRadius: BorderRadius.circular(14),
              border: selected
                  ? Border.all(color: GE.primary, width: 1.4)
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (m.isPinned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CupertinoIcons.pin_fill,
                          color: m.fromMe ? GE.sub : GE.primary,
                          size: 11,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Закреплено на этом устройстве',
                          style: TextStyle(
                            color: m.fromMe ? GE.sub : GE.sub,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (m.replyPreview != null) ...[
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 5),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: (m.fromMe ? GE.text : GE.primary).withValues(
                        alpha: 0.14,
                      ),
                      borderRadius: BorderRadius.circular(7),
                      border: Border(
                        left: BorderSide(
                          color: m.fromMe ? GE.sub : GE.primary,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Text(
                      m.replyPreview!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: m.fromMe ? GE.sub : GE.sub,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
                if (m.hasFile)
                  InkWell(
                    onTap: _selectionMode ? null : () => _openLanFile(m),
                    child: _lanFilePreview(m),
                  ),
                if (m.text.isNotEmpty) ...[
                  if (m.hasFile) const SizedBox(height: 4),
                  EmojiText(
                    m.text,
                    style: TextStyle(
                      color: m.fromMe ? GE.text : GE.text,
                      fontSize: 14,
                    ),
                  ),
                ],
                if (m.reaction != null) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: (m.fromMe ? GE.text : GE.primary).withValues(
                        alpha: 0.18,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: EmojiText(
                      m.reaction!,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${m.editedAt == null ? '' : 'изменено · '}$hh:$mm',
                      style: TextStyle(
                        color: m.fromMe ? GE.sub : GE.sub,
                        fontSize: 10,
                      ),
                    ),
                    if (m.fromMe) ...[const SizedBox(width: 4), _ticks(m)],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _lanFilePreview(LanChatMessage m) {
    final mime = m.fileMime ?? '';
    if (mime.startsWith('image/') && m.fileBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Image.memory(
          m.fileBytes!,
          width: 220,
          height: 165,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }
    if (mime.startsWith('video/')) {
      return Container(
        width: 220,
        height: 130,
        decoration: BoxDecoration(
          color: GE.scrimFaint,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              CupertinoIcons.play_circle_fill,
              color: m.fromMe ? GE.text : GE.primary,
              size: 44,
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 7,
              child: Text(
                m.fileName ?? 'Видео',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: m.fromMe ? GE.text : GE.text,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          CupertinoIcons.doc,
          color: m.fromMe ? GE.text : GE.text,
          size: 18,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            m.fileName ?? 'Файл',
            style: TextStyle(
              color: m.fromMe ? GE.text : GE.text,
              fontSize: 13,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ],
    );
  }
}
