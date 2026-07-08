import 'dart:async';
import 'dart:collection';

/// Log entry with timestamp, category, and message
class LogEntry {
  final DateTime time;
  final String category; // lan, bt, wifi_direct, etc.
  final String level;    // info, warn, error, debug
  final String message;

  const LogEntry({
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
}

/// Global app logger — keeps last N entries in memory, streams to UI
class AppLogger {
  static final AppLogger _i = AppLogger._();
  factory AppLogger() => _i;
  AppLogger._();

  static const int maxEntries = 2000;

  final _entries = Queue<LogEntry>();
  final _ctrl = StreamController<LogEntry>.broadcast();

  Stream<LogEntry> get onLog => _ctrl.stream;
  List<LogEntry> get entries => _entries.toList();

  void log(String category, String message, {String level = 'info'}) {
    final entry = LogEntry(
      time: DateTime.now(),
      category: category,
      level: level,
      message: message,
    );
    _entries.addLast(entry);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    _ctrl.add(entry);
  }

  void info(String category, String message) => log(category, message, level: 'info');
  void warn(String category, String message) => log(category, message, level: 'warn');
  void error(String category, String message) => log(category, message, level: 'error');
  void debug(String category, String message) => log(category, message, level: 'debug');

  void clear() => _entries.clear();
}

final appLog = AppLogger();
