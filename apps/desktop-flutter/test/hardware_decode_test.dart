// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "Hardware video decoding" option (#713): default ON, persisted, drives the
// mpv hwdec value; plus the unexpected-exit marker logic.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:crumb_desktop/state/client_options.dart';
import 'package:crumb_desktop/state/hardware_decode.dart';
import 'package:crumb_desktop/state/session_marker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HardwareDecode.enabled.value = true;
  });

  test('hwdecModeFor maps the option to the mpv value', () {
    expect(hwdecModeFor(true), 'auto');
    expect(hwdecModeFor(false), 'no');
  });

  test('defaults to ON and hwdecMode() is auto', () async {
    final o = await ClientOptionsStore.load();
    expect(o.hardwareDecoding, isTrue);
    expect(hwdecMode(), 'auto');
  });

  test('turning it off persists and switches hwdecMode() to no', () async {
    final o = await ClientOptionsStore.load();
    o.hardwareDecoding = false;
    expect(hwdecMode(), 'no');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('crumb.hardwareDecoding'), isFalse);

    HardwareDecode.enabled.value = true;
    final reloaded = await ClientOptionsStore.load();
    expect(reloaded.hardwareDecoding, isFalse);
    expect(hwdecMode(), 'no');
  });

  test('session marker: first run is clean, an unended run is flagged once',
      () async {
    final prefs = await SharedPreferences.getInstance();
    expect(await beginSession(prefs), isFalse); // fresh install
    expect(await beginSession(prefs), isTrue); // never ended: crashed
    expect(await beginSession(prefs), isTrue); // still never ended
    await endSession(prefs);
    expect(await beginSession(prefs), isFalse); // clean exit in between
  });

  test('notice shows only after an unexpected exit with hardware decoding on',
      () {
    expect(
      shouldShowUnexpectedExitNotice(
        previousExitUnexpected: true,
        hardwareDecoding: true,
      ),
      isTrue,
    );
    expect(
      shouldShowUnexpectedExitNotice(
        previousExitUnexpected: true,
        hardwareDecoding: false,
      ),
      isFalse,
    );
    expect(
      shouldShowUnexpectedExitNotice(
        previousExitUnexpected: false,
        hardwareDecoding: true,
      ),
      isFalse,
    );
  });
}
