// SupportScreen — экран «Поддержка». Простые ответы на частые вопросы
// (шифрование, seed-фраза, смена телефона, приватность, потеря доступа) +
// карточка «Связаться» с контактом @ghostchatof.
//
// Чистый UI: ничего не грузит с сервера, кнопка «Открыть канал» пока
// показывает SnackBar «Скоро» (реального перехода нет).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../mesh_background.dart';
import '../services/theme_service.dart';
import '../widgets/glass.dart';
import '../widgets/toast_overlay.dart';

class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  // Контакт поддержки. Менять тут, если username сменится.
  static const _supportHandle = '@waki_one';

  // Список вопрос → ответ. Простым языком, термины в скобках.
  static const List<List<String>> _faq = [
    [
      'Как работает шифрование?',
      'Сообщения шифруются прямо на твоём телефоне и расшифровываются только '
          'на телефоне собеседника (это называется сквозное шифрование, E2E). '
          'По дороге, даже на наших серверах, текст выглядит как набор '
          'нечитаемых символов.',
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
      'Только ты и твой собеседник. Мы не можем прочитать переписку, потому '
          'что у нас нет ключей для расшифровки. Поэтому береги телефон и '
          'ключ-фразу — это единственный способ попасть в твой аккаунт.',
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
                child: Icon(Icons.alternate_email, color: GE.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Канал поддержки',
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
                icon: Icon(Icons.copy_outlined, color: GE.sub, size: 18),
                tooltip: 'Скопировать',
                onPressed: () {
                  Clipboard.setData(
                    const ClipboardData(text: _supportHandle),
                  );
                  _snack('Скопировано');
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          GlassButton(
            label: 'Открыть канал',
            icon: Icons.open_in_new,
            fullWidth: true,
            onTap: () => _openChannel(),
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

  Future<void> _openChannel() async {
    final uri = Uri.parse('https://t.me/waki_one');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      toast.show('Не удалось открыть ссылку');
    }
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
        leading: Icon(Icons.help_outline, color: GE.primary, size: 20),
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
