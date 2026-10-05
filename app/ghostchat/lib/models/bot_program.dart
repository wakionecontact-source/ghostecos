class BotCommandRule {
  final String command;
  final String description;
  final String response;

  const BotCommandRule({
    required this.command,
    required this.description,
    required this.response,
  });

  factory BotCommandRule.fromDynamic(dynamic value) {
    if (value is! Map) throw const FormatException('Некорректная команда бота');
    return BotCommandRule(
      command: value['command'] as String? ?? '',
      description: value['description'] as String? ?? '',
      response: value['response'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'command': command.trim().toLowerCase(),
    'description': description.trim(),
    'response': response.trim(),
  };

  String? validate() {
    final normalized = command.trim().toLowerCase();
    if (!RegExp(r'^/[a-z][a-z0-9_]{0,31}$').hasMatch(normalized)) {
      return 'Команда: /start, латиница, цифры и _';
    }
    if (description.trim().isEmpty || description.trim().length > 64) {
      return 'Описание должно быть от 1 до 64 символов';
    }
    if (response.trim().isEmpty || response.trim().length > 4000) {
      return 'Ответ должен быть от 1 до 4000 символов';
    }
    return null;
  }
}

class BotProgram {
  final List<BotCommandRule> commands;
  final String fallback;

  const BotProgram({this.commands = const [], this.fallback = ''});

  factory BotProgram.fromDynamic(dynamic value) {
    if (value is! Map || value['version'] != 1 || value['commands'] is! List) {
      throw const FormatException('Неизвестный формат программы бота');
    }
    final commands = (value['commands'] as List)
        .map(BotCommandRule.fromDynamic)
        .toList(growable: false);
    final fallback = value['fallback'];
    if (fallback != null && fallback is! String) {
      throw const FormatException('Некорректный резервный ответ');
    }
    return BotProgram(commands: commands, fallback: fallback as String? ?? '');
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'commands': commands.map((command) => command.toJson()).toList(),
    'fallback': fallback.trim(),
  };

  List<String> validate() {
    final errors = <String>[];
    if (commands.length > 50) errors.add('Можно добавить не больше 50 команд');
    final seen = <String>{};
    for (var i = 0; i < commands.length; i++) {
      final command = commands[i];
      final error = command.validate();
      if (error != null) {
        errors.add(
          '${command.command.isEmpty ? 'Команда ${i + 1}' : command.command}: $error',
        );
      }
      final name = command.command.trim().toLowerCase();
      if (!seen.add(name)) {
        errors.add('Команда $name повторяется');
      }
    }
    if (fallback.length > 4000) {
      errors.add('Резервный ответ длиннее 4000 символов');
    }
    return errors;
  }

  bool get canStart => commands.isNotEmpty || fallback.trim().isNotEmpty;
}
