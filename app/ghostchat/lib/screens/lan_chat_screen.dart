// LanChatScreen — переписка с устройством поблизости (LAN/BLE/Wi-Fi Direct).
// Текст-only (транспорт пока не умеет файлы) и работает, только пока пир
// реально на связи прямо сейчас — доставка не гарантируется офлайн-пиру.
// История хранится в LanChatStore — привязана к устройству, не к аккаунту.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../services/lan_chat_store.dart';
import '../services/crypto_v2.dart';
import '../core/local/local_hub.dart';
import '../core/local/local_transport.dart';

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
  StreamSubscription? _msgSub;
  Timer? _onlineTimer;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
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

  void _onIncoming(LocalMessageEvent m) {
    if (m.fromUsername != widget.deviceId || m.encB64.isEmpty) return;
    _decryptAndAppend(m);
  }

  Future<void> _decryptAndAppend(LocalMessageEvent m) async {
    if (_seenMsgIds.contains(m.msgId)) return;
    try {
      final clear = await CryptoV2.instance.decryptForMe(m.encB64);
      if (clear == null) return;
      final text = utf8.decode(clear);
      final createdAtSec = m.sentAt > 0 ? m.sentAt ~/ 1000 : null;
      await LanChatStore.instance.addMessage(
        deviceId: widget.deviceId,
        msgId: m.msgId,
        fromMe: false,
        text: text,
        createdAtSec: createdAtSec,
      );
      await LanChatStore.instance.markRead(widget.deviceId);
      if (!mounted) return;
      _seenMsgIds.add(m.msgId);
      setState(() {
        _messages.add(LanChatMessage(
          msgId: m.msgId,
          deviceId: widget.deviceId,
          fromMe: false,
          text: text,
          createdAt: createdAtSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ));
      });
      _scrollToBottom();
    } catch (_) {}
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
      final encB64 = await CryptoV2.instance.encryptV2(
        base64Decode(peerPubB64),
        utf8.encode(text),
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

  @override
  Widget build(BuildContext context) {
    final online = localHub.isOnline(widget.deviceId) ||
        localHub.hasSession(widget.deviceId);
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          showBack: true,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.displayName,
                  style: TextStyle(color: GE.text, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: online ? GE.green : GE.sub,
                ),
              ),
            ],
          ),
        ),
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

  Widget _bubble(LanChatMessage m) {
    final time = DateTime.fromMillisecondsSinceEpoch(m.createdAt * 1000);
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return Align(
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
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(m.text, style: TextStyle(color: m.fromMe ? Colors.white : GE.text, fontSize: 14)),
            const SizedBox(height: 2),
            Text('$hh:$mm',
                style: TextStyle(
                    color: m.fromMe ? Colors.white70 : GE.sub, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _inputRow(bool online) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
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
