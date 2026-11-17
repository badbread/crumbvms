// The login form reopens with the last server address and username filled in
// (sign-out, expired session, restart), and never with a password.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/ui/login_screen.dart';

class _FakeApi extends CrumbApi {
  @override
  Future<Session> login(
    String base,
    String username,
    String password, {
    bool remember = true,
  }) async => Session(base: 'http://nvr.example:8080', token: 't');

  @override
  Future<List<Camera>> listCameras(Session s) async => const [];
}

String _fieldText(WidgetTester tester, String label) => tester
    .widget<TextField>(find.widgetWithText(TextField, label))
    .controller!
    .text;

void main() {
  testWidgets('a successful sign-in is remembered for the next login form', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var loggedIn = false;
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(api: _FakeApi(), onLoggedIn: (_, _) => loggedIn = true),
      ),
    );
    await tester.pumpAndSettle();
    expect(_fieldText(tester, 'Server URL'), isEmpty);

    await tester.enterText(
      find.widgetWithText(TextField, 'Server URL'),
      'nvr.example:8080/',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'pat ');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(loggedIn, isTrue);

    // Signed out: a fresh login form opens prefilled, password blank.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(home: LoginScreen(api: _FakeApi(), onLoggedIn: (_, _) {})),
    );
    await tester.pumpAndSettle();
    expect(_fieldText(tester, 'Server URL'), 'http://nvr.example:8080');
    expect(_fieldText(tester, 'Username'), 'pat');
    expect(_fieldText(tester, 'Password'), isEmpty);
  });
}
