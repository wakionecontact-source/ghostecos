// LanChatScreen — переписка с устройством поблизости (LAN/BLE/Wi-Fi Direct).
// Текст + файлы (лучше всего работает по LAN — TCP; BLE/Wi-Fi Direct без
// chunking на нативной стороне periферии, крупные файлы могут не дойти —
// см. комментарий в bluetooth_transport.dart). Работает, только пока пир
// реально на связи прямо сейчас — доставка не гарантируется офлайн-пиру.
// История хранится в LanChatStore — привязана к устройству, не к аккаунту.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../services/lan_chat_store.dart';
import '../services/crypto_v2.dart';
import '../core/local/local_hub.dart';
import '../core/local/local_transport.dart';

const _maxLanFileBytes = 10 * 1024 * 1024; // 10MB — best-effort P2P, без прогресс-бара

class LanChatScreen extends StatefulWidget {
  final String deviceId;
  final String displayName;
  const LanChatScreen({
    super.key,
    required this.deviceId,
    required this.displayName,
  });

  @override
  State<LanChatScreen> createState() => _LanChatScreenState();
}

class _LanChatScreenState extends State<LanChatScreen> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<LanChatMessage> _messages = [];
  final Set<String> _seenMsgIds = {};
  final Set<String> _selectedIds = {};
  StreamSubscription? _msgSub;
  Timer? _onlineTimer;
  bool _sending = false;
  late String _name;

  bool get _selectionMode => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _name = widget.displayName;
    _load();
    _msgSub = localHub.onMessage.listen(_onIncoming);
    // isOnline() опирается на keepalive-таймеры — обновляем индикатор тиком,
    // не отдельным стримом (в LocalHub его для UI сейчас нет).
    _onlineTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() {});
    });
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
  }

  // ВАЖНО: расшифровку и запись в БД делает ТОЛЬКО глобальный обработчик в
  // MainShell (_onLanMessage) — здесь просто ждём, пока он это сделает, и
  // дочитываем результат из LanChatStore. Если бы этот экран тоже сам
  // расшифровывал и писал в БД, при одновременном срабатывании обоих
  // листенеров возникала бы гонка за один и тот же msg_id (кто первый
  // вставит — тот и победит, включая потенциально "сырую" версию до фикса).
  void _onIncoming(LocalMessageEvent m) {
    if (m.fromUsername != widget.deviceId) return;
    _reloadNewMessages();
  }

  Future<void> _reloadNewMessages() async {
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    final msgs = await LanChatStore.instance.getMessages(widget.deviceId);
    final fresh = msgs.where((m) => !_seenMsgIds.contains(m.msgId)).toList();
    if (fresh.isEmpty) return;
    await LanChatStore.instance.markRead(widget.deviceId);
    if (!mounted) return;
    setState(() {
      _seenMsgIds.addAll(fresh.map((m) => m.msgId));
      _messages.addAll(fresh);
    });
    _scrollToBottom();
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    if (!localHub.hasSession(widget.deviceId)) return; // офлайн — кнопка и так скрыта

    setState(() => _sending = true);
    try {
      final peerPubB64 = await LanChatStore.instance.getPeerPub(widget.deviceId);
      if (peerPubB64 == null) throw StateError('Нет ключа собеседника');

      final msgId = const Uuid().v4();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final envelope = jsonEncode({'t': 'txt', 'v': text});
      final encB64 = await CryptoV2.instance.encryptV2(
        base64Decode(peerPubB64),
        utf8.encode(envelope),
      );
      await localHub.sendMessage(widget.deviceId, msgId, encB64, nowMs);
      await LanChatStore.instance.addMessage(
        deviceId: widget.deviceId,
        msgId: msgId,
        fromMe: true,
        text: text,
        createdAtSec: nowMs ~/ 1000,
      );
      if (!mounted) return;
      _seenMsgIds.add(msgId);
      setState(() {
        _messages.add(LanChatMessage(
          msgId: msgId,
          deviceId: widget.deviceId,
          fromMe: true,
          text: text,
          createdAt: nowMs ~/ 1000,
        ));
        _msgCtrl.clear();
      });
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attachFile() async {
    if (!localHub.hasSession(widget.deviceId)) return;
    final file = await openFile();
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length > _maxLanFileBytes) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Файл больше 10MB — P2P-канал не резиновый')),
        );
        return;
      }
      final peerPubB64 = await LanChatStore.instance.getPeerPub(widget.deviceId);
      if (peerPubB64 == null) throw StateError('Нет ключа собеседника');

      final msgId = const Uuid().v4();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final envelope = jsonEncode({
        't': 'file',
        'n': file.name,
        'm': file.mimeType ?? '',
        'd': base64Encode(bytes),
      });
      final encB64 = await CryptoV2.instance.encryptV2(
        base64Decode(peerPubB64),
        utf8.encode(envelope),
      );
      await localHub.sendMessage(widget.deviceId, msgId, encB64, nowMs);
      await LanChatStore.instance.addMessage(
        deviceId: widget.deviceId,
        msgId: msgId,
        fromMe: true,
        createdAtSec: nowMs ~/ 1000,
        fileName: file.name,
        fileMime: file.mimeType,
        fileBytes: bytes,
      );
      if (!mounted) return;
      _seenMsgIds.add(msgId);
      setState(() {
        _messages.add(LanChatMessage(
          msgId: msgId,
          deviceId: widget.deviceId,
          fromMe: true,
          text: '',
          createdAt: nowMs ~/ 1000,
          fileName: file.name,
          fileMime: file.mimeType,
          fileBytes: bytes,
        ));
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить файл: $e')),
      );
    }
  }

  Future<void> _openLanFile(LanChatMessage m) async {
    if (!m.hasFile) return;
    try {
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path, m.fileName!);
      final f = File(path);
      await f.writeAsBytes(m.fileBytes!, flush: true);
      await OpenFilex.open(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось открыть файл: $e')),
      );
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
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

  Future<void> _manualPing() async {
    await localHub.pingNow(widget.deviceId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Пинг отправлен'), duration: Duration(seconds: 1)),
    );
  }

  void _toggleSelect(String msgId) {
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
    await LanChatStore.instance.deleteMessages(widget.deviceId, ids);
    if (!mounted) return;
    setState(() {
      _messages.removeWhere((m) => ids.contains(m.msgId));
      _selectedIds.clear();
    });
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
    _msgSub?.cancel();
    _onlineTimer?.cancel();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  IconData _barsIcon(int bars) {
    switch (bars) {
      case 0: return Icons.signal_cellular_0_bar;
      case 1: return Icons.signal_cellular_alt_1_bar;
      case 2: return Icons.signal_cellular_alt_2_bar;
      default: return Icons.signal_cellular_alt;
    }
  }

  @override
  Widget build(BuildContext context) {
    final online = localHub.isOnline(widget.deviceId) ||
        localHub.hasSession(widget.deviceId);
    final pingMs = localHub.getPingMs(widget.deviceId);
    final available = localHub.availableTransportsFor(widget.deviceId);
    final bars = localHub.signalBars(widget.deviceId);
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: _selectionMode ? _selectionAppBar() : _normalAppBar(online, pingMs, available, bars),
        body: Column(
          children: [
            if (!online)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 6),
                color: GE.yellow.withValues(alpha: 0.12),
                child: Text(
                  'Устройство сейчас не на связи — сообщения не дойдут',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GE.yellow, fontSize: 11.5),
                ),
              ),
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Text(
                        'Начните переписку — сообщения видны только вам двоим',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: GE.sub, fontSize: 12.5),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.all(12),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) => _bubble(_messages[i]),
                    ),
            ),
            _inputRow(online),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _selectionAppBar() {
    return GlassAppBar(
      leading: IconButton(
        icon: Icon(Icons.close, color: GE.text),
        onPressed: () => setState(() => _selectedIds.clear()),
      ),
      titleText: '${_selectedIds.length}',
      actions: [
        IconButton(
          icon: Icon(Icons.delete_outline, color: GE.red),
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
          Text(_name,
              style: TextStyle(color: GE.text, fontSize: 16, fontWeight: FontWeight.w700)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_barsIcon(bars), size: 12, color: online ? GE.green : GE.sub),
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
                        TransportType.lan => Icons.wifi,
                        TransportType.wifiDirect => Icons.wifi_tethering,
                        TransportType.bluetooth => Icons.bluetooth,
                      },
                      size: 12,
                      color: on ? GE.primary : GE.sub.withValues(alpha: 0.35),
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
          icon: Icon(Icons.wifi_tethering, color: GE.sub),
          tooltip: 'Пинг сейчас',
          onPressed: online ? _manualPing : null,
        ),
        IconButton(
          icon: Icon(Icons.edit_outlined, color: GE.sub),
          tooltip: 'Переименовать',
          onPressed: _rename,
        ),
      ],
    );
  }

  Widget _bubble(LanChatMessage m) {
    final time = DateTime.fromMillisecondsSinceEpoch(m.createdAt * 1000);
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final selected = _selectedIds.contains(m.msgId);
    return GestureDetector(
      onLongPress: () => _toggleSelect(m.msgId),
      onTap: _selectionMode ? () => _toggleSelect(m.msgId) : null,
      child: Container(
        color: selected ? GE.primary.withValues(alpha: 0.10) : Colors.transparent,
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
              border: selected ? Border.all(color: GE.primary, width: 1.4) : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (m.hasFile)
                  InkWell(
                    onTap: _selectionMode ? null : () => _openLanFile(m),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.insert_drive_file_outlined,
                            color: m.fromMe ? Colors.white : GE.text, size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(m.fileName!,
                              style: TextStyle(
                                color: m.fromMe ? Colors.white : GE.text,
                                fontSize: 13,
                                decoration: TextDecoration.underline,
                              )),
                        ),
                      ],
                    ),
                  ),
                if (m.text.isNotEmpty) ...[
                  if (m.hasFile) const SizedBox(height: 4),
                  Text(m.text, style: TextStyle(color: m.fromMe ? Colors.white : GE.text, fontSize: 14)),
                ],
                const SizedBox(height: 2),
                Text('$hh:$mm',
                    style: TextStyle(
                        color: m.fromMe ? Colors.white70 : GE.sub, fontSize: 10)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _inputRow(bool online) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.attach_file, color: online ? GE.sub : GE.sub.withValues(alpha: 0.4)),
            onPressed: online ? _attachFile : null,
          ),
          Expanded(
            child: GlassInput(
              controller: _msgCtrl,
              hint: online ? 'Сообщение…' : 'Устройство офлайн',
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.send_rounded, color: online ? GE.primary : GE.sub),
            onPressed: online ? _send : null,
          ),
        ],
      ),
    );
  }
}
