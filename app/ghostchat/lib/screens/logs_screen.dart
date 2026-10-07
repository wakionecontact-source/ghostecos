// LogsScreen — просмотр внутренних логов (перенесено из 1.19.3, дизайн Ghost).
// В экран попадают события приложения, API/WS, чатов, БД, криптографии,
// хранилища, локальных транспортов и необработанных Flutter/runtime-ошибок.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';
import '../core/local/app_logger.dart';
import '../services/app_security_store.dart';

class LogsScreen extends StatefulWidget {
  final int? focusLogId;

  const LogsScreen({super.key, this.focusLogId});
  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  bool _closingForScopeChange = false;
  String? _scopeIdAtOpen;
  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  StreamSubscription<LogEntry>? _sub;
  StreamSubscription<void>? _privacySub;
  List<LogEntry> _logs = [];
  String _filter = 'all';
  String _searchQuery = '';
  DateTime? _fromTime;
  DateTime? _toTime;
  bool _autoScroll = true;
  bool _showDebug = false;
  bool _isExporting = false;
  final _logKeys = <int, GlobalKey>{};
  Timer? _highlightTimer;
  int _focusRevealAttempts = 0;
  int? _highlightedLogId;

  static const _logChannel = MethodChannel('ghostchat/logs');

  // Категории из старого логгера 1.19.3 плюс новые каналы API/runtime.
  // Динамические категории всё равно добавляются ниже, поэтому журнал не
  // потребует правки экрана при появлении нового транспорта или сервиса.
  static const _baseCategories = [
    'all',
    'app',
    'auth',
    'api',
    'ws',
    'chat',
    'msg',
    'file',
    'presence',
    'channel',
    'db',
    'crypto',
    'storage',
    'security',
    'ui',
    'settings',
    'notify',
    'permissions',
    'search',
    'bot',
    'support',
    'dictaphone',
    'flutter',
    'runtime',
    'lan',
    'bt',
    'wifi_direct',
  ];

  List<String> get _categories {
    final seenCategories = _logs
        .map((e) => e.category)
        .where((c) => c.isNotEmpty)
        .toSet();
    return [
      ..._baseCategories,
      ...seenCategories.where((c) => !_baseCategories.contains(c)),
    ]..sort((a, b) {
      final ai = _baseCategories.indexOf(a);
      final bi = _baseCategories.indexOf(b);
      if (ai >= 0 && bi >= 0) return ai.compareTo(bi);
      if (ai >= 0) return -1;
      if (bi >= 0) return 1;
      return a.compareTo(b);
    });
  }

