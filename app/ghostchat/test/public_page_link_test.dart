import 'package:flutter_test/flutter_test.dart';
import 'package:ghost/services/public_page_link.dart';

void main() {
  test('legal pages are treated as public pages', () {
    expect(
      PublicPageLink.parse('https://ghostecos.duckdns.org/terms')?.path,
      equals('/terms'),
    );
    expect(
      PublicPageLink.parse('https://ghostecos.duckdns.org/privacy')?.path,
      equals('/privacy'),
    );
    expect(
      PublicPageLink.parse('https://ghostecos.duckdns.org/g/1')?.path,
      equals('/g/1'),
    );
  });

  test('private and API paths remain blocked', () {
    expect(
      PublicPageLink.parse('https://ghostecos.duckdns.org/api/chat'),
      isNull,
    );
    expect(
      PublicPageLink.parse('https://ghostecos.duckdns.org/download/app.apk'),
      isNull,
    );
  });
}
