import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/screens/contacts_screen.dart';
import 'package:ghost/services/contact_service.dart';
import 'package:ghost/services/search_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeContactApi implements ContactApi {
  final List<Map<String, dynamic>> rows = [];
  @override
  Future<dynamic> get(String path) async => rows;

  @override
  Future<dynamic> post(String path) async {
    final username = path.split('/').last;
    rows.add({'username': username, 'display_name': 'New friend'});
    return {'username': username, 'display_name': 'New friend'};
  }

  @override
  Future<dynamic> delete(String path) async => {'status': 'ok'};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('contacts show a real people search and add action', (
    tester,
  ) async {
    final service = ContactService(api: _FakeContactApi());
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsScreen(
          service: service,
          currentUsername: () async => 'me',
          searchUsers: (query) async => [
            FoundUser(username: 'newfriend', displayName: 'New friend'),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Контакты'), findsOneWidget);
    expect(find.text('Пока здесь тихо'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '@newfriend');
    await tester.pump(const Duration(milliseconds: 360));
    await tester.pump();

    expect(find.text('New friend'), findsOneWidget);
    final addButton = find.byTooltip('Добавить в контакты');
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    expect(find.text('Добавлен'), findsOneWidget);
  });
}
