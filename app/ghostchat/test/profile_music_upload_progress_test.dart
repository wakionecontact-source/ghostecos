import 'package:flutter_test/flutter_test.dart';

import 'package:ghost/screens/profile_music_library_screen.dart';

void main() {
  test('keeps transport progress below 100 until the response arrives', () {
    expect(profileMusicUploadProgress(0, 100), 0);
    expect(profileMusicUploadProgress(50, 100), closeTo(0.47, 0.0001));
    expect(profileMusicUploadProgress(100, 100), 0.94);
  });

  test('clamps invalid and over-reported transport values', () {
    expect(profileMusicUploadProgress(10, 0), 0);
    expect(profileMusicUploadProgress(-1, 100), 0);
    expect(profileMusicUploadProgress(200, 100), 0.94);
  });
}
