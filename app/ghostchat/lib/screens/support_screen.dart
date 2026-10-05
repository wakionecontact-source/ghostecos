// SupportScreen — экран «Поддержка». FAQ остаётся как есть, но карточка
// «Связаться» теперь ведёт в НАСТОЯЩИЙ внутренний чат с системным
// GhostChat-аккаунтом @support (не внешняя ссылка на Telegram) — сообщения
// туда идут как боту (plain_text на сервере, см. bot_api.py/chat_router.py),
// читает и отвечает Waki через support_admin.html (локальная HTML-панель,
// C:\Users\ilush\GC\support_admin.html, эндпоинты — support_admin_router.py
// на сервере).

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../services/theme_service.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';
import 'chat_screen.dart';

class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  // Системный GhostChat-аккаунт поддержки (account_type='bot', провижинен
  // на сервере, id=116) — НЕ Telegram-хендл, обычный username в GhostChat.
  static const _supportUsername = 'support';
  static const _supportHandle = '@support';

  // Список вопрос → ответ. Простым языком, термины в скобках.
  static const List<List<String>> _faq = [
    [
      'Как работает шифрование?',
      'В личных чатах с людьми сообщения шифруются на устройстве и '
          'расшифровываются на устройствах собеседников (сквозное шифрование, '
          'E2EE). Чаты с ботами, включая @support, работают иначе: бот получает '
          'текст сообщения, поэтому сквозного шифрования там нет.',
    ],
    [
      'Что такое ключ-фраза (seed) и зачем её хранить?',
      'Ключ-фраза (seed) — это набор слов, который заменяет твой главный '
          'пароль и подтверждает, что аккаунт твой. По ней можно вернуть '
          'доступ и привязать новое устройство. Запиши её на бумаге и никому '
          'не показывай — кто знает фразу, тот может войти.',
    ],
    [
      'Я сменил телефон — как восстановить переписку?',
      'Установи приложение на новом телефоне и войди, используя свою '
          'ключ-фразу (seed). После входа новое устройство получит ключи и '
          'сможет читать сообщения. Если фразы нет — восстановить старую '
          'переписку не получится.',
    ],
    [
      'Кто видит мои сообщения?',
      'В E2EE-чате с человеком содержимое могут прочитать только участники '
          'на своих устройствах. В чатах с ботами, в том числе с @support, '
          'сообщение передаётся боту как обычный текст и может быть доступно '
          'операторам поддержки. Не отправляй туда пароли, seed-фразы или '
          'приватные ключи.',
    ],
    [
      'Что делать если потерял доступ?',
      'Если помнишь ключ-фразу (seed) — просто войди по ней на любом '
          'устройстве. Если фраза утеряна и телефона под рукой нет, '
          'восстановить аккаунт нельзя: это плата за то, что доступ есть '
          'только у тебя. Напиши в поддержку — подскажем, что ещё можно сделать.',
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return MeshBackground(child: _scaffold(context));
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(showBack: true, titleText: 'Поддержка'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 60),
        children: [
          _intro(),
          const SizedBox(height: 14),
          _sectionTitle('Быстрые ответы'),
          GlassCard(
            isListSection: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < _faq.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 0.5,
                      color: GE.glassBorder,
                      indent: 14,
                      endIndent: 14,
                    ),
                  _FaqTile(question: _faq[i][0], answer: _faq[i][1]),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle('Связаться'),
          _contactCard(context),
        ],
      ),
    );
  }

  Widget _intro() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.support_agent, color: GE.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Коротко о главном: шифрование, ключ-фраза, смена телефона и '
              'приватность. Если не нашёл ответ — напиши нам.',
              style: TextStyle(color: GE.sub, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _contactCard(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: GE.primary.withValues(alpha: 0.18),
                  border: ThemeService.isMinimal
                      ? null
                      : Border.all(color: GE.primary, width: 1),
                ),
                child: Icon(CupertinoIcons.at, color: GE.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Чат поддержки',
                      style: TextStyle(
                        color: GE.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _supportHandle,
                      style: TextStyle(color: GE.sub, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(CupertinoIcons.doc_on_doc, color: GE.sub, size: 18),
                tooltip: 'Скопировать',
                onPressed: () {
                  Clipboard.setData(const ClipboardData(text: _supportHandle));
                  _snack('Скопировано');
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.30)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_open, color: Colors.orange, size: 18),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Чат с @support не защищён сквозным шифрованием: '
                    'сообщения получает бот и они могут быть доступны '
                    'операторам поддержки. Не отправляй пароли, seed-фразу '
                    'или приватные ключи.',
                    style: TextStyle(color: GE.text, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          GlassButton(
            label: 'Написать в поддержку',
            icon: CupertinoIcons.chat_bubble_2,
            fullWidth: true,
            onTap: () => _openChat(context),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
    child: Text(
      t.toUpperCase(),
      style: TextStyle(
        color: GE.sub,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    ),
  );

  void _snack(String msg) => toast.show(msg);

  void _openChat(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ChatScreen(
          peer: _supportUsername,
          displayName: 'Поддержка GhostChat',
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// Один раскрывающийся вопрос. Theme-override убирает дефолтный делитель
// ExpansionTile и красит иконку/текст под тёмное стекло.
class _FaqTile extends StatelessWidget {
  final String question;
  final String answer;
  const _FaqTile({required this.question, required this.answer});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        listTileTheme: ListTileThemeData(iconColor: GE.primary),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        expandedAlignment: Alignment.centerLeft,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        iconColor: GE.primary,
        collapsedIconColor: GE.sub,
        leading: Icon(
          CupertinoIcons.question_circle,
          color: GE.primary,
          size: 20,
        ),
        title: Text(
          question,
          style: TextStyle(
            color: GE.text,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        children: [
          Text(
            answer,
            style: TextStyle(color: GE.sub, fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }
}
