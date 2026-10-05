// Базовый переиспользуемый экран "Выберите чаты" — мультивыбор поверх
// обычного списка диалогов. Временное/простое решение везде, где нужно
// выбрать несколько чатов (сейчас — исключения уведомлений), без отдельной
// вёрстки под каждый конкретный случай.
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../services/chat_repo.dart';
import '../services/db_service.dart';
import '../services/lan_chat_store.dart';
import '../services/bookmark_store.dart';
import '../widgets/glass.dart';
import '../widgets/avatar.dart';
import '../widgets/emoji_text.dart';

class ChatPickerScreen extends StatefulWidget {
  final Set<String> initialSelected;
  final String title;

  const ChatPickerScreen({
    super.key,
    this.initialSelected = const {},
    this.title = 'Выберите чаты',
  });

  @override
  State<ChatPickerScreen> createState() => _ChatPickerScreenState();
}

class _ChatPickerScreenState extends State<ChatPickerScreen> {
  late final Set<String> _selected = Set.of(widget.initialSelected);

  @override
  Widget build(BuildContext context) {
    return MeshBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(showBack: true, titleText: widget.title),
        body: ValueListenableBuilder<List<StoredDialog>>(
          valueListenable: ChatRepo.instance.dialogsNotifier,
          builder: (context, serverDialogs, _) =>
              ValueListenableBuilder<List<StoredDialog>>(
                valueListenable: LanChatStore.instance.dialogsNotifier,
                builder: (context, lanDialogs, _) =>
                    ValueListenableBuilder<List<StoredDialog>>(
                      valueListenable: BookmarkStore.instance.dialogsNotifier,
                      builder: (context, bookmarkDialogs, _) {
                        final seen = <String>{};
                        final real =
                            [
                              ...serverDialogs,
                              ...lanDialogs,
                              ...bookmarkDialogs,
                            ].where((d) {
                              if (d.username.startsWith('g:')) return false;
                              return seen.add(d.username);
                            }).toList();
                        if (real.isEmpty) {
                          return Center(
                            child: Text(
                              'Пока нет чатов',
                              style: TextStyle(color: GE.sub, fontSize: 14),
                            ),
                          );
                        }
                        return ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: real.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 4),
                          itemBuilder: (context, i) {
                            final d = real[i];
                            final isSel = _selected.contains(d.username);
                            return PressScale(
                              onTap: () => setState(() {
                                if (isSel) {
                                  _selected.remove(d.username);
                                } else {
                                  _selected.add(d.username);
                                }
                              }),
                              child: GlassCard(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    GhostAvatar(
                                      avatarUrl: ChatRepo.instance
                                          .getPeerAvatarCached(d.username),
                                      fallbackText: d.displayName.isNotEmpty
                                          ? d.displayName[0]
                                          : '?',
                                      size: 40,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: EmojiText(
                                        d.displayName,
                                        allowFormatting: false,
                                        style: TextStyle(
                                          color: GE.text,
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      isSel
                                          ? CupertinoIcons.checkmark_circle_fill
                                          : CupertinoIcons.circle,
                                      color: isSel ? GE.primary : GE.sub,
                                      size: 22,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
              ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: GlassButton(
              label: 'Готово',
              primary: true,
              fullWidth: true,
              onTap: () => Navigator.of(context).pop(_selected),
            ),
          ),
        ),
      ),
    );
  }
}
