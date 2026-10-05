import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/contact_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeContactApi implements ContactApi {
  dynamic listResponse = const [];
  dynamic addResponse = const {'status': 'ok'};
  String? lastGet;
  String? lastPost;
  String? lastDelete;

  @override
  Future<dynamic> get(String path) async {
    lastGet = path;
    return listResponse;
  }

  @override
  Future<dynamic> post(String path) async {
    lastPost = path;
    return addResponse;
  }

  @override
  Future<dynamic> delete(String path) async {
    lastDelete = path;
    return const {'status': 'ok'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('contact model tolerates optional profile fields', () {
    final contact = GhostContact.fromJson({'username': 'mira'});

    expect(contact.username, 'mira');
    expect(contact.displayName, 'mira');
    expect(contact.avatarUrl, isNull);
  });

  test('lists server contacts and ignores malformed entries', () async {
    final api = _FakeContactApi()
      ..listResponse = [
        {
          'username': 'mira',
          'display_name': 'Mira',
          'avatar_url': '/media/mira.jpg',
          'added_at': '2026-09-14T10:00:00Z',
        },
        {'display_name': 'Missing username'},
      ];
    final service = ContactService(api: api);

    final contacts = await service.list();

    expect(api.lastGet, '/contacts');
    expect(contacts, hasLength(1));
    expect(contacts.single.displayName, 'Mira');
    expect(contacts.single.avatarUrl, '/media/mira.jpg');
  });

  test('add and remove use authenticated contact endpoints', () async {
    final api = _FakeContactApi()
      ..addResponse = const {
        'status': 'ok',
        'username': 'mira',
        'display_name': 'Mira',
      };
    final service = ContactService(api: api);

    final added = await service.add(
      username: '@mira',
      avatarUrl: '/media/mira.jpg',
    );
    await service.remove('@mira');

    expect(api.lastPost, '/contacts/mira');
    expect(api.lastDelete, '/contacts/mira');
    expect(added.username, 'mira');
    expect(added.displayName, 'Mira');
    expect(added.avatarUrl, '/media/mira.jpg');
  });
}
