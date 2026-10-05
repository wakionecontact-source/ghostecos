// Экран "Хранилище" — как в Telegram: кольцевая диаграмма + список категорий.
// Отличие от ТГ: у нас нет серверного медиа-кэша (локальный E2E-мессенджер),
// категории — реальные байты из SQLite (filecache у серверных чатов,
// lan_messages.file_bytes у LAN-чатов) плюс "накладные расходы" самой БД
// (текст сообщений, индексы — то, что в файле БД, но не посчитано как медиа).
//
// Форма кольца — не круг и не квадрат жёстко, а суперэллипс, который меняет
// форму вместе с настройкой "Скругление" во Внешнем виде (см.
// StorageRingChart/ThemeService.cornerNotifier) — единственный экран, где
// эта настройка видна не как радиус угла карточки, а как форма графика.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../services/db_service.dart';
import '../services/chat_repo.dart';
import '../services/room_service.dart';
import '../services/lan_chat_store.dart';
import '../services/theme_service.dart';
import '../widgets/glass.dart';
import '../widgets/skeleton.dart';
import '../widgets/storage_ring_chart.dart';

class StorageScreen extends StatefulWidget {
  final Set<String> initialChats;

  const StorageScreen({super.key, this.initialChats = const {}});
  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _CategoryInfo {
  final String key;
  final String label;
  final IconData icon;
  final Color Function() color;
  const _CategoryInfo(this.key, this.label, this.icon, this.color);
}

final List<_CategoryInfo> _categories = [
  _CategoryInfo('photo', 'Фото', Icons.image_outlined, () => GE.blue),
  _CategoryInfo('video', 'Видео', Icons.videocam_outlined, () => GE.primary),
  _CategoryInfo('voice', 'Голосовые', Icons.mic_none_outlined, () => GE.green),
  _CategoryInfo(
    'files',
    'Файлы',
    Icons.insert_drive_file_outlined,
    () => GE.yellow,
  ),
  _CategoryInfo(
    'db_overhead',
    'Кэш базы данных',
    Icons.storage_outlined,
    () => GE.muted,
  ),
];

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 Б';
  const units = ['Б', 'КБ', 'МБ', 'ГБ'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(v < 10 ? 1 : 0);
  return '$s ${units[i]}';
}

class _StorageScreenState extends State<StorageScreen> {
  bool _loading = true;
  bool _clearing = false;
  Map<String, int> _totals = {};
  final Set<String> _hiddenCategories = {};
  final Set<String> _selectedChats = {};
  String? _selectedCategory;
  double _totalLimitGb = 2;
  double _mediaLimitGb = 1;
  double _keepDays = 30;
  static const _selectedCategoryKey = 'storage_selected_category_v1';
  static const _hiddenCategoriesKey = 'storage_hidden_categories_v1';
  static const _totalLimitKey = 'storage_total_limit_gb_v1';
  static const _mediaLimitKey = 'storage_media_limit_gb_v1';
  static const _keepDaysKey = 'storage_keep_days_v1';
  static const _selectedChatsKey = 'storage_selected_chats_v1';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Любой из источников может кинуть исключение (гостевой режим без
    // серверного логина, недоступная БД и т.п.) — раньше это оставляло
    // экран в вечном спиннере, т.к. setState просто не успевал случиться.
    var server = <String, int>{};
    var lan = <String, int>{};
    try {
      server = await DbService.instance.storageByCategory();
    } catch (_) {}
    try {
      lan = await LanChatStore.instance.storageByCategory();
    } catch (_) {}
    final merged = <String, int>{};
    for (final c in _categories) {
      merged[c.key] = (server[c.key] ?? 0) + (lan[c.key] ?? 0);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      _selectedCategory = prefs.getString(_selectedCategoryKey);
      _hiddenCategories
        ..clear()
        ..addAll(prefs.getStringList(_hiddenCategoriesKey) ?? const []);
      _totalLimitGb = prefs.getDouble(_totalLimitKey) ?? 2;
      _mediaLimitGb = prefs.getDouble(_mediaLimitKey) ?? 1;
      _keepDays = (prefs.getInt(_keepDaysKey) ?? 30).toDouble();
      _selectedChats
        ..clear()
        ..addAll(
          widget.initialChats.isNotEmpty
              ? widget.initialChats
              : (prefs.getStringList(_selectedChatsKey) ?? const []),
        );
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _totals = merged;
      _loading = false;
    });
  }

