import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../widgets/glass.dart';
import '../widgets/avatar.dart';
import '../widgets/bot_badge.dart';
import '../widgets/bot_token_sheet.dart';
import '../widgets/toast_overlay.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/theme_service.dart';
import 'bot_detail_screen.dart';

const _sdkInstallCommand = 'pip install ghostecos-api';
const _sdkImportCommand = 'from ghostapi import bot';

class BotsScreen extends StatefulWidget {
  const BotsScreen({super.key});
  @override
  State<BotsScreen> createState() => _BotsScreenState();
}

class _Bot {
  final int id;
  final String username;
  final String displayName;
  final String status;
  final String? avatarUrl;
  const _Bot({
    required this.id,
    required this.username,
    required this.displayName,
    required this.status,
    this.avatarUrl,
  });

  factory _Bot.fromJson(Map<String, dynamic> json) {
    final id = json['id'] is num
        ? (json['id'] as num).toInt()
        : int.tryParse('${json['id']}') ?? 0;
    return _Bot(
      id: id,
      username: json['username']?.toString() ?? '',
      displayName: json['display_name']?.toString() ?? '',
      status: json['status']?.toString() ?? 'offline',
      avatarUrl: json['avatar_url']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'username': username,
    'display_name': displayName,
    'status': status,
    if (avatarUrl != null) 'avatar_url': avatarUrl,
  };
}

class _BotsScreenState extends State<BotsScreen> {
  bool _loading = true;
  bool _creating = false;
  String? _error;
  List<_Bot> _bots = [];
  bool _hasCachedList = false;

  Future<String> _cacheKey() async {
    final account = (await AuthService.username())?.trim().toLowerCase();
    return 'ghostchat_bots_cache_v1_${account == null || account.isEmpty ? 'anonymous' : account}';
  }

  @override
  void initState() {
    super.initState();
    _loadFromCacheThenServer();
  }

  Future<bool> _restoreCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(await _cacheKey());
      if (raw == null) return false;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return false;
      final cached = decoded
          .whereType<Map>()
          .map((item) => _Bot.fromJson(Map<String, dynamic>.from(item)))
          .where((bot) => bot.id > 0 && bot.username.isNotEmpty)
          .toList(growable: false);
      _hasCachedList = true;
      if (mounted) {
        setState(() {
          _bots = cached;
          _loading = false;
          _error = null;
        });
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveCache(List<_Bot> bots) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        await _cacheKey(),
        jsonEncode(bots.map((bot) => bot.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _loadFromCacheThenServer() async {
    final restored = await _restoreCache();
    await _refreshFromServer(showLoading: !restored);
  }

  Future<void> _load() => _loadFromCacheThenServer();

  Future<void> _refreshFromServer({required bool showLoading}) async {
    if (mounted && showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final resp = await ApiClient().botsGet('/mine');
      final list = ((resp as Map)['bots'] as List?) ?? const [];
      final bots = list
          .whereType<Map>()
          .map((m) => _Bot.fromJson(Map<String, dynamic>.from(m)))
          .where((bot) => bot.id > 0 && bot.username.isNotEmpty)
          .toList();
      _bots = bots;
      _hasCachedList = true;
      await _saveCache(bots);
      _error = null;
    } catch (e) {
      // Cached bot data is still useful offline. Only show an error when no
      // usable list has ever been saved on this device.
      if (!_hasCachedList) _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _createBot() async {
    final details = await showGlassSheet<Map<String, String>>(
      context,
      child: const _CreateBotSheet(),
    );
    if (details == null || !mounted) return;
    setState(() => _creating = true);
    try {
      final raw = await ApiClient().botsPost('/create', details);
      final created = raw is Map ? Map<String, dynamic>.from(raw) : const {};
      final username = created['username'] as String? ?? details['username']!;
      final token = created['token'] as String?;
      if (mounted) {
        setState(() => _creating = false);
        await _load();
      }
      if (mounted && token != null && token.isNotEmpty) {
        await showBotTokenSheet(context, username: username, token: token);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _creating = false);
      toast.show('Не удалось создать бота: $e');
    }
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) toast.show('Код скопирован');
  }

  Widget _copyableCodeRow({required String label, required String code}) {
    return PressScale(
      onTap: () => _copyCode(code),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(color: GE.sub, fontSize: 11)),
                  const SizedBox(height: 4),
                  SelectableText(
                    code,
                    style: TextStyle(
                      color: GE.text,
                      fontFamily: 'monospace',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Icon(CupertinoIcons.doc_on_doc, color: GE.primary, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _sdkSetupCard() {
    return GlassCard(
      isListSection: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text(
              'Подключение ghostecos-api',
              style: TextStyle(
                color: GE.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (ThemeService.instance.showDetailedDescriptions)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Text(
                'Нажми на строку, чтобы скопировать код.',
                style: TextStyle(color: GE.sub, fontSize: 11),
              ),
            ),
          _copyableCodeRow(label: 'Установка SDK', code: _sdkInstallCommand),
          Divider(height: 1, indent: 12, color: GE.glassBorder),
          _copyableCodeRow(label: 'Импорт', code: _sdkImportCommand),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: true, titleText: 'Боты'),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: GE.primary))
            : _error != null
            ? _errorView()
            : _bots.isEmpty
            ? _emptyView()
            : _listView(),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: TextStyle(color: GE.sub),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            GlassButton(label: 'Повторить', onTap: _load),
          ],
        ),
      ),
    );
  }

  Widget _emptyView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: GE.primary.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: GE.primary.withValues(alpha: 0.24)),
              ),
              child: Icon(Icons.smart_toy_rounded, size: 38, color: GE.primary),
            ),
            const SizedBox(height: 18),
            Text(
              'Пока нет ботов',
              style: TextStyle(
                color: GE.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Создай своего бота: задай ему имя и username, а затем подключи через ghostecos-api.',
              textAlign: TextAlign.center,
              style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 20),
            GlassButton(
              label: _creating ? 'Создаю…' : 'Создать бота',
              icon: _creating ? null : CupertinoIcons.add_circled_solid,
              primary: true,
              onTap: _creating ? null : _createBot,
            ),
            const SizedBox(height: 10),
            _sdkSetupCard(),
            const SizedBox(height: 14),
            Text(
              'Токен показывается один раз и нужен только программе бота — не отправляй его в чат.',
              textAlign: TextAlign.center,
              style: TextStyle(color: GE.muted, fontSize: 11, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listView() {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GlassButton(
            label: _creating ? 'Создаю…' : 'Создать бота',
            icon: _creating ? null : CupertinoIcons.add_circled_solid,
            fullWidth: true,
            onTap: _creating ? null : _createBot,
          ),
          const SizedBox(height: 14),
          _sdkSetupCard(),
          const SizedBox(height: 14),
          GlassCard(
            isListSection: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < _bots.length; i++)
                  _botRow(_bots[i], last: i == _bots.length - 1),
              ],
            ),
          ),
          const SizedBox(height: 16),
          GlassButton(
            label: 'Обновить список',
            icon: Icons.refresh_rounded,
            fullWidth: true,
            onTap: _load,
          ),
        ],
      ),
    );
  }

  Widget _botRow(_Bot b, {bool last = false}) {
    return Column(
      children: [
        PressScale(
          onTap: () => Navigator.of(context)
              .push(
                MaterialPageRoute(
                  builder: (_) => BotDetailScreen(
                    botId: b.id,
                    username: b.username,
                    displayName: b.displayName,
                    avatarUrl: b.avatarUrl,
                  ),
                ),
              )
              .then((_) => _load()),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    GhostAvatar(
                      avatarUrl: b.avatarUrl,
                      fallbackText: b.displayName,
                      size: 48,
                    ),
                    const Positioned(
                      left: -2,
                      bottom: -2,
                      child: BotBadge(size: 19),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        b.displayName,
                        style: TextStyle(
                          color: GE.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '@${b.username}',
                        style: TextStyle(color: GE.sub, fontSize: 12.5),
                      ),
                      const SizedBox(height: 5),
                      _BotStatusLabel(status: b.status),
                    ],
                  ),
                ),
                Icon(CupertinoIcons.chevron_right, size: 16, color: GE.sub),
              ],
            ),
          ),
        ),
        if (!last) Divider(height: 1, indent: 48, color: GE.border),
      ],
    );
  }
}

