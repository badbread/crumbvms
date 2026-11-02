// "Hardware video decoding" client option (#713): which mpv `hwdec` value
// every libmpv pane is opened with. Some GPU drivers fault inside their video
// decoder and take the whole process down, so the operator needs a way to fall
// back to software decoding.
//
// The panes are spread over many screens that have no handle on the options
// store, so the current value is mirrored into [HardwareDecode.enabled] (set
// by `ClientOptionsStore`, same approach as `MotionPrefs.reduceMotion`) and
// panes read it through [hwdecMode] when they are created. Already-open panes
// keep the decoder they started with until they are reopened or reconnected.

import 'package:flutter/foundation.dart';

/// Process-wide mirror of the persisted "Hardware video decoding" option.
class HardwareDecode {
  HardwareDecode._();

  /// Default ON (mpv `auto`). Written by `ClientOptionsStore`.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);
}

/// The mpv `hwdec` property value for [enabled]: `auto` or `no`.
String hwdecModeFor(bool enabled) => enabled ? 'auto' : 'no';

/// The `hwdec` value to give a newly created mpv pane right now.
String hwdecMode() => hwdecModeFor(HardwareDecode.enabled.value);
