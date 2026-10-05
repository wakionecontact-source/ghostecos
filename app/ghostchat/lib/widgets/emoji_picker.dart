// Эмодзи-пикер: категории + поиск. Открывается из композера, вставляет эмодзи
// в поле ввода (и используется для реакций). Системный глиф рендерит сама ОС;
// здесь — удобная сетка с вкладками-категориями и поиском по ключевым словам.
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import '../theme.dart';
import 'emoji_text.dart';

class _EmojiCat {
  final IconData icon;
  final String title;
  final List<String> emojis;
  const _EmojiCat(this.icon, this.title, this.emojis);
}

const List<_EmojiCat> _cats = [
  _EmojiCat(CupertinoIcons.smiley, 'Смайлы', [
    '😀','😃','😄','😁','😆','😅','😂','🤣','😊','😇','🙂','🙃','😉','😌','😍',
    '🥰','😘','😋','😛','😜','🤪','😎','🥳','🤩','😏','😒','😞','😔','😟','😕',
    '🙁','😣','😖','😫','😩','🥺','😢','😭','😤','😠','😡','🤬','🤯','😳','🥵',
    '🥶','😱','😨','😰','😥','😓','🤔','🤫','🤭','😴','😪','🤤','😷','🤒','🤕',
    '🤢','🤮','🥴','😵','🤐','🥱','😬','🤥','😈','👻','💀','🤡','👽','🤖',
  ]),
  _EmojiCat(CupertinoIcons.hand_raised, 'Жесты', [
    '👍','👎','👌','✌️','🤞','🤟','🤘','🤙','👈','👉','👆','👇','☝️','✋','🤚',
    '🖐️','🖖','👋','🤝','🙏','✊','👊','🤛','🤜','👏','🙌','👐','🤲','💪','🦾',
    '🤳','💅','🤌','🤏',
  ]),
  _EmojiCat(CupertinoIcons.heart_fill, 'Любовь', [
    '❤️','🧡','💛','💚','💙','💜','🖤','🤍','🤎','💔','❤️‍🔥','💕','💞','💓','💗',
    '💖','💘','💝','💟','😍','🥰','😘','💋','💌',
  ]),
  _EmojiCat(CupertinoIcons.paw, 'Животные', [
    '🐶','🐱','🐭','🐹','🐰','🦊','🐻','🐼','🐨','🐯','🦁','🐮','🐷','🐸','🐵',
    '🐔','🐧','🐦','🐤','🦆','🦅','🦉','🦇','🐺','🐗','🐴','🦄','🐝','🐛','🦋',
    '🐌','🐞','🐢','🐍','🐙','🦑','🦀','🐠','🐟','🐬','🐳','🐋','🦈','🌸','🌹',
    '🌻','🌼','🌷','🌳','🌲','🌵','🍀',
  ]),
  _EmojiCat(Icons.restaurant, 'Еда', [
    '🍎','🍐','🍊','🍋','🍌','🍉','🍇','🍓','🫐','🍒','🍑','🥭','🍍','🥥','🥝',
    '🍅','🥑','🥦','🌽','🥕','🍔','🍟','🍕','🌭','🥪','🌮','🌯','🍿','🍩','🍪',
    '🎂','🍰','🧁','🍫','🍬','🍭','🍦','☕','🍵','🍺','🍷','🥂','🍸','🥤',
  ]),
  _EmojiCat(CupertinoIcons.gamecontroller_fill, 'Развлечения', [
    '⚽','🏀','🏈','⚾','🎾','🏐','🏉','🎱','🏓','🏸','⛳','🏹','🎣','🥊','⛸️',
    '🎿','🏂','🏋️','🚴','🏆','🥇','🥈','🥉','🎮','🎲','🎯','🎸','🎺','🎻','🎤',
    '🎧','🎬','🎨','🎭',
  ]),
  _EmojiCat(CupertinoIcons.airplane, 'Путешествия', [
    '🚗','🚕','🚙','🚌','🏎️','🚓','🚑','🚒','🚚','🏍️','🚲','✈️','🚀','🚁','⛵',
    '🚤','🚢','🗺️','🗽','🗼','🏰','🎡','🎢','🏖️','🏝️','🏔️','⛰️','🌋','🏕️','🏙️',
  ]),
  _EmojiCat(CupertinoIcons.lightbulb, 'Объекты', [
    '⌚','📱','💻','⌨️','🖥️','🖨️','💽','💾','📷','📸','🎥','📞','📺','📻','⏰',
    '⏳','📡','🔋','🔌','💡','🔦','📚','📖','✏️','📝','📌','📎','🔒','🔑','🔨',
    '🛠️','🔭','🔬','💉','💊','🛒','🎁','🎈','🎉','🎊',
  ]),
  _EmojiCat(CupertinoIcons.tag, 'Символы', [
    '✅','❌','❓','❗','💯','🔥','⭐','🌟','✨','⚡','☀️','🌙','🌈','❄️','💧',
    '🌊','🎵','🎶','➕','➖','✔️','♻️','⚠️','🚫','🆗','🆕','💤','💬','🔔','🔕',
    '☑️','🔝','💢','💥',
  ]),
];

