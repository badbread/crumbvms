// Per-camera main/sub stream preference, port of app.js `getStreamPref` /
// `setStreamPref` (apps/desktop/src/app.js:89-91-ish, the `streamPref` map).
// The wall defaults every tile to the light "sub" stream; a tile's context
// menu lets the operator pin it to "main" (full quality) instead. This is
// pure client-side UI state — it does not persist across restarts in the old
// client beyond the in-memory `streamPref` map, so this mirrors that scope.

import 'package:flutter/foundation.dart';

enum StreamKind { main, sub }

extension StreamKindWire on StreamKind {
  String get wire => this == StreamKind.main ? 'main' : 'sub';

  static StreamKind fromWire(String v) =>
      v == 'main' ? StreamKind.main : StreamKind.sub;
}

/// Holds the operator's per-camera main/sub choice for wall tiles. Defaults to
/// [StreamKind.sub] (the wall's low-bandwidth default in the old client —
/// see `wallDefaultStream()` in app.js).
class StreamPrefStore extends ChangeNotifier {
  final Map<String, StreamKind> _prefs = {};

  StreamKind prefFor(String cameraId) => _prefs[cameraId] ?? StreamKind.sub;

  void setPref(String cameraId, StreamKind kind) {
    if (_prefs[cameraId] == kind) return;
    _prefs[cameraId] = kind;
    notifyListeners();
  }
}
