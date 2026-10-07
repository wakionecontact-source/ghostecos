// Общий декодер входящих LAN/BLE/Wi-Fi-Direct сообщений — расшифровка +
// разбор конверта {"t":"txt","v":...} / {"t":"file","n":...,"m":...,"d":...}.
// ЕДИНАЯ точка входа, чтобы не дублировать логику между MainShell (глобальный
// обработчик, пишет в LanChatStore всегда) и LanChatScreen (когда открыт) —
// раньше decrypt+parse дублировался в обоих местах, и при одновременном
// срабатывании возникала гонка за один и тот же msg_id в БД.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import '../../services/crypto_v2.dart';
import 'local_transport.dart';

// ── base64/JSON файловых вложений в отдельном изоляте ──
// Файл по LAN/BLE/Wi-Fi-Direct едет как base64 внутри JSON-конверта. Для
// многомегабайтных файлов base64Encode/Decode + jsonEncode — заметная работа на
// UI-потоке; гоним её через compute(), чтобы не ронять кадры при отправке/приёме
// вложения (crypto уже уходит в изолят внутри CryptoV2).
class _FileEnvelopeArgs {
  final String fileName;
  final String fileMime;
  final Uint8List fileBytes;
  final String? replyPreview;
  const _FileEnvelopeArgs(
    this.fileName,
    this.fileMime,
    this.fileBytes,
    this.replyPreview,
  );
}

String _buildFileEnvelope(_FileEnvelopeArgs a) => jsonEncode({
  't': 'file',
  'n': a.fileName,
  'm': a.fileMime,
  'd': base64Encode(a.fileBytes),
  if (a.replyPreview != null) 'rp': a.replyPreview,
});

class DecodedLanMessage {
  final String text;
  final String? fileName;
  final String? fileMime;
  final Uint8List? fileBytes;
  final String? replyPreview;
  const DecodedLanMessage({
    this.text = '',
    this.fileName,
    this.fileMime,
    this.fileBytes,
    this.replyPreview,
  });
}

Future<DecodedLanMessage?> decodeLanMessage(LocalMessageEvent m) async {
  if (m.encB64.isEmpty) return null;
  final clear = await CryptoV2.instance.decryptForMe(m.encB64);
  if (clear == null) return null;
  final raw = utf8.decode(clear);
  try {
    final env = jsonDecode(raw) as Map<String, dynamic>;
    final t = env['t'] as String?;
    if (t == 'file') {
      final dataB64 = env['d'] as String?;
      final fileBytes = dataB64 != null
          ? await compute(base64Decode, dataB64)
          : null;
      return DecodedLanMessage(
        fileName: env['n'] as String?,
        fileMime: (env['m'] as String?)?.isEmpty == true
            ? null
            : env['m'] as String?,
        fileBytes: fileBytes,
        replyPreview: env['rp'] as String?,
      );
    }
    return DecodedLanMessage(
      text: env['v'] as String? ?? '',
      replyPreview: env['rp'] as String?,
    );
  } catch (_) {
    return DecodedLanMessage(
      text: raw,
    ); // старый формат без конверта — совместимость
  }
}

/// Обратная сторона decodeLanMessage — шифрует текст/файл под известный
/// pubkey пира в тот же формат конверта. Общая точка для LanChatScreen
/// (обычная отправка) и очереди офлайн-сообщений (см. MainShell), чтобы не
/// дублировать сборку конверта в двух местах.
Future<String> encodeLanEnvelope({
  required String peerPubB64,
  String text = '',
  String? fileName,
  String? fileMime,
  Uint8List? fileBytes,
  String? replyPreview,
}) async {
  final envelope = fileBytes != null && fileName != null
      ? await compute(
          _buildFileEnvelope,
          _FileEnvelopeArgs(fileName, fileMime ?? '', fileBytes, replyPreview),
        )
      : jsonEncode({
          't': 'txt',
          'v': text,
          if (replyPreview != null) 'rp': replyPreview,
        });
  return CryptoV2.instance.encryptV2(
    base64Decode(peerPubB64),
    utf8.encode(envelope),
  );
}