  @override
  void initState() {
    super.initState();
    AppSecurityStore.instance.revision.addListener(_onSecurityChanged);
    _searchCtrl.addListener(_onSearchChanged);
    _scopeIdAtOpen = AppSecurityStore.instance.activeScenarioId;
    _logs = List.of(appLog.entries);
    if (widget.focusLogId != null) _showDebug = true;
    _sub = appLog.onLog.listen((entry) {
      if (!mounted ||
          !appLog.isVisibleInCurrentContext(entry) ||
          entry.protectedScopeId != _scopeIdAtOpen) {
        return;
      }
      setState(() => _logs.add(entry));
      if (_autoScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
          }
        });
      }
    });
    _privacySub = appLog.onPrivacyChanged.listen((_) {
      if (!mounted) return;
      setState(() => _logs = List.of(appLog.entries));
    });
    if (widget.focusLogId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealFocusedLog());
    }
  }

  void _onSecurityChanged() {
    if (!mounted ||
        AppSecurityStore.instance.activeScenarioId == _scopeIdAtOpen) {
      return;
    }
    _closeForScopeChange();
  }

  void _closeForScopeChange() {
    if (_closingForScopeChange) return;
    _closingForScopeChange = true;
    _logs.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
      } else {
        setState(() {});
        _closingForScopeChange = false;
      }
    });
  }

  @override
  void dispose() {
    AppSecurityStore.instance.revision.removeListener(_onSecurityChanged);
    _sub?.cancel();
    _privacySub?.cancel();
    _highlightTimer?.cancel();
    _searchCtrl
      ..removeListener(_onSearchChanged)
      ..dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  static String _normalizeSearch(String value) =>
      value.trim().toLowerCase().replaceAll('ё', 'е');

  void _onSearchChanged() {
    final query = _normalizeSearch(_searchCtrl.text);
    if (query == _searchQuery) return;
    setState(() => _searchQuery = query);
    _scrollToTop();
  }

  bool _matchesQueryAndTime(LogEntry entry) {
    if (_searchQuery.isNotEmpty &&
        !_normalizeSearch(entry.exportLine).contains(_searchQuery)) {
      return false;
    }
    if (_fromTime != null && entry.time.isBefore(_fromTime!)) return false;
    if (_toTime != null && entry.time.isAfter(_toTime!)) return false;
    return true;
  }

  List<LogEntry> get _filtered {
    var list = _logs;
    if (!_showDebug) {
      list = list.where((e) => e.level != 'debug').toList();
    }
    if (_filter != 'all') {
      list = list.where((e) => e.category == _filter).toList();
    }
    list = list.where(_matchesQueryAndTime).toList();
    return list;
  }

  List<LogEntry> get _exportEntries =>
      filterLogEntries(_logs, _filter).where(_matchesQueryAndTime).toList();

  void _scrollToTop() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _scrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      _scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  String _formatBoundary(DateTime value) {
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    final year = (value.year % 100).toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$day.$month.$year $hour:$minute';
  }

  Future<void> _pickTimeBoundary({required bool from}) async {
    final now = DateTime.now();
    final firstDate = DateTime(2000);
    final lastDate = DateTime(now.year + 1, 12, 31);
    final current = (from ? _fromTime : _toTime) ?? now;
    final initialDate = current.isBefore(firstDate)
        ? firstDate
        : current.isAfter(lastDate)
        ? lastDate
        : current;
    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: from ? 'Логи начиная с даты' : 'Логи до даты',
      cancelText: 'Отмена',
      confirmText: 'Далее',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      helpText: from ? 'Время начала' : 'Время окончания',
      cancelText: 'Отмена',
      confirmText: 'Готово',
    );
    if (time == null || !mounted) return;
    final value = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (from) {
        _fromTime = value;
      } else {
        _toTime = value;
      }
    });
    _scrollToTop();
  }

  Widget _timeChip({required bool from, required DateTime value}) {
    return InputChip(
      label: Text('${from ? 'С' : 'До'} ${_formatBoundary(value)}'),
      labelStyle: TextStyle(color: GE.text, fontSize: 11),
      backgroundColor: GE.glassFill,
      side: BorderSide(color: GE.glassBorder),
      onDeleted: () => setState(() {
        if (from) {
          _fromTime = null;
        } else {
          _toTime = null;
        }
      }),
      deleteIconColor: GE.sub,
    );
  }

  GlobalKey _keyFor(LogEntry entry) {
    // id=0 is retained for compatibility with direct LogEntry test fixtures.
    final keyId = entry.id == 0 ? -identityHashCode(entry) : entry.id;
    return _logKeys.putIfAbsent(keyId, GlobalKey.new);
  }

  void _revealFocusedLog() {
    if (!mounted || _focusRevealAttempts > 8) return;
    final id = widget.focusLogId;
    if (id == null) return;
    final filtered = _filtered;
    final targetIndex = filtered.indexWhere((entry) => entry.id == id);
    if (targetIndex < 0) return;
    final target = filtered[targetIndex];
    final targetKey = _keyFor(target);
    if (targetKey.currentContext == null) {
      // ListView.builder does not create off-screen rows. First move near the
      // estimated index, then retry after that row has entered the viewport;
      // ensureVisible below performs the final exact alignment.
      if (!_scrollCtrl.hasClients) return;
      _focusRevealAttempts++;
      final estimatedOffset = (targetIndex * 34.0).clamp(
        0.0,
        _scrollCtrl.position.maxScrollExtent,
      );
      _scrollCtrl.jumpTo(estimatedOffset);
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealFocusedLog());
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final targetContext = targetKey.currentContext;
      if (targetContext != null) {
        await Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          alignment: 0.35,
        );
      }
      if (!mounted) return;
      setState(() => _highlightedLogId = id);
      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _highlightedLogId = null);
      });
    });
  }

  Future<void> _copyEntry(LogEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.exportLine));
    if (mounted) toast.show('Лог скопирован');
  }

  String _fileStamp(DateTime time) {
    final year = time.year.toString().padLeft(4, '0');
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$year$month${day}_$hour$minute';
  }

  Future<void> _exportLogs() async {
    final entries = _exportEntries;
    if (entries.isEmpty) {
      toast.show('В выбранном фильтре нет логов', level: ToastLevel.warn);
      return;
    }

    setState(() => _isExporting = true);
    final filterName = _filter == 'all' ? 'all' : _filter;
    final fileName =
        'ghostchat_${filterName}_${_fileStamp(DateTime.now())}.txt';
    final content = formatLogEntries(entries);

    try {
      String? savedLocation;
      if (Platform.isAndroid) {
        // file_selector has no Android save-dialog implementation. The native
        // channel uses ACTION_CREATE_DOCUMENT, so the user chooses Downloads
        // or another visible location in the system file picker.
        savedLocation = await _logChannel.invokeMethod<String>(
          'saveTextFile',
          <String, dynamic>{'fileName': fileName, 'content': content},
        );
      } else {
        final location = await getSaveLocation(
          suggestedName: fileName,
          confirmButtonText: 'Сохранить',
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'Текстовый файл',
              extensions: ['txt'],
              mimeTypes: ['text/plain'],
            ),
          ],
        );
        if (location != null) {
          final file = XFile.fromData(
            Uint8List.fromList(utf8.encode(content)),
            name: fileName,
            mimeType: 'text/plain',
          );
          await file.saveTo(location.path);
          savedLocation = location.path;
        }
      }

      if (mounted && savedLocation != null) {
        toast.show('Лог сохранён: $fileName (${entries.length} строк)');
      }
    } on PlatformException catch (error) {
      if (mounted) {
        toast.show(
          'Не удалось сохранить лог: ${error.message ?? error.code}',
          level: ToastLevel.error,
        );
      }
    } catch (error) {
      if (mounted) {
        toast.show('Не удалось сохранить лог: $error', level: ToastLevel.error);
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'error':
        return GE.red;
      case 'warn':
        return GE.yellow;
      case 'debug':
        return GE.muted;
      default:
        return GE.text;
    }
  }

  Color _categoryColor(String cat) {
    switch (cat) {
      case 'lan':
        return const Color(0xFF22C55E);
      case 'bt':
        return const Color(0xFF60A5FA);
      case 'wifi_direct':
        return const Color(0xFF34D399);
      case 'api':
        return GE.blue;
      case 'auth':
        return GE.yellow;
      case 'chat':
        return GE.primary;
      case 'db':
        return const Color(0xFFF59E0B);
      case 'crypto':
        return const Color(0xFFFB7185);
      case 'storage':
        return const Color(0xFFA78BFA);
      case 'flutter':
      case 'runtime':
        return GE.red;
      default:
        return GE.sub;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          showBack: true,
          titleText: 'Логи (${filtered.length})',
          actions: [
            IconButton(
              icon: Icon(
                CupertinoIcons.arrow_down_doc,
                color: _isExporting ? GE.muted : GE.primary,
                size: 20,
              ),
              tooltip: 'Скачать выбранный лог TXT',
              onPressed: _isExporting ? null : _exportLogs,
            ),
            IconButton(
              icon: Icon(
                _showDebug ? CupertinoIcons.ant_fill : CupertinoIcons.ant,
                color: _showDebug ? GE.primary : GE.sub,
                size: 20,
              ),
              tooltip: 'Debug',
              onPressed: () => setState(() => _showDebug = !_showDebug),
            ),
            IconButton(
              icon: Icon(
                CupertinoIcons.arrow_down_to_line,
                color: _autoScroll ? GE.primary : GE.sub,
                size: 20,
              ),
              tooltip: 'Автопрокрутка',
              onPressed: () => setState(() => _autoScroll = !_autoScroll),
            ),
            IconButton(
              icon: Icon(CupertinoIcons.trash, color: GE.sub, size: 20),
              tooltip: 'Очистить',
              onPressed: () => setState(() {
                appLog.clear();
                _logs.clear();
              }),
            ),
          ],
        ),
        body: Column(
          children: [
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                itemCount: _categories.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final cat = _categories[i];
                  final active = _filter == cat;
                  final c = active ? _categoryColor(cat) : GE.sub;
                  return PressScale(
                    onTap: () => setState(() => _filter = cat),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.withValues(alpha: active ? 0.18 : 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: c.withValues(alpha: active ? 0.5 : 0.2),
                        ),
                      ),
                      child: Text(
                        cat,
                        style: TextStyle(color: c, fontSize: 11.5),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 40,
                      child: TextField(
                        controller: _searchCtrl,
                        textInputAction: TextInputAction.search,
                        style: TextStyle(color: GE.text, fontSize: 13),
                        cursorColor: GE.primary,
                        decoration: InputDecoration(
                          hintText: 'Поиск по логу',
                          hintStyle: TextStyle(color: GE.sub, fontSize: 12),
                          prefixIcon: Icon(
                            CupertinoIcons.search,
                            color: GE.sub,
                            size: 18,
                          ),
                          suffixIcon: _searchQuery.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Очистить поиск',
                                  onPressed: _searchCtrl.clear,
                                  icon: Icon(
                                    CupertinoIcons.xmark_circle_fill,
                                    color: GE.sub,
                                    size: 17,
                                  ),
                                ),
                          filled: true,
                          fillColor: GE.glassFill,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: GE.glassBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: GE.primary),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 8,
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Фильтр времени: начиная с',
                    onPressed: () => _pickTimeBoundary(from: true),
                    icon: Icon(
                      Icons.calendar_month,
                      color: _fromTime == null ? GE.sub : GE.primary,
                      size: 21,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Фильтр времени: до',
                    onPressed: () => _pickTimeBoundary(from: false),
                    icon: Icon(
                      Icons.event,
                      color: _toTime == null ? GE.sub : GE.primary,
                      size: 21,
                    ),
                  ),
                ],
              ),
            ),
            if (_fromTime != null || _toTime != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      if (_fromTime != null)
                        _timeChip(from: true, value: _fromTime!),
                      if (_fromTime != null && _toTime != null)
                        const SizedBox(width: 6),
                      if (_toTime != null)
                        _timeChip(from: false, value: _toTime!),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  filtered.isEmpty
                      ? Center(
                          child: Text(
                            'Нет логов',
                            style: TextStyle(color: GE.sub, fontSize: 13),
                          ),
                        )
                      : ListView.separated(
                          controller: _scrollCtrl,
                          itemCount: filtered.length,
                          // Leave room for the floating down button so it
                          // never covers the last log row.
                          padding: const EdgeInsets.fromLTRB(10, 10, 10, 68),
                          separatorBuilder: (_, _) => const SizedBox(height: 6),
                          itemBuilder: (_, i) {
                            final e = filtered[i];
                            final highlighted = _highlightedLogId == e.id;
                            return AnimatedContainer(
                              key: _keyFor(e),
                              duration: const Duration(milliseconds: 220),
                              padding: const EdgeInsets.only(right: 4),
                              decoration: BoxDecoration(
                                color: highlighted
                                    ? GE.primary.withValues(alpha: 0.16)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  IconButton(
                                    onPressed: () => _copyEntry(e),
                                    tooltip: 'Скопировать лог',
                                    icon: Icon(
                                      CupertinoIcons.doc_on_doc,
                                      color: GE.sub,
                                      size: 16,
                                    ),
                                    padding: const EdgeInsets.all(4),
                                    constraints: const BoxConstraints(
                                      minWidth: 28,
                                      minHeight: 28,
                                    ),
                                  ),
                                  Expanded(
                                    child: SelectableText.rich(
                                      TextSpan(
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11,
                                          height: 1.4,
                                        ),
                                        children: [
                                          TextSpan(
                                            text: '${e.timeStr} ',
                                            style: TextStyle(color: GE.muted),
                                          ),
                                          TextSpan(
                                            text: '[${e.category}] ',
                                            style: TextStyle(
                                              color: _categoryColor(e.category),
                                            ),
                                          ),
                                          TextSpan(
                                            text: e.message,
                                            style: TextStyle(
                                              color: _levelColor(e.level),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                  if (filtered.isNotEmpty)
                    Positioned(
                      right: 14,
                      bottom: 14,
                      child: _scrollBottomButton(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scrollBottomButton() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: GE.surface,
        shape: BoxShape.circle,
        border: Border.all(color: GE.glassBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: IconButton(
        tooltip: 'Вниз логов',
        onPressed: _scrollToBottom,
        icon: Icon(CupertinoIcons.arrow_down, color: GE.primary, size: 20),
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        padding: EdgeInsets.zero,
      ),
    );
  }
}
