import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Builds a short authentication string from both WebRTC DTLS certificates.
/// The result is identical on both endpoints and changes if a MITM creates
/// separate DTLS connections to each participant.
class CallVerificationCode {
  static const _emojis = <String>[
    '😀',
    '😃',
    '😄',
    '😁',
    '😆',
    '😅',
    '😂',
    '🙂',
    '🙃',
    '😉',
    '😊',
    '😇',
    '🥰',
    '😍',
    '🤩',
    '😎',
    '🐶',
    '🐱',
    '🐭',
    '🐹',
    '🐰',
    '🦊',
    '🐻',
    '🐼',
    '🐨',
    '🐯',
    '🦁',
    '🐮',
    '🐸',
    '🐵',
    '🐧',
    '🐦',
    '🍎',
    '🍐',
    '🍊',
    '🍋',
    '🍌',
    '🍉',
    '🍇',
    '🍓',
    '🫐',
    '🍒',
    '🍑',
    '🥭',
    '🍍',
    '🥥',
    '🥝',
    '🍅',
    '⚽',
    '🏀',
    '🏈',
    '⚾',
    '🎾',
    '🏐',
    '🎱',
    '🪁',
    '🎈',
    '🎉',
    '🎵',
    '🎸',
    '🎹',
    '🎺',
    '🚀',
    '⭐',
  ];

  static final _fingerprintPattern = RegExp(
    r'^a=fingerprint:sha-256[ \t]+([0-9a-f:]+)[ \t]*\r?$',
    multiLine: true,
    caseSensitive: false,
  );

  static Future<List<String>> fromDescriptions({
    required String localSdp,
    required String remoteSdp,
  }) async {
    final fingerprints = {
      ..._fingerprints(localSdp),
      ..._fingerprints(remoteSdp),
    }.toList()..sort();

    // A valid two-party call should expose one SHA-256 DTLS fingerprint from
    // each endpoint. Hide the code rather than show an untrustworthy value.
    if (fingerprints.length < 2) return const [];

    final input = utf8.encode(
      'ghost-calls-emoji-check-v1|${fingerprints.join('|')}',
    );
    final digest = await Sha256().hash(input);
    return List<String>.unmodifiable(
      digest.bytes.take(5).map((byte) => _emojis[byte & 0x3f]),
    );
  }

  static Set<String> _fingerprints(String sdp) => _fingerprintPattern
      .allMatches(sdp)
      .map((match) => match.group(1)!.replaceAll(':', '').toLowerCase())
      .where((value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value))
      .toSet();
}
