/// Реестр элементов GhostUI.
///
/// Каждый визуальный элемент приложения обязан быть описан здесь: id, слоты,
/// доступные свойства, привязки к данным. Конфиг, в котором нет элемента из
/// реестра, считается невалидным — это и есть «нет конфига = ошибка».
///
/// `isLocked: true` — элемент нельзя оформлять расширениями (ключи, 2FA,
/// системные диалоги). Такие элементы исключены из проверки покрытия.
library;

enum UiPropType { color, number, boolean, text, radiusStep, choice }

class UiPropSpec {
  const UiPropSpec({
    required this.type,
    this.required = false,
    this.min,
    this.max,
    this.choices,
    this.defaultValue,
  });

  final UiPropType type;
  final bool required;
  final num? min;
  final num? max;
  final List<String>? choices;

  /// Значение по умолчанию в «сыром» виде: `token:accent`, `#RRGGBB`, число,
  /// bool, строка. Резолвится при разборе конфига.
  final Object? defaultValue;
}

class UiElementSpec {
  const UiElementSpec({
    required this.id,
    required this.title,
    this.props = const <String, UiPropSpec>{},
    this.slots = const <String>[],
    this.bindings = const <String>[],
    this.allowedAreas = const <String>[],
    this.editable = const <String>[],
    this.locked = const <String>[],
    this.isLocked = false,
  });

  final String id;
  final String title;
  final Map<String, UiPropSpec> props;
  final List<String> slots;
  final List<String> bindings;
  final List<String> allowedAreas;
  final List<String> editable;
  final List<String> locked;
  final bool isLocked;
}

class UiRegistry {
  UiRegistry._();

  static final UiRegistry instance = UiRegistry._();

  static const UiPropSpec _color = UiPropSpec(type: UiPropType.color);
  static const UiPropSpec _radius = UiPropSpec(
    type: UiPropType.radiusStep,
    defaultValue: 'm',
  );

