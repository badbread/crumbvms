// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Launch-time resume of the stored session (D2): an unreachable server must
// never drop the wall to the login form, only a 401 does.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/session/session_resume.dart';
import 'package:crumb_desktop/ui/waiting_for_server_screen.dart';

final _session = Session(base: 'http://192.0.2.10:8080', token: 't');
Duration _noDelay(int attempt) => Duration.zero;

class _NetworkDown implements Exception {
  const _NetworkDown();
}

void main() {
  test('network errors never reject: keeps retrying until the server answers',
      () async {
    var calls = 0;
    int? waitingAt;
    var waitingCalls = 0;
    final result = await resumeStoredSession(
      session: _session,
      fetchCameras: (s) async {
        calls++;
        if (calls <= 40) throw TimeoutException('server still booting');
        return const <Camera>[];
      },
      isActive: () => true,
      onWaiting: (n) {
        waitingCalls++;
        waitingAt = n;
      },
      delay: _noDelay,
    );
    expect(result.outcome, ResumeOutcome.resumed);
    expect(calls, 41);
    expect(waitingCalls, 1, reason: 'the waiting state is announced once');
    expect(waitingAt, kResumeQuickAttempts);
  });

  test('5xx is transient, 401 is the only thing that rejects', () async {
    var calls = 0;
    final result = await resumeStoredSession(
      session: _session,
      fetchCameras: (s) async {
        calls++;
        if (calls < 3) {
          throw CrumbApiException('boom', statusCode: 503);
        }
        throw CrumbApiException('nope', statusCode: 401);
      },
      isActive: () => true,
      delay: _noDelay,
    );
    expect(result.outcome, ResumeOutcome.rejected);
    expect(calls, 3);
  });

  test('stops without touching the session once abandoned', () async {
    var active = true;
    var calls = 0;
    final result = await resumeStoredSession(
      session: _session,
      fetchCameras: (s) async {
        calls++;
        if (calls == 3) active = false; // operator chose another user
        throw const _NetworkDown();
      },
      isActive: () => active,
      delay: _noDelay,
    );
    expect(result.outcome, ResumeOutcome.abandoned);
    expect(calls, 3);
  });

  test('backoff is capped at 60 s', () {
    expect(defaultResumeDelay(0), const Duration(milliseconds: 1500));
    expect(defaultResumeDelay(3), const Duration(milliseconds: 6000));
    expect(defaultResumeDelay(100), kResumeMaxDelay);
  });

  testWidgets('waiting screen names the server and offers the escape hatch',
      (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WaitingForServerScreen(
          hostLabel: WaitingForServerScreen.hostLabelFor(_session.base),
          onSignInAsSomeoneElse: () => tapped++,
        ),
      ),
    );
    expect(
      find.text('Waiting for server at 192.0.2.10:8080...'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('sign-in-as-someone-else')));
    expect(tapped, 1);
  });
}
