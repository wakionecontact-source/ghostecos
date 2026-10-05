enum CallCollisionDecision { keepOutgoing, acceptIncoming }

CallCollisionDecision resolveCallCollision({
  required String localUsername,
  required String remoteUsername,
  required String localCallId,
  required String incomingCallId,
}) {
  final localName = localUsername.trim().toLowerCase();
  final remoteName = remoteUsername.trim().toLowerCase();
  final nameOrder = localName.compareTo(remoteName);
  final winnerOrder = nameOrder == 0
      ? localCallId.compareTo(incomingCallId)
      : nameOrder;

  // Both devices compare the same two offer identities, so exactly one keeps
  // its outgoing offer and the other accepts it.
  return winnerOrder <= 0
      ? CallCollisionDecision.keepOutgoing
      : CallCollisionDecision.acceptIncoming;
}
