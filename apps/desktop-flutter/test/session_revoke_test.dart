// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Sign-out revokes the client's own server-side session (D3).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';

String _b64(Map<String, dynamic> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

String _jwt(Map<String, dynamic> claims) =>
    '${_b64({'alg': 'HS256'})}.${_b64(claims)}.sig';

void main() {
  const jti = '8b1f4c9e-2d37-4a52-9e0a-5f3c7a1d6b20';

  test('sessionIdOf reads the jti claim, tolerates junk', () {
    expect(CrumbApi.sessionIdOf(_jwt({'jti': jti, 'sub': 'u'})), jti);
    expect(CrumbApi.sessionIdOf(_jwt({'sub': 'u'})), isNull);
    expect(CrumbApi.sessionIdOf('not-a-jwt'), isNull);
    expect(CrumbApi.sessionIdOf('a.%%%.c'), isNull);
  });

  test('revokeCurrentSession DELETEs /auth/sessions/:jti with the bearer',
      () async {
    late http.Request seen;
    final api = CrumbApi(
      client: MockClient((req) async {
        seen = req;
        return http.Response('', 204);
      }),
    );
    final token = _jwt({'jti': jti});
    final ok = await api.revokeCurrentSession(
      Session(base: 'http://192.0.2.10:8080', token: token),
    );
    expect(ok, isTrue);
    expect(seen.method, 'DELETE');
    expect(seen.url.path, '/auth/sessions/$jti');
    expect(seen.headers['authorization'], 'Bearer $token');
  });

  test('revokeCurrentSession never throws when the server is unreachable',
      () async {
    final api = CrumbApi(
      client: MockClient((req) async => throw http.ClientException('down')),
    );
    final ok = await api.revokeCurrentSession(
      Session(base: 'http://192.0.2.10:8080', token: _jwt({'jti': jti})),
    );
    expect(ok, isFalse);
  });

  test('a token without a session id sends nothing', () async {
    var calls = 0;
    final api = CrumbApi(
      client: MockClient((req) async {
        calls++;
        return http.Response('', 204);
      }),
    );
    final ok = await api.revokeCurrentSession(
      Session(base: 'http://192.0.2.10:8080', token: 'opaque'),
    );
    expect(ok, isFalse);
    expect(calls, 0);
  });
}
