// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A playlist advance is only adopted as the prefetched segment when mpv
// actually moved onto that file (the stale-prefetch "video jumps after a
// scrub" fix in gapless_segment_pane_controller.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:crumb_desktop/ui/playback/gapless_segment_pane_controller.dart';

void main() {
  const a = 'http://10.0.0.5:8080/media/segments/aaa.mp4?token=one'; // gitleaks:allow
  const b = 'http://10.0.0.5:8080/media/segments/bbb.mp4?token=two'; // gitleaks:allow
  final pl = Playlist([Media(a), Media(b)], index: 1);

  test('matches the same file', () {
    expect(playlistEntryIs(pl, 1, b), isTrue);
  });

  test('ignores a different token on the same file', () {
    expect(
      playlistEntryIs(
        pl,
        1,
        'http://10.0.0.5:8080/media/segments/bbb.mp4?token=refreshed', // gitleaks:allow
      ),
      isTrue,
    );
  });

  test('a stale file in that slot does not match', () {
    expect(playlistEntryIs(pl, 1, a), isFalse);
  });

  test('nothing prefetched, or an index out of range, never matches', () {
    expect(playlistEntryIs(pl, 1, null), isFalse);
    expect(playlistEntryIs(pl, 5, b), isFalse);
    expect(playlistEntryIs(pl, -1, b), isFalse);
  });
}
