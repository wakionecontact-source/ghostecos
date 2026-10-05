import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/models/bot_program.dart';

void main() {
  test('program round-trips builder commands with the Python SDK schema', () {
    const program = BotProgram(
      commands: [
        BotCommandRule(
          command: '/start',
          description: 'Начать',
          response: 'Привет!',
        ),
      ],
      fallback: 'Напиши /help',
    );

    expect(BotProgram.fromDynamic(program.toJson()).toJson(), program.toJson());
  });

  test('program rejects malformed, duplicate, and oversized command data', () {
    const invalid = BotProgram(
      commands: [
        BotCommandRule(command: 'start', description: '', response: ''),
        BotCommandRule(command: '/start', description: 'Начать', response: 'x'),
        BotCommandRule(command: '/start', description: 'Повтор', response: 'y'),
      ],
    );

    expect(invalid.validate(), isNotEmpty);
    expect(invalid.canStart, isTrue);
  });

  test('empty program is not launchable', () {
    const program = BotProgram();
    expect(program.canStart, isFalse);
    expect(program.validate(), isEmpty);
  });
}
