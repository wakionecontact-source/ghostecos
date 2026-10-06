import 'dart:async';
import 'dart:collection';

/// Log entry with timestamp, category, and message
class LogEntry {
  /// Monotonic in-memory id used to jump from an error panel to this exact
  /// entry in LogsScreen. It is optional for compatibility with old tests and
  /// callers that construct LogEntry directly.
  final int id;
  final DateTime time;
  final String category; // lan, bt, wifi_direct, etc.
  final String level; // info, warn, error, debug
  final String message;

  const LogEntry({
    this.id = 0,
    required this.time,
    required this.category,
    required this.level,
    required this.message,
  });

  String get timeStr {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  /// Full-fidelity line used when a user exports the log.
  String get exportLine =>
      '${time.toIso8601String()} [$category] [$level] $message';
}

/// Applies the category selected in LogsScreen to an export snapshot.
///
/// The `all` filter intentionally keeps every level, including debug entries,
/// so exporting the whole log really exports the whole in-memory journal.
List<LogEntry> filterLogEntries(Iterable<LogEntry> entries, String category) {
  final snapshot = entries.toList(growable: false);
  if (category == 'all') return snapshot;
  return snapshot.where((entry) => entry.category == category).toList();
}

/// Serializes log entries as UTF-8-friendly plain text.
String formatLogEntries(Iterable<LogEntry> entries) {
  final lines = entries.map((entry) => entry.exportLine).toList();
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}

/// Global app logger — keeps last N entries in memory, streams to UI
class AppLogger {
  static final AppLogger _i = AppLogger._();
  factory AppLogger() => _i;
  AppLogger._();

  static const int maxEntries = 2000;

  final _entries = Queue<LogEntry>();
  final _ctrl = StreamController<LogEntry>.broadcast();
  int _nextId = 0;
  bool _protectedContext = false;
  Set<String> _sensitiveValues = {};

  Stream<LogEntry> get onLog => _ctrl.stream;
  List<LogEntry> get entries => _entries.toList();

  /// Keep events raised inside protected environments out of the ordinary
  /// app log. A dedicated protected journal can opt into a separate sink.
  set protectedContext(bool value) => _protectedContext = value;

  /// Remove protected chat identifiers from ordinary log history and filter
  /// future entries that mention them.
  set sensitiveValues(Iterable<String> values) {
    _sensitiveValues = values
        .map((value) => value.trim())
        .where((value) => value.length >= 3)
        .expand((value) {
          final parts = <String>{value, Uri.encodeComponent(value)};
          final suffix = value.split(':').last;
          if (suffix.length >= 3) parts.add(suffix);
          return parts;
        })
        .toSet();
    _entries.removeWhere((entry) => _containsSensitiveValue(entry.message));
  }

  bool _containsSensitiveValue(String message) {
    for (final value in _sensitiveValues) {
      final pattern = RegExp(
        '(^|[^A-Za-z0-9_])${RegExp.escape(value)}([^A-Za-z0-9_]|\$)',
        caseSensitive: false,
      );
      if (pattern.hasMatch(message)) return true;
    }
    return false;
  }

  LogEntry log(String category, String message, {String level = 'info'}) {
    final entry = LogEntry(
      id: ++_nextId,
      time: DateTime.now(),
      category: category,
      level: level,
      message: message,
    );
    if (!_protectedContext && !_containsSensitiveValue(message)) {
      _entries.addLast(entry);
      while (_entries.length > maxEntries) {
        _entries.removeFirst();
      }
      _ctrl.add(entry);
    }
    return entry;
  }

  LogEntry info(String category, String message) =>
      log(category, message, level: 'info');
  LogEntry warn(String category, String message) =>
      log(category, message, level: 'warn');
  LogEntry error(String category, String message) =>
      log(category, message, level: 'error');
  LogEntry debug(String category, String message) =>
      log(category, message, level: 'debug');

  void clear() => _entries.clear();
}

final appLog = AppLogger();