class _BotStatusLabel extends StatelessWidget {
  final String status;
  const _BotStatusLabel({required this.status});

  @override
  Widget build(BuildContext context) {
    final online = status == 'online';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: online ? GE.green : GE.muted,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          online ? 'в сети' : 'не в сети',
          style: TextStyle(color: online ? GE.green : GE.sub, fontSize: 11),
        ),
      ],
    );
  }
}

class _CreateBotSheet extends StatefulWidget {
  const _CreateBotSheet();

  @override
  State<_CreateBotSheet> createState() => _CreateBotSheetState();
}

class _CreateBotSheetState extends State<_CreateBotSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    super.dispose();
  }

  String _normalizedUsername() {
    var value = _username.text
        .trim()
        .replaceFirst(RegExp(r'^@+'), '')
        .toLowerCase();
    if (!value.endsWith('bot')) value = '${value}_bot';
    return value;
  }

  InputDecoration _decoration(String label, String hint) => InputDecoration(
    labelText: label,
    hintText: hint,
    labelStyle: TextStyle(color: GE.sub),
    hintStyle: TextStyle(color: GE.muted),
    filled: true,
    fillColor: GE.glassFill,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: GE.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: GE.primary, width: 1.4),
    ),
  );

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop({
      'display_name': _name.text.trim(),
      'username': _normalizedUsername(),
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: GE.sub.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Новый бот',
                style: TextStyle(
                  color: GE.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Как в BotFather: имя будет видно людям, username должен заканчиваться на bot.',
                style: TextStyle(color: GE.sub, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _name,
                autofocus: true,
                maxLength: 100,
                textCapitalization: TextCapitalization.words,
                style: TextStyle(color: GE.text),
                decoration: _decoration('Имя бота', 'Например, Помощник'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Введи имя бота'
                    : null,
                onFieldSubmitted: (_) => FocusScope.of(context).nextFocus(),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _username,
                maxLength: 64,
                autocorrect: false,
                enableSuggestions: false,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_.@]')),
                ],
                style: TextStyle(color: GE.text),
                decoration: _decoration('Username', 'weather_bot'),
                validator: (value) {
                  final typed = (value ?? '').trim().replaceFirst(
                    RegExp(r'^@+'),
                    '',
                  );
                  if (typed.isEmpty) {
                    return 'Введи username';
                  }
                  final normalized = _normalizedUsername();
                  if (normalized.length < 3 ||
                      normalized.length > 64 ||
                      !RegExp(r'^[a-z0-9_.]+$').hasMatch(normalized)) {
                    return 'Используй латиницу, цифры, точку или _';
                  }
                  return null;
                },
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 4),
              Text(
                'Если не дописать bot, приложение добавит суффикс _bot. Username после создания постоянный.',
                style: TextStyle(color: GE.muted, fontSize: 11, height: 1.35),
              ),
              const SizedBox(height: 18),
              GlassButton(
                label: 'Создать бота',
                icon: CupertinoIcons.add_circled_solid,
                primary: true,
                fullWidth: true,
                onTap: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
