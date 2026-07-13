// Coordinates the "Connecting…" placeholder cascade shown when the Live wall
// (re)gains visibility, ported from `liveBeginReconnect` / `setTileConnecting`
// / `liveRevealOnFirstFrame` in apps/desktop/src/app.js.
//
// The Tauri client reused native libmpv panes across tab switches; a fresh
// RTSP open goes black until its first keyframe, and staggered across
// cameras that produced a visible "windows fill in one at a time" cascade.
// It hid each pane behind a DOM placeholder via `invoke('set_panes_hidden')`
// and revealed it the instant the pane's `live_pane_progress` advanced past
// its pre-reconnect baseline, with a 3s reveal-all fallback so nothing could
// be stuck hidden forever.
//
// media_kit tiles are ordinary Flutter widgets, not natively-composited
// panes, so there's no window to hide — "hidden" here just means the tile
// renders its "Connecting…" placeholder instead of the `Video` widget. This
// controller only tracks *which* pane ids are in that state; each tile
// decides for itself what "hidden" looks like.

import 'dart:async';

import 'package:flutter/foundation.dart';

class LiveRevealController extends ChangeNotifier {
  LiveRevealController({this.fallback = const Duration(seconds: 3)});

  /// Reveal-all fallback so a pane can never be left behind the placeholder
  /// forever if its stream never produces a frame.
  final Duration fallback;

  final Set<String> _connecting = {};
  Timer? _fallbackTimer;

  bool isConnecting(String paneId) => _connecting.contains(paneId);

  /// Mark the given panes as "Connecting…" (each tile should hide its video
  /// and show the placeholder) and arm the reveal-all fallback. Call this
  /// whenever the Live view (re)gains visibility and is about to reconnect
  /// its panes — including on first entry, when [paneIds] is simply empty.
  void beginReconnect(Iterable<String> paneIds) {
    _fallbackTimer?.cancel();
    _connecting
      ..clear()
      ..addAll(paneIds);
    if (_connecting.isEmpty) return;
    notifyListeners();
    _fallbackTimer = Timer(fallback, revealAll);
  }

  /// Reveal one pane the instant its stream decodes a first live frame.
  void notifyFrameDecoded(String paneId) {
    if (_connecting.remove(paneId)) {
      notifyListeners();
      if (_connecting.isEmpty) _fallbackTimer?.cancel();
    }
  }

  /// Reveal every still-hidden pane immediately — the fallback path, and
  /// also appropriate to call when navigating away from Live mid-reconnect.
  void revealAll() {
    _fallbackTimer?.cancel();
    if (_connecting.isEmpty) return;
    _connecting.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    super.dispose();
  }
}
