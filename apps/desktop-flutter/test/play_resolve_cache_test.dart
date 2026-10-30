import 'dart:convert';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/http_client.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/play_resolve_cache.dart';
import 'package:crumb_desktop/api/playback_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _t0 = DateTime.utc(2026, 1, 1, 12);

ResolvedSegment _seg(String cam, String id, int startS, {int lenS = 4}) =>
    ResolvedSegment(
      cameraId: cam,
      segmentId: id,
      url: '/segments/$id',
      start: _t0.add(Duration(seconds: startS)),
      end: _t0.add(Duration(seconds: startS + lenS)),
      durationMs: lenS * 1000,
      hasMotion: false,
    );

DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));

void main() {
  group('PlayResolveCache', () {
    test('any instant inside a cached segment hits; the end is exclusive', () {
      final c = PlayResolveCache();
      final s = _seg('cam', 'a', 0);
      c.put('srv', 'main', s);
      expect(c.lookup('srv', 'cam', 'main', _at(0)), same(s));
      expect(c.lookup('srv', 'cam', 'main', _at(3999)), same(s));
      expect(c.lookup('srv', 'cam', 'main', _at(4000)), isNull);
      expect(c.lookup('srv', 'cam', 'main', _at(-1)), isNull);
    });

    test('scope, camera and stream are all part of the key', () {
      final c = PlayResolveCache();
      c.put('srv|tokA', 'main', _seg('cam', 'a', 0));
      expect(c.lookup('srv|tokB', 'cam', 'main', _at(1000)), isNull);
      expect(c.lookup('srv|tokA', 'other', 'main', _at(1000)), isNull);
      expect(c.lookup('srv|tokA', 'cam', 'sub', _at(1000)), isNull);
      expect(c.lookup('srv|tokA', 'cam', 'main', _at(1000)), isNotNull);
    });

    test('entries expire after the TTL even when read', () {
      var now = DateTime.utc(2026, 1, 1);
      final c = PlayResolveCache(now: () => now);
      c.put('srv', 'main', _seg('cam', 'a', 0));
      now = now.add(kPlayResolveTtl - const Duration(seconds: 1));
      expect(c.lookup('srv', 'cam', 'main', _at(10)), isNotNull);
      now = now.add(const Duration(seconds: 1));
      expect(c.lookup('srv', 'cam', 'main', _at(10)), isNull);
      expect(c.length, 0);
    });

    test('the TTL stays well inside the 15 min media-token lifetime', () {
      expect(kPlayResolveTtl, lessThanOrEqualTo(const Duration(minutes: 1)));
    });

    test('bounded: evicts the least recently used segment', () {
      final c = PlayResolveCache(capacity: 2);
      c.put('srv', 'main', _seg('cam', 'a', 0));
      c.put('srv', 'main', _seg('cam', 'b', 4));
      // Touch a, so b is the LRU one.
      expect(c.lookup('srv', 'cam', 'main', _at(100)), isNotNull);
      c.put('srv', 'main', _seg('cam', 'c', 8));
      expect(c.length, 2);
      expect(c.lookup('srv', 'cam', 'main', _at(4100)), isNull);
      expect(c.lookup('srv', 'cam', 'main', _at(100))!.segmentId, 'a');
      expect(c.lookup('srv', 'cam', 'main', _at(8100))!.segmentId, 'c');
    });

    test('invalidate drops one camera or everything', () {
      final c = PlayResolveCache();
      c.put('srv', 'main', _seg('cam', 'a', 0));
      c.put('srv', 'main', _seg('other', 'b', 0));
      c.invalidate(cameraId: 'cam');
      expect(c.lookup('srv', 'cam', 'main', _at(100)), isNull);
      expect(c.lookup('srv', 'other', 'main', _at(100)), isNotNull);
      c.invalidate();
      expect(c.length, 0);
    });
  });

  group('PlaybackApi.resolveSegment caching', () {
    var calls = 0;
    final session = Session(base: 'http://crumb.test', token: 'tok');

    // `sharedHttpClient` is a lazily initialised top-level whose inner client
    // comes from `http.Client()`, which honours `runWithClient`. Touching it
    // first inside that zone (this test file runs in its own isolate) routes
    // every PlaybackApi call to the fake server below.
    setUpAll(() {
      http.runWithClient(
        () => sharedHttpClient,
        () => MockClient((req) async {
          calls++;
          final ts = DateTime.parse(req.url.queryParameters['ts']!);
          // Footage only in the first minute after _t0, as 4 s segments.
          final off = ts.difference(_t0).inMilliseconds;
          if (off < 0 || off >= 60000) return http.Response('', 404);
          final startS = (off ~/ 4000) * 4;
          final cam = req.url.pathSegments.last;
          return http.Response(
            jsonEncode({
              'camera_id': cam,
              'segment_id': '$cam-$startS',
              'url': '/segments/$cam-$startS',
              'start': _t0.add(Duration(seconds: startS)).toIso8601String(),
              'end': _t0.add(Duration(seconds: startS + 4)).toIso8601String(),
              'duration_ms': 4000,
              'has_motion': false,
            }),
            200,
          );
        }),
      );
    });

    setUp(() {
      calls = 0;
      PlaybackApi.clearTokenCache();
    });

    test(
      'a second resolve inside the same segment skips the round trip',
      () async {
        final api = CrumbApi();
        final a = await api.resolveSegment(session, 'cam', _at(1000));
        final b = await api.resolveSegment(session, 'cam', _at(3500));
        expect(calls, 1);
        expect(b!.segmentId, a!.segmentId);
        // The next segment is a different window: a real resolve.
        final c = await api.resolveSegment(session, 'cam', _at(4001));
        expect(calls, 2);
        expect(c!.segmentId, isNot(a.segmentId));
      },
    );

    test('404s are never cached', () async {
      final api = CrumbApi();
      expect(await api.resolveSegment(session, 'cam', _at(90000)), isNull);
      expect(await api.resolveSegment(session, 'cam', _at(90000)), isNull);
      expect(calls, 2);
    });

    test('bypassCache and invalidation force a server round trip', () async {
      final api = CrumbApi();
      await api.resolveSegment(session, 'cam', _at(1000));
      await api.resolveSegment(session, 'cam', _at(1000), bypassCache: true);
      expect(calls, 2);
      PlaybackApi.invalidateResolveCache(cameraId: 'cam');
      await api.resolveSegment(session, 'cam', _at(1000));
      expect(calls, 3);
      // Signing out clears it too.
      PlaybackApi.clearTokenCache();
      await api.resolveSegment(session, 'cam', _at(1000));
      expect(calls, 4);
    });

    test(
      'a different session never reuses another principal\'s resolve',
      () async {
        final api = CrumbApi();
        await api.resolveSegment(session, 'cam', _at(1000));
        await api.resolveSegment(
          Session(base: 'http://crumb.test', token: 'other'),
          'cam',
          _at(1000),
        );
        expect(calls, 2);
      },
    );
  });
}
