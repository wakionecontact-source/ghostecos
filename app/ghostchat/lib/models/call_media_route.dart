enum CallMediaRoute { unknown, direct, turnRelay }

CallMediaRoute resolveCallMediaRouteFromStats(
  Iterable<Map<String, dynamic>> reports,
) {
  final reportsById = <String, Map<String, dynamic>>{};
  final reportList = reports.toList(growable: false);
  for (final report in reportList) {
    final id = report['id'];
    if (id is String) reportsById[id] = report;
  }

  Map<String, dynamic>? selectedPair;
  var hasSelectedPairId = false;
  for (final report in reportList.where(
    (report) => _typeOf(report) == 'transport',
  )) {
    final selectedPairId = _stringValue(
      _valuesOf(report),
      'selectedCandidatePairId',
    );
    if (selectedPairId == null || selectedPairId.isEmpty) continue;
    hasSelectedPairId = true;
    selectedPair = reportsById[selectedPairId];
    break;
  }

  if (hasSelectedPairId && selectedPair == null) {
    return CallMediaRoute.unknown;
  }

  final pairs = reportList.where(
    (report) => _typeOf(report) == 'candidate-pair',
  );
  selectedPair ??= _firstWhereOrNull(
    pairs,
    (report) => _boolValue(_valuesOf(report), 'selected') == true,
  );
  selectedPair ??= _firstWhereOrNull(pairs, (report) {
    final values = _valuesOf(report);
    return _stringValue(values, 'state')?.toLowerCase() == 'succeeded' &&
        _boolValue(values, 'nominated') == true;
  });
  if (selectedPair == null) return CallMediaRoute.unknown;

  final pairValues = _valuesOf(selectedPair);
  final localId = _stringValue(pairValues, 'localCandidateId');
  final remoteId = _stringValue(pairValues, 'remoteCandidateId');
  if (localId == null || remoteId == null) return CallMediaRoute.unknown;

  final localType = _candidateType(reportsById[localId]);
  final remoteType = _candidateType(reportsById[remoteId]);
  if (localType == 'relay' || remoteType == 'relay') {
    return CallMediaRoute.turnRelay;
  }
  if (localType != null && remoteType != null) return CallMediaRoute.direct;
  return CallMediaRoute.unknown;
}

String? _candidateType(Map<String, dynamic>? report) {
  if (report == null ||
      (_typeOf(report) != 'local-candidate' &&
          _typeOf(report) != 'remote-candidate')) {
    return null;
  }
  return _stringValue(_valuesOf(report), 'candidateType')?.toLowerCase();
}

String _typeOf(Map<String, dynamic> report) =>
    (report['type'] as String? ?? '').toLowerCase();

Map<dynamic, dynamic> _valuesOf(Map<String, dynamic> report) {
  final values = report['values'];
  return values is Map ? values : const <dynamic, dynamic>{};
}

String? _stringValue(Map<dynamic, dynamic> values, String key) {
  final normalizedKey = _normalize(key);
  for (final entry in values.entries) {
    if (_normalize(entry.key.toString()) == normalizedKey) {
      final value = entry.value;
      if (value is String) return value;
    }
  }
  return null;
}

bool? _boolValue(Map<dynamic, dynamic> values, String key) {
  final normalizedKey = _normalize(key);
  for (final entry in values.entries) {
    if (_normalize(entry.key.toString()) == normalizedKey) {
      final value = entry.value;
      if (value is bool) return value;
      if (value is String) return value.toLowerCase() == 'true';
    }
  }
  return null;
}

String _normalize(String value) =>
    value.replaceAll(RegExp(r'[_-]'), '').toLowerCase();

T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T) test) {
  for (final value in values) {
    if (test(value)) return value;
  }
  return null;
}
