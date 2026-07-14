// Shared HTTP client with a request timeout for the whole desktop API layer.
//
// Every outbound Crumb API call must be bounded: a wedged server (or a dropped
// connection that never RSTs) used to hang login, thumbnail fetches, plate
// lookups, and the report screen indefinitely because none of the scattered
// `http.get`/`http.post` call sites set a timeout. See issue #129.
//
// [TimeoutClient] wraps any `http.Client` and applies [kHttpTimeout] to each
// request. On timeout it throws a [TimeoutException] (which `implements
// Exception`), so existing `try/catch` callers surface it as a normal failure
// instead of a hang.

import 'dart:async';

import 'package:http/http.dart' as http;

/// Per-request budget for every desktop API call. Long enough to ride out a
/// briefly slow LAN server, short enough that a wedged request fails fast
/// instead of freezing the UI.
const Duration kHttpTimeout = Duration(seconds: 12);

/// An [http.Client] that bounds every request with [timeout]. Wrap a real
/// client with this and use it exactly like a normal client; the timeout
/// applies to obtaining the response, and a stalled request throws
/// [TimeoutException] rather than hanging forever.
class TimeoutClient extends http.BaseClient {
  TimeoutClient({http.Client? inner, this.timeout = kHttpTimeout})
    : _inner = inner ?? http.Client();

  final http.Client _inner;
  final Duration timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request).timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Request to ${request.url} timed out',
        timeout,
      ),
    );
  }

  @override
  void close() => _inner.close();
}

/// Process-wide shared timeout client for the API files that previously called
/// the top-level `http.get`/`http.post`/`http.delete`/`http.put` helpers (which
/// have no timeout). Route those calls through this instead.
final http.Client sharedHttpClient = TimeoutClient();
