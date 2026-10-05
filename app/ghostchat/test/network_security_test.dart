import 'package:flutter_test/flutter_test.dart';

import 'package:ghost/theme.dart';

void main() {
  test('production API and WebSocket use encrypted transports', () {
    expect(Uri.parse(GE.apiChat).scheme, 'https');
    expect(Uri.parse(GE.apiSoc).scheme, 'https');
    expect(Uri.parse(GE.apiCore).scheme, 'https');
    expect(Uri.parse(GE.apiBots).scheme, 'https');
    expect(Uri.parse(GE.wsUrl).scheme, 'wss');
  });
}
