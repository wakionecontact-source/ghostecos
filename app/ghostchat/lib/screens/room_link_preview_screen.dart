import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../mesh_background.dart';
import '../services/public_page_link.dart';
import '../services/room_service.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/emoji_text.dart';
import '../widgets/glass.dart';
import 'rooms_screen.dart';

/// A validated GhostChat room link. Keeping this parser separate from the
/// browser opener makes an in-app link open a preview instead of silently
/// sending the user to the web chat.
class RoomLinkTarget {
  final String? username;
  final String? token;
  final String? roomTypeHint;

  const RoomLinkTarget._({this.username, this.token, this.roomTypeHint});

  bool get isInvite => token != null;

  static final _username = RegExp(r'^[A-Za-z0-9_.]{3,64}$');
  static final _groupRef = RegExp(r'^(?:[A-Za-z0-9_.]{3,64}|[0-9]{1,20})$');
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{16,256}$');
  static const _hosts = <String>{
    'ghostecos.duckdns.org',
    'ghostchats.duckdns.org',
  };

  static RoomLinkTarget? parse(String raw) {
    final uri = PublicPageLink.parse(raw);
    if (uri == null || !_hosts.contains(uri.host.toLowerCase())) return null;
    final segments = uri.pathSegments;
    if (segments.length == 2 &&
        segments.first == 'c' &&
        _username.hasMatch(segments.last)) {
      return RoomLinkTarget._(username: segments.last, roomTypeHint: 'channel');
    }
    if (segments.length == 2 &&
        segments.first == 'g' &&
        _groupRef.hasMatch(segments.last)) {
      return RoomLinkTarget._(username: segments.last, roomTypeHint: 'group');
    }
    if (segments.length == 2 &&
        segments.first == 'invite' &&
        _tokenPattern.hasMatch(segments.last)) {
      return RoomLinkTarget._(token: segments.last);
    }
    return null;
  }
}

class RoomLinkPreviewScreen extends StatefulWidget {
  final RoomLinkTarget target;

  const RoomLinkPreviewScreen({super.key, required this.target});

  @override
  State<RoomLinkPreviewScreen> createState() => _RoomLinkPreviewScreenState();
}

class _RoomLinkPreviewScreenState extends State<RoomLinkPreviewScreen> {
  final _service = RoomService.instance;
  RoomPreview? _preview;
  String? _error;
  bool _loading = true;
  bool _actionBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview = widget.target.isInvite
          ? await _service.loadInvitePreview(widget.target.token!)
          : await _service.loadPublicPreview(widget.target.username!);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _primaryAction() async {
    final preview = _preview;
    if (preview == null || _actionBusy) return;
    if (preview.isMember) {
      await _openRoom(preview.room);
      return;
    }

    setState(() => _actionBusy = true);
    try {
      if (widget.target.isInvite) {
        final result = await _service.redeemInvite(widget.target.token!);
        final status = result['status']?.toString();
        if (status == 'requested') {
          _showMessage('Заявка отправлена владельцу');
        } else {
          await _openRoom(RoomSummary.fromMap(result));
        }
      } else {
        final result = await _service.requestJoin(preview.room);
        if (result['status']?.toString() == 'requested') {
          _showMessage('Заявка отправлена владельцу');
        } else {
          final room = await _service.loadRoom(preview.room);
          await _openRoom(room);
        }
      }
    } catch (error) {
      if (mounted) _showMessage('Не удалось выполнить действие: $error');
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _openRoom(RoomSummary room) async {
    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => RoomChatScreen(room: room)));
  }

  Future<void> _openUrl(String raw) async {
    final target = RoomLinkTarget.parse(raw);
    if (target != null) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => RoomLinkPreviewScreen(target: target),
        ),
      );
      return;
    }
    await PublicPageLink.open(raw);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(CupertinoIcons.chevron_back),
          ),
          title: const Text('Предпросмотр'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _ErrorView(error: _error!, onRetry: _load)
            : _body(_preview!),
      ),
    );
  }

  Widget _body(RoomPreview preview) {
    final room = preview.room;
    final fallback = room.isChannel
        ? '#'
        : (room.title.isEmpty ? '?' : room.title.substring(0, 1).toUpperCase());
    final type = room.isChannel ? 'Канал' : 'Группа';
    final access = room.isPublic ? 'Публичная' : 'Приватная';
    final actionLabel = preview.isMember
        ? 'Перейти'
        : widget.target.isInvite
        ? 'Принять приглашение'
        : 'Вступить';

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          GlassCard(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
            child: Column(
              children: [
                GhostAvatar(
                  avatarUrl: room.avatarUrl,
                  fallbackText: fallback,
                  fallbackIcon: room.isChannel
                      ? CupertinoIcons.antenna_radiowaves_left_right
                      : CupertinoIcons.person_3_fill,
                  size: 92,
                ),
                const SizedBox(height: 12),
                Text(
                  room.title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (room.username?.isNotEmpty == true) ...[
                  const SizedBox(height: 4),
                  Text(
                    '@${room.username}',
                    style: TextStyle(color: GE.primary, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _InfoChip(icon: CupertinoIcons.person_2, label: type),
                    _InfoChip(
                      icon: room.isPublic
                          ? CupertinoIcons.globe
                          : CupertinoIcons.lock,
                      label: access,
                    ),
                    _InfoChip(
                      icon: CupertinoIcons.person_3,
                      label: '${room.membersCount}',
                    ),
                  ],
                ),
                if (room.about.trim().isNotEmpty) ...[
                  const SizedBox(height: 15),
                  Text(
                    room.about,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: GE.sub, height: 1.35),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _actionBusy ? null : _primaryAction,
                  icon: _actionBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          preview.isMember
                              ? CupertinoIcons.arrow_right
                              : CupertinoIcons.person_add,
                        ),
                  label: Text(actionLabel),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: PublicPageLink.openDownload,
                icon: const Icon(CupertinoIcons.cloud_download),
                label: const Text('Скачать'),
              ),
            ],
          ),
          if (preview.messages.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text(
              'Сообщения',
              style: TextStyle(
                color: GE.text,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            for (final message in preview.messages)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _PreviewMessage(message: message, onUrlTap: _openUrl),
              ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                room.isPrivate
                    ? 'Сообщения появятся после принятия приглашения.'
                    : 'В этом канале пока нет сообщений.',
                textAlign: TextAlign.center,
                style: TextStyle(color: GE.sub),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: GE.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: GE.primary),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(color: GE.text, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _PreviewMessage extends StatelessWidget {
  final RoomMessage message;
  final Future<void> Function(String url) onUrlTap;

  const _PreviewMessage({required this.message, required this.onUrlTap});

  @override
  Widget build(BuildContext context) {
    final author = message.senderDisplayName.trim().isNotEmpty
        ? message.senderDisplayName.trim()
        : (message.senderUsername.trim().isEmpty
              ? 'Участник'
              : '@${message.senderUsername.trim()}');
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GhostAvatar(
            avatarUrl: message.senderAvatarUrl,
            fallbackText: author.substring(0, 1).toUpperCase(),
            size: 32,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: GE.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                EmojiText(
                  message.text,
                  style: TextStyle(color: GE.text, fontSize: 14, height: 1.3),
                  onUrlTap: onUrlTap,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              CupertinoIcons.exclamationmark_triangle,
              color: GE.red,
              size: 32,
            ),
            const SizedBox(height: 12),
            Text(
              'Не удалось загрузить превью',
              textAlign: TextAlign.center,
              style: TextStyle(color: GE.text, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              error,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: GE.sub, fontSize: 12),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(CupertinoIcons.refresh),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}