  final Map<String, UiElementSpec> elements = const <String, UiElementSpec>{
    'nav.bar': UiElementSpec(
      id: 'nav.bar',
      title: 'Нижняя навигация',
      props: <String, UiPropSpec>{
        'background': _color,
        'height': UiPropSpec(
          type: UiPropType.number,
          min: 48,
          max: 96,
          defaultValue: 64,
        ),
        'radius': UiPropSpec(
          type: UiPropType.radiusStep,
          defaultValue: 'l',
        ),
        'selectedBackground': _color,
        'icon': _color,
        'label': _color,
        'labels': UiPropSpec(type: UiPropType.boolean, defaultValue: true),
        'position': UiPropSpec(
          type: UiPropType.choice,
          choices: <String>['bottom', 'top'],
          defaultValue: 'bottom',
        ),
      },
      slots: <String>['items'],
      bindings: <String>['nav.activeTab'],
      editable: <String>['height', 'background', 'selectedBackground', 'icon', 'label', 'labels'],
      locked: <String>['targets', 'minimumTapTarget'],
    ),
    'chat.list.row': UiElementSpec(
      id: 'chat.list.row',
      title: 'Строка чата',
      props: <String, UiPropSpec>{
        'background': _color,
        'selectedBackground': _color,
        'unreadBackground': _color,
        'radius': _radius,
        'height': UiPropSpec(
          type: UiPropType.number,
          min: 48,
          max: 96,
          defaultValue: 68,
        ),
        'paddingH': UiPropSpec(type: UiPropType.number, min: 4, max: 24, defaultValue: 10),
        'paddingV': UiPropSpec(type: UiPropType.number, min: 2, max: 16, defaultValue: 6),
        'avatarSize': UiPropSpec(type: UiPropType.number, min: 32, max: 64, defaultValue: 46),
        'title': _color,
        'subtitle': _color,
        'time': _color,
        'badgeBackground': _color,
        'badgeText': _color,
        'avatarSide': UiPropSpec(
          type: UiPropType.choice,
          choices: <String>['left', 'right'],
          defaultValue: 'left',
        ),
      },
      slots: <String>['avatar', 'title', 'subtitle', 'time', 'badge', 'trailing'],
      bindings: <String>['chat.title', 'chat.avatar', 'chat.lastMessage', 'chat.unread', 'chat.time'],
      allowedAreas: <String>['list.main'],
      editable: <String>['height', 'background', 'selectedBackground', 'unreadBackground', 'avatarSize', 'title', 'subtitle', 'time', 'badge', 'avatarSide'],
      locked: <String>['onTap', 'semantics'],
    ),
    'chat.bubble.self': UiElementSpec(
      id: 'chat.bubble.self',
      title: 'Пузырь сообщения (своё)',
      props: <String, UiPropSpec>{
        'background': _color,
        'backgroundTo': _color,
        'text': _color,
        'time': _color,
        'radius': _radius,
        'maxWidth': UiPropSpec(type: UiPropType.number, min: 220, max: 720, defaultValue: 600),
        'paddingH': UiPropSpec(type: UiPropType.number, min: 6, max: 24, defaultValue: 12),
        'paddingV': UiPropSpec(type: UiPropType.number, min: 4, max: 20, defaultValue: 8),
      },
      slots: <String>['content', 'reactions', 'meta'],
      bindings: <String>['message.text', 'message.time', 'message.attachments', 'message.reactions'],
      editable: <String>['background', 'backgroundTo', 'text', 'time', 'maxWidth', 'padding'],
      locked: <String>['actions', 'e2eeMarker'],
    ),
    'chat.bubble.peer': UiElementSpec(
      id: 'chat.bubble.peer',
      title: 'Пузырь сообщения (чужое)',
      props: <String, UiPropSpec>{
        'background': _color,
        'backgroundTo': _color,
        'text': _color,
        'time': _color,
        'radius': _radius,
        'maxWidth': UiPropSpec(type: UiPropType.number, min: 220, max: 720, defaultValue: 600),
        'paddingH': UiPropSpec(type: UiPropType.number, min: 6, max: 24, defaultValue: 12),
        'paddingV': UiPropSpec(type: UiPropType.number, min: 4, max: 20, defaultValue: 8),
      },
      slots: <String>['content', 'reactions', 'meta'],
      bindings: <String>['message.text', 'message.time', 'message.attachments', 'message.reactions'],
      editable: <String>['background', 'text', 'time', 'maxWidth', 'padding'],
      locked: <String>['actions', 'e2eeMarker'],
    ),
    'chat.composer': UiElementSpec(
      id: 'chat.composer',
      title: 'Поле ввода',
      props: <String, UiPropSpec>{
        'background': _color,
        'hint': _color,
        'sendBackground': _color,
        'sendIcon': _color,
        'radius': UiPropSpec(type: UiPropType.radiusStep, defaultValue: 'xl'),
        'height': UiPropSpec(type: UiPropType.number, min: 44, max: 72, defaultValue: 52),
      },
      slots: <String>['attach', 'field', 'emoji', 'send'],
      bindings: <String>['chat.draft'],
      editable: <String>['background', 'hint', 'sendBackground', 'sendIcon', 'height', 'order'],
      locked: <String>['send', 'attachments', 'permissions'],
    ),
    'settings.row': UiElementSpec(
      id: 'settings.row',
      title: 'Строка настроек',
      props: <String, UiPropSpec>{
        'background': _color,
        'title': _color,
        'subtitle': _color,
        'icon': _color,
        'chevron': _color,
        'radius': _radius,
        'height': UiPropSpec(type: UiPropType.number, min: 48, max: 88, defaultValue: 58),
        'paddingH': UiPropSpec(type: UiPropType.number, min: 8, max: 24, defaultValue: 14),
      },
      slots: <String>['icon', 'title', 'subtitle', 'trailing'],
      bindings: <String>['settings.title', 'settings.subtitle'],
      editable: <String>['height', 'background', 'title', 'subtitle', 'icon', 'chevron'],
      locked: <String>['behavior'],
    ),
    'app.bar': UiElementSpec(
      id: 'app.bar',
      title: 'Шапка экрана',
      props: <String, UiPropSpec>{
        'background': _color,
        'title': _color,
        'icon': _color,
        'height': UiPropSpec(type: UiPropType.number, min: 48, max: 80, defaultValue: 56),
        'radius': UiPropSpec(type: UiPropType.radiusStep, defaultValue: 'xs'),
      },
      slots: <String>['leading', 'title', 'actions'],
      bindings: <String>['screen.title'],
      editable: <String>['background', 'title', 'icon', 'height'],
      locked: <String>['navigation'],
    ),

    /// Заблокированные элементы: оформление запрещено на уровне валидатора.
    'auth.key_entry': UiElementSpec(
      id: 'auth.key_entry',
      title: 'Ввод ключа (locked)',
      isLocked: true,
      locked: <String>['*'],
    ),
  };

  Iterable<UiElementSpec> get styleable =>
      elements.values.where((e) => !e.isLocked);

  UiElementSpec? byId(String id) => elements[id];
}
