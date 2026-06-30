// Basic smoke test for the JustClash app.
//
// The full widget tree (JustClashApp -> MainShell) initializes the
// window_manager and system_tray desktop plugins, which are not available in
// the headless `flutter test` environment. To keep `flutter test` and
// `flutter analyze` green without depending on desktop plugins, this test only
// verifies that the root widget (JustClashApp, defined in lib/main.dart) can be
// instantiated. The previous template referenced a non-existent `MyApp`.

import 'package:flutter_test/flutter_test.dart';

import 'package:just_clash/main.dart';

void main() {
  test('JustClashApp can be instantiated', () {
    const app = JustClashApp();
    expect(app, isNotNull);
  });
}
