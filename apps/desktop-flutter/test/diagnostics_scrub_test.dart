// The scrub is the load-bearing part of Diagnostics (#180): a leaky "share my
// logs" button would be worse than none. These tests pin every redaction shape.

import 'package:crumb_desktop/services/diagnostics_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const scrub = DiagnosticsService.scrub;

  test('JWT-shaped triplets are redacted wherever they appear', () {
    const jwt =
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG1pbiIsImV4cCI6MTcwMDAwMDAwMH0.'
        'sZ4x8jkeeQm1qX0dPLYc2vT5nJH3wQ9yUabcdEfGhIj';
    final out = scrub('opened http://host:8080/media/x.mp4 with $jwt trailing');
    expect(out, isNot(contains('eyJ')));
    expect(out, contains('[REDACTED-JWT]'));
  });

  test('Authorization bearer values are redacted', () {
    final out = scrub('header authorization: Bearer abc.def-123_456 sent');
    expect(out, isNot(contains('abc.def-123_456')));
    expect(out, contains('Bearer [REDACTED]'));
  });

  test('token/password/secret query params are redacted, key preserved', () {
    final out = scrub(
      'GET /media/seg.mp4?token=sekrit123&start=5 and password=hunter2 done',
    );
    expect(out, isNot(contains('sekrit123')));
    expect(out, isNot(contains('hunter2')));
    expect(out, contains('token=[REDACTED]'));
    expect(out, contains('password=[REDACTED]'));
    expect(out, contains('start=5'), reason: 'non-secret params survive');
  });

  test('JSON secret fields are redacted, key preserved', () {
    final out = scrub(
      '{"username":"admin","password":"pw123","token":"tok456"}',
    );
    expect(out, isNot(contains('pw123')));
    expect(out, isNot(contains('tok456')));
    expect(out, contains('"password":"[REDACTED]"'));
    expect(out, contains('"token":"[REDACTED]"'));
    expect(out, contains('"username":"admin"'), reason: 'non-secrets survive');
  });

  test('RTSP/URL userinfo credentials are redacted (any case, @ in password)', () {
    // The load-bearing case: mpv/ffmpeg echo the full go2rtc restream URL, which
    // embeds user:pass@ — it must never reach the exported log.
    // ignore: this is a fabricated test credential, not a real one
    final lower = scrub('Playing: rtsp://cam:s3cret@192.0.2.6:554/stream1'); // gitleaks:allow
    expect(lower, isNot(contains('s3cret')));
    expect(lower, contains('rtsp://[REDACTED]@192.0.2.6:554/stream1'));

    // Uppercase scheme is still caught (regex is case-insensitive).
    final upper = scrub('RTSP://user:pass@host:8554/cam failed'); // gitleaks:allow
    expect(upper, isNot(contains('pass')));
    expect(upper, contains('[REDACTED]@host:8554'));

    // A password containing '@' is fully redacted (greedy to the LAST @).
    final atPw = scrub('open rtsp://user:p@ss@host/stream refused'); // gitleaks:allow
    expect(atPw, isNot(contains('p@ss')));
    expect(atPw, isNot(contains('ss@host')));
    expect(atPw, contains('rtsp://[REDACTED]@host/stream'));

    // No userinfo → nothing redacted; a later '@' in the path/query is not swallowed.
    const clean = 'GET http://host:8080/media/x.mp4?to=a@b done';
    expect(scrub(clean), clean);
  });

  test('ordinary log lines pass through untouched', () {
    const line = 'GET /cameras → 200 (41ms)';
    expect(scrub(line), line);
  });
}
