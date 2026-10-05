/// Bot DMs are plain text, not E2E envelopes. An incomplete real-time event
/// should be replayed from durable history instead of shown as a decrypt error.
bool shouldDeferKnownBotMessage({
  required bool isKnownBot,
  required String? plainText,
}) => isKnownBot && plainText == null;

/// A bot reply normally arrives over chat.new. These bounded delays are only a
/// catch-up path for a missed realtime event; they stay well below the server's
/// per-user /pending rate limit and stop as soon as a reply is visible locally.
const botReplyCatchUpDelays = <Duration>[
  Duration(milliseconds: 500),
  Duration(milliseconds: 1500),
  Duration(milliseconds: 3500),
  Duration(milliseconds: 6000),
];

Future<void> catchUpBotReply({
  required Future<void> Function() fetchPending,
  required Future<bool> Function() hasReply,
  required bool Function() isCurrentSession,
  Future<void> Function(Duration delay)? wait,
}) async {
  final waitFor = wait ?? (delay) => Future<void>.delayed(delay);
  for (final delay in botReplyCatchUpDelays) {
    if (!isCurrentSession()) return;
    await waitFor(delay);
    if (!isCurrentSession()) return;
    if (await hasReply()) return;
    await fetchPending();
    if (!isCurrentSession() || await hasReply()) return;
  }
}