// Ключевые слова для поиска (рус) — для самых ходовых; остальное ищется по
// вкладкам. Эмодзи без ключа в поиск не попадёт (это ок).
const Map<String, String> _kw = {
  '😀': 'улыбка смех радость', '😂': 'смех слёзы ржу', '🤣': 'ржу смех угар',
  '😊': 'улыбка мило', '😍': 'влюблён любовь глаза', '🥰': 'влюблён мило сердечки',
  '😘': 'поцелуй чмок', '😎': 'крутой очки', '🥳': 'праздник вечеринка',
  '😭': 'плач рыдаю слёзы', '😡': 'злость гнев бесит', '🤔': 'думаю мысль',
  '😴': 'сон спать', '😱': 'шок страх ужас', '🤯': 'взрыв мозга шок',
  '👍': 'класс палец вверх лайк ок', '👎': 'дизлайк плохо', '👌': 'окей ок отлично',
  '🙏': 'спасибо молитва прошу', '👏': 'апло хлопки браво', '💪': 'сила мышцы',
  '🔥': 'огонь жара круто', '❤️': 'сердце любовь', '💔': 'разбитое сердце',
  '✅': 'галочка готово ок', '❌': 'крест нет ошибка', '💯': 'сотка топ',
  '⭐': 'звезда', '🎉': 'праздник салют', '🎁': 'подарок', '💬': 'сообщение чат',
  '🚀': 'ракета запуск', '🐶': 'собака пёс', '🐱': 'кот кошка', '🍕': 'пицца еда',
  '☕': 'кофе', '🍺': 'пиво', '🎮': 'игра геймпад', '✈️': 'самолёт полёт',
  '💡': 'идея лампа', '🔒': 'замок защита', '🔑': 'ключ',
};

class EmojiPicker extends StatefulWidget {
  final ValueChanged<String> onPick;
  const EmojiPicker({super.key, required this.onPick});

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<EmojiPicker> {
  int _cat = 0;
  String _q = '';

  List<String> get _shown {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return _cats[_cat].emojis;
    final out = <String>[];
    for (final c in _cats) {
      for (final e in c.emojis) {
        final kw = _kw[e];
        if (kw != null && kw.contains(q) && !out.contains(e)) out.add(e);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    // Высоту задаёт родитель (инлайн-панель в чате — Positioned height).
    return Container(
      decoration: BoxDecoration(
        color: GE.bgDeep.withValues(alpha: 0.98),
        border: Border(top: BorderSide(color: GE.glassBorder)),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: GE.glassBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Поиск
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              style: TextStyle(color: GE.text, fontSize: 14),
              cursorColor: GE.primary,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Поиск эмодзи',
                hintStyle: TextStyle(color: GE.sub, fontSize: 14),
                prefixIcon: Icon(CupertinoIcons.search, color: GE.sub, size: 20),
                filled: true,
                fillColor: GE.glassFill,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: GE.glassBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: GE.glassBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: GE.primary),
                ),
              ),
            ),
          ),
          // Сетка эмодзи
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text(
                      'Ничего не найдено',
                      style: TextStyle(color: GE.sub, fontSize: 13),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 46,
                      mainAxisSpacing: 2,
                      crossAxisSpacing: 2,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (_, i) => InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => widget.onPick(shown[i]),
                      child: Center(
                        child: EmojiText(
                          shown[i],
                          style: const TextStyle(fontSize: 22),
                        ),
                      ),
                    ),
                  ),
          ),
          // Вкладки-категории (скрыты при поиске)
          if (_q.trim().isEmpty)
            Container(
              height: 48,
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: GE.glassBorder)),
              ),
              child: Row(
                children: List.generate(_cats.length, (i) {
                  final sel = i == _cat;
                  return Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _cat = i),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: sel ? GE.primary : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: Icon(
                          _cats[i].icon,
                          size: 20,
                          color: sel ? GE.primary : GE.sub,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          SafeArea(top: false, child: const SizedBox(height: 2)),
        ],
      ),
    );
  }
}
