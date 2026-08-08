// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Regression test for "maximized live camera drops back to the wall after a
// window minimize→restore".
//
// A camera maximized on the live wall (full-pane, not OS fullscreen) was lost
// when the window was minimized and restored: the minimize placeholder swap
// (#91) tears the wall down and restore rebuilds it with fresh players, so the
// new State started with nothing maximized and showed the grid. The fix carries
// the maximized camera id across that rebuild and re-applies it in the wall's
// initState via `resolveInitialMaximize`.
//
// The window-event delivery that feeds the id is platform-specific and needs
// on-hardware verification; this covers the pure re-apply DECISION headlessly:
// a stored id whose camera is still present ⇒ maximize it; id null or the
// camera gone (removed/disabled while minimized) ⇒ stay on the grid.

import 'package:flutter_test/flutter_test.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/ui/wall_screen.dart';

Camera _cam(String id, {bool enabled = true}) => Camera(
      id: id,
      name: 'Camera $id',
      enabled: enabled,
      hasSub: true,
      ptz: false,
      servedBy: 'crumb',
    );

void main() {
  group('resolveInitialMaximize (minimize→restore re-maximize decision)', () {
    final shown = [_cam('a'), _cam('b'), _cam('c')];

    test('stored id present in the shown list ⇒ maximize that camera', () {
      final cam = resolveInitialMaximize('b', shown);
      expect(cam, isNotNull);
      expect(cam!.id, 'b');
    });

    test('null id (nothing was maximized) ⇒ stay on the grid', () {
      expect(resolveInitialMaximize(null, shown), isNull);
    });

    test('camera removed while minimized ⇒ stay on the grid', () {
      expect(resolveInitialMaximize('gone', shown), isNull);
    });

    test('camera disabled while minimized (not in shown) ⇒ stay on grid', () {
      // The wall's `_shown` already filters to enabled cameras, so a disabled
      // camera simply isn't in the list passed here.
      final onlyEnabled =
          shown.where((c) => c.enabled).toList(growable: false);
      expect(resolveInitialMaximize('a', onlyEnabled), isNotNull);
      // Same list with 'a' disabled+filtered out ⇒ no match.
      final withoutA = [_cam('b'), _cam('c')];
      expect(resolveInitialMaximize('a', withoutA), isNull);
    });

    test('empty shown list ⇒ stay on the grid', () {
      expect(resolveInitialMaximize('a', const []), isNull);
    });
  });
}
