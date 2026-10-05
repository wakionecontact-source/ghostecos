import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/shared/utils/validators.dart';

void main() {
  test('краевые пробелы допустимы и нормализуются отдельно', () {
    expect(Validators.username('   Alice_01   '), isNull);
    expect(Validators.normalizeUsername('   Alice_01   '), 'alice_01');
  });

  test('внутренний пробел остаётся ошибкой', () {
    expect(Validators.username('alice 01'), isNotNull);
  });
}
