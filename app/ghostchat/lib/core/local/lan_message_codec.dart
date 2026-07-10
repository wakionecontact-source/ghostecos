// Общий декодер входящих LAN/BLE/Wi-Fi-Direct сообщений — расшифровка +
// разбор конверта {"t":"txt","v":...} / {"t":"file","n":...,"m":...,"d":...}.
// ЕДИНАЯ точка входа, чтобы не дублировать логику между MainShell (глобальный
// обработчик, пишет в LanChatStore всегда) и LanChatScreen (когда открыт) —
// раньше decrypt+parse дублировался в обоих местах, и при одновременном
// срабатывании возникала гонка за один и тот же msg_id в БД.
import 'dart:convert';
import 'dart:typed_data';
import '../../services/crypto_v2.dart';
import 'local_transport.dart';

class DecodedLanMessage {
  final String text;
  final String? fileName;
  final String? fileMime;
  final Uint8List? fileBytes;
  const DecodedLanMessage({this.text = '', this.fileName, this.fileMime, this.fileBytes});
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
      return DecodedLanMessage(
        fileName: env['n'] as String?,
        fileMime: (env['m'] as String?)?.isEmpty == true ? null : env['m'] as String?,
        fileBytes: dataB64 != null ? base64Decode(dataB64) : null,
      );
    }
    return DecodedLanMessage(text: env['v'] as String? ?? '');
  } catch (_) {
    return DecodedLanMessage(text: raw); // старый формат без конверта — совместимость
  }
}