  Future<void> _toggleCategory(_CategoryInfo category) async {
    setState(() {
      _selectedCategory = category.key;
      // Тап по строке одновременно выбирает защищаемую категорию и
      // переключает её видимость в кольце. Повторный тап возвращает сегмент.
      if (!_hiddenCategories.add(category.key)) {
        _hiddenCategories.remove(category.key);
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedCategoryKey, category.key);
    await prefs.setStringList(_hiddenCategoriesKey, _hiddenCategories.toList());
  }

  Future<void> _selectRingSegment(
    List<StorageSegment> segments,
    int index,
  ) async {
    if (index < 0 || index >= segments.length) return;
    final id = segments[index].id;
    if (id.isEmpty) return;
    setState(() {
      _selectedCategory = id;
      _hiddenCategories.remove(id);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedCategoryKey, id);
    await prefs.setStringList(_hiddenCategoriesKey, _hiddenCategories.toList());
  }

  Future<void> _saveLimits() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_totalLimitKey, _totalLimitGb);
    await prefs.setDouble(_mediaLimitKey, _mediaLimitGb);
    await prefs.setInt(_keepDaysKey, _keepDays.round());
  }

  List<String> _availableChats() => {
    ...ChatRepo.instance.dialogsNotifier.value.map((dialog) => dialog.username),
    ...LanChatStore.instance.dialogsNotifier.value.map(
      (dialog) => dialog.username,
    ),
  }.toList();

  Future<void> _chooseChats() async {
    final selected = await Navigator.of(context).push<Set<String>>(
      MaterialPageRoute(
        builder: (_) => StorageChatSelectionScreen(
          availableChats: _availableChats(),
          initialSelected: _selectedChats,
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _selectedChats
        ..clear()
        ..addAll(selected);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_selectedChatsKey, _selectedChats.toList());
  }

  @override
  Widget build(BuildContext context) {
    final total = _totals.values.fold<int>(0, (a, b) => a + b);
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: true, titleText: 'Память устройства'),
        body: _loading
            ? ListView(
                padding: const EdgeInsets.all(16),
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  const Center(
                    child: SkeletonBox(width: 180, height: 180, radius: 90),
                  ),
                  const SizedBox(height: 24),
                  GlassCard(
                    isListSection: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: SkeletonRowList(
                      count: _categories.length,
                      avatarSize: 32,
                    ),
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  ValueListenableBuilder<double>(
                    valueListenable: ThemeService.instance.cornerNotifier,
                    builder: (context, cornerFactor, _) {
                      final segments = total == 0
                          ? <StorageSegment>[]
                          : _categories
                                .where(
                                  (c) =>
                                      (_totals[c.key] ?? 0) > 0 &&
                                      !_hiddenCategories.contains(c.key),
                                )
                                .map(
                                  (c) => StorageSegment(
                                    id: c.key,
                                    label: c.label,
                                    bytes: _totals[c.key] ?? 0,
                                    color: c.color(),
                                  ),
                                )
                                .toList();
                      return Center(
                        child: StorageRingChart(
                          segments: total == 0
                              ? [
                                  StorageSegment(
                                    id: 'empty',
                                    label: 'Пусто',
                                    bytes: 1,
                                    color: GE.border,
                                  ),
                                ]
                              : segments,
                          cornerFactor: cornerFactor,
                          selectedIndex:
                              segments.indexWhere(
                                    (segment) =>
                                        segment.id == _selectedCategory,
                                  ) <
                                  0
                              ? null
                              : segments.indexWhere(
                                  (segment) => segment.id == _selectedCategory,
                                ),
                          onTap: (index) => _selectRingSegment(segments, index),
                          center: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _formatBytes(total),
                                style: TextStyle(
                                  color: GE.text,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                'занято',
                                style: TextStyle(color: GE.sub, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  GlassCard(
                    isListSection: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        for (var i = 0; i < _categories.length; i++)
                          _categoryRow(
                            _categories[i],
                            last: i == _categories.length - 1,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  GlassCard(
                    isListSection: true,
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Освободить место',
                          style: TextStyle(
                            color: GE.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Удалит загруженные вложения. История чатов останется, но LAN-файлы повторно скачать нельзя.',
                          style: TextStyle(
                            color: GE.sub,
                            fontSize: 11,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 10),
                        GlassButton(
                          fullWidth: true,
                          icon: Icons.cleaning_services_outlined,
                          label: 'Очистить кэш вложений',
                          danger: true,
                          loading: _clearing,
                          onTap: _clearMediaCache,
                        ),
                        const SizedBox(height: 8),
                        GlassButton(
                          fullWidth: true,
                          icon: Icons.chat_outlined,
                          label: _selectedChats.isEmpty
                              ? 'Выбрать чаты для очистки'
                              : 'Чаты для очистки: ${_selectedChats.length}',
                          onTap: _clearing ? null : _chooseChats,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _limitsCard(),
                ],
              ),
      ),
    );
  }

  Widget _categoryRow(_CategoryInfo c, {bool last = false}) {
    final bytes = _totals[c.key] ?? 0;
    final selected = _selectedCategory == c.key;
    return Column(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _toggleCategory(c),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: 14,
              vertical: selected ? 16 : 12,
            ),
            decoration: BoxDecoration(
              color: selected ? c.color().withValues(alpha: 0.08) : null,
              border: selected
                  ? Border.all(color: c.color().withValues(alpha: 0.42))
                  : null,
              borderRadius: BorderRadius.circular(GE.radiusSm),
            ),
            child: Row(
              children: [
                AnimatedScale(
                  scale: selected ? 1.12 : 1,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c.color().withValues(alpha: 0.16),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(c.icon, size: 17, color: c.color()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    c.label,
                    style: TextStyle(
                      color: GE.text,
                      fontSize: selected ? 15 : 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  _formatBytes(bytes),
                  style: TextStyle(color: GE.sub, fontSize: 13),
                ),
                const SizedBox(width: 4),
                Icon(
                  _hiddenCategories.contains(c.key)
                      ? Icons.check_box_outline_blank
                      : Icons.check_box,
                  color: _hiddenCategories.contains(c.key) ? GE.sub : c.color(),
                  size: 19,
                ),
              ],
            ),
          ),
        ),
        if (!last) Divider(height: 1, indent: 58, color: GE.border),
      ],
    );
  }

  Widget _limitsCard() {
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ограничения',
            style: TextStyle(
              color: GE.text,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Автоматически освобождать место по этим правилам',
            style: TextStyle(color: GE.sub, fontSize: 11),
          ),
          const SizedBox(height: 10),
          _limitSlider(
            label: 'Общий лимит',
            value: _totalLimitGb,
            suffix: '${_totalLimitGb.toStringAsFixed(1)} ГБ',
            min: 0.5,
            max: 20,
            divisions: 39,
            onChanged: (v) {
              setState(() => _totalLimitGb = v);
              _saveLimits();
            },
          ),
          _limitSlider(
            label: 'Медиа',
            value: _mediaLimitGb,
            suffix: '${_mediaLimitGb.toStringAsFixed(1)} ГБ',
            min: 0.1,
            max: _totalLimitGb,
            divisions: 39,
            onChanged: (v) {
              setState(() => _mediaLimitGb = v);
              _saveLimits();
            },
          ),
          _limitSlider(
            label: 'Хранить медиа',
            value: _keepDays,
            suffix: '${_keepDays.round()} дн.',
            min: 1,
            max: 365,
            divisions: 364,
            onChanged: (v) {
              setState(() => _keepDays = v);
              _saveLimits();
            },
          ),
        ],
      ),
    );
  }

  Widget _limitSlider({
    required String label,
    required double value,
    required String suffix,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    final safeMax = max < min ? min : max;
    final safeValue = value.clamp(min, safeMax).toDouble();
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: GE.text, fontSize: 12),
              ),
            ),
            Text(suffix, style: TextStyle(color: GE.sub, fontSize: 12)),
          ],
        ),
        Slider(
          value: safeValue,
          min: min,
          max: safeMax,
          divisions: divisions,
          activeColor: GE.primary,
          inactiveColor: GE.border,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Future<void> _clearMediaCache() async {
    if (_clearing) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GE.bgDeep,
        title: Text('Очистить вложения?', style: TextStyle(color: GE.text)),
        content: Text(
          'Загруженные файлы будут удалены с устройства. Сообщения сохранятся, но вложения из LAN-чатов восстановить нельзя.',
          style: TextStyle(color: GE.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена', style: TextStyle(color: GE.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Очистить', style: TextStyle(color: GE.red)),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() => _clearing = true);
    var removed = 0;
    final categories = _categories
        .where(
          (category) =>
              category.key != 'db_overhead' &&
              !_hiddenCategories.contains(category.key),
        )
        .map((category) => category.key)
        .toSet();
    try {
      final serverPeers = _selectedChats
          .where(
            (id) =>
                !id.startsWith(lanDialogPrefix) &&
                !id.startsWith(roomDialogPrefix),
          )
          .toList();
      final lanDevices = _selectedChats
          .where((id) => id.startsWith(lanDialogPrefix))
          .map((id) => id.substring(lanDialogPrefix.length))
          .toList();
      if (_selectedChats.isEmpty) {
        removed += await DbService.instance.clearFileCacheByCategories(
          categories,
        );
        removed += await LanChatStore.instance.clearMediaCacheByCategories(
          categories,
        );
      } else {
        removed += await DbService.instance.clearFileCacheForPeers(
          serverPeers,
          categories: categories,
        );
        removed += await LanChatStore.instance.clearMediaCacheForDevices(
          lanDevices,
          categories: categories,
        );
      }
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Удалено вложений: $removed')));
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }
}

class StorageChatSelectionScreen extends StatefulWidget {
  final List<String> availableChats;
  final Set<String> initialSelected;

  const StorageChatSelectionScreen({
    super.key,
    required this.availableChats,
    this.initialSelected = const {},
  });

  @override
  State<StorageChatSelectionScreen> createState() =>
      _StorageChatSelectionScreenState();
}

class _StorageChatSelectionScreenState
    extends State<StorageChatSelectionScreen> {
  static const _selectedChatsKey = 'storage_selected_chats_v1';
  late final Set<String> _selected = {...widget.initialSelected};
  bool _closing = false;

  List<String> get _chats => {
    ...widget.availableChats,
    ..._selected,
  }.where((id) => id.trim().isNotEmpty).toSet().toList();

  String _label(String id) {
    if (id.startsWith(lanDialogPrefix)) {
      return 'LAN · ${id.substring(lanDialogPrefix.length)}';
    }
    if (id.startsWith(roomDialogPrefix)) return 'Комната · $id';
    return '@$id';
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_selectedChatsKey, _selected.toList());
  }

  Future<void> _finish() async {
    if (_closing) return;
    _closing = true;
    await _persist();
    if (mounted) Navigator.of(context).pop({..._selected});
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Set<String>>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_finish());
      },
      child: MeshBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: GlassAppBar(
            leading: IconButton(
              onPressed: _closing ? null : _finish,
              icon: const Icon(CupertinoIcons.chevron_back),
            ),
            titleText: 'Чаты для очистки',
            actions: [
              IconButton(
                tooltip: 'Сохранить выбор',
                onPressed: _closing ? null : _finish,
                icon: const Icon(CupertinoIcons.checkmark),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
            children: [
              Text(
                'Выбор сохраняется между выходами из хранилища и перезапусками приложения.',
                style: TextStyle(color: GE.sub, fontSize: 12, height: 1.35),
              ),
              const SizedBox(height: 12),
              if (_chats.isEmpty)
                Text(
                  'Нет чатов с локальным кэшем',
                  style: TextStyle(color: GE.sub),
                )
              else
                GlassCard(
                  isListSection: true,
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (var i = 0; i < _chats.length; i++) ...[
                        ListTile(
                          leading: Icon(
                            _selected.contains(_chats[i])
                                ? CupertinoIcons.checkmark_circle_fill
                                : CupertinoIcons.circle,
                            color: _selected.contains(_chats[i])
                                ? GE.primary
                                : GE.sub,
                          ),
                          title: Text(
                            _label(_chats[i]),
                            style: TextStyle(color: GE.text, fontSize: 14),
                          ),
                          onTap: () {
                            setState(() {
                              if (!_selected.remove(_chats[i])) {
                                _selected.add(_chats[i]);
                              }
                            });
                            unawaited(_persist());
                          },
                        ),
                        if (i < _chats.length - 1)
                          Divider(height: 1, indent: 56, color: GE.border),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
