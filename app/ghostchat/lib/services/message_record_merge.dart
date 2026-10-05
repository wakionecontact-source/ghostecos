/// Keeps local delivery/read acknowledgements when a server history replay
/// upserts the same message without receipt metadata.
Map<String, Object?> mergePersistedReceiptFlags({
  required Map<String, Object?> incoming,
  Map<String, Object?>? existing,
}) {
  final merged = Map<String, Object?>.of(incoming);
  if (existing == null) return merged;

  for (final field in const ['delivered', 'read']) {
    merged[field] = _isSet(existing[field]) || _isSet(incoming[field]) ? 1 : 0;
  }
  return merged;
}

bool _isSet(Object? value) => value == true || value == 1;
