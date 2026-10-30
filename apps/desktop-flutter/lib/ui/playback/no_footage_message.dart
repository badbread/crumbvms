// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Why a playback pane has no footage at the playhead. Pure (no widgets) so
// every branch is unit-tested; playback_screen.dart maps the reason to an
// icon, tint and the short corner label.
//
// The pane only knows "no segment here" (or that loading failed). The reason
// comes from real data, not a guess: the wall clock (live edge), the camera's
// oldest remaining recording (`oldest_footage_ts` on GET /cameras) and its
// effective recording mode (`recording_mode` on GET /cameras).

/// Which no-footage case applies, in priority order.
enum NoFootageReason {
  /// Resolving the segment, the media token or the network failed.
  loadError,

  /// The playhead is at or past the live edge and the camera is recording
  /// right now. Segments are indexed only once they close, so the newest few
  /// seconds never have footage yet. A motion camera with no motion right now
  /// is [noMotion] instead: nothing is being recorded, so nothing will appear.
  liveEdge,

  /// The playhead is earlier than the camera's oldest remaining recording:
  /// retention has deleted it.
  footageDeleted,

  /// The camera has no recordings at all (new server, no segments).
  noFootageForCamera,

  /// Motion-mode camera, inside the retained range: nothing moved.
  noMotion,

  /// Continuous camera, inside the retained range, nothing recorded. Abnormal
  /// (camera offline or recording stopped), so it is flagged.
  recordingGap,

  /// Older server without the fields: no reason is claimed.
  unknown,
}

/// How close to "now" the playhead must be to count as the live edge.
const Duration kLiveEdgeWindow = Duration(seconds: 10);

/// How recent a motion camera's last motion must be for it to count as still
/// recording at the live edge (a segment is a few seconds long, plus the
/// motion post-roll keeps recording after motion stops).
const Duration kRecentMotionWindow = Duration(seconds: 30);

class NoFootageMessage {
  const NoFootageMessage(
    this.reason,
    this.title,
    this.shortLabel, [
    this.subtitle,
  ]);

  final NoFootageReason reason;
  final String title;

  /// Short form for the small corner label on grid tiles.
  final String shortLabel;
  final String? subtitle;

  /// True for the cases shown in the amber warn style.
  bool get isWarning =>
      reason == NoFootageReason.recordingGap ||
      reason == NoFootageReason.noFootageForCamera;
}

/// Choose the message for a pane with no footage at [playhead].
///
/// [error] is the pane's load error, if any. [now] is the wall clock (UTC).
/// [oldestFootage] is the camera's oldest remaining recording and
/// [recordingMode] its effective policy mode (`"continuous"` / `"motion"`);
/// both are null against a server that predates them. [motionNow] is whether
/// a motion camera has had motion in the last few seconds (so it is recording
/// and its footage is just not indexed yet).
NoFootageMessage noFootageMessage({
  required DateTime playhead,
  required DateTime now,
  String? error,
  DateTime? oldestFootage,
  String? recordingMode,
  bool motionNow = false,
}) {
  if (error != null) {
    return NoFootageMessage(
      NoFootageReason.loadError,
      "Couldn't load footage",
      'error',
      error,
    );
  }
  if (!playhead.isBefore(now.subtract(kLiveEdgeWindow))) {
    if (recordingMode == 'motion' && !motionNow) {
      // An idle motion camera is not "a few seconds behind": it is not
      // recording at all.
      return const NoFootageMessage(
        NoFootageReason.noMotion,
        'No motion right now',
        'no motion',
        'This camera records only when it detects motion',
      );
    }
    return const NoFootageMessage(
      NoFootageReason.liveEdge,
      'Live edge',
      'live edge',
      'Recordings appear a few seconds behind live',
    );
  }
  if (oldestFootage != null && playhead.isBefore(oldestFootage)) {
    return NoFootageMessage(
      NoFootageReason.footageDeleted,
      'Footage deleted',
      'deleted',
      "Older than this camera's retention. "
          'Recordings start ${formatLocalDateTime(oldestFootage)}.',
    );
  }
  final mode = recordingMode;
  if (mode == null || (mode != 'motion' && mode != 'continuous')) {
    return const NoFootageMessage(
      NoFootageReason.unknown,
      'No footage at this time',
      'no footage',
    );
  }
  if (oldestFootage == null) {
    // A server new enough to send the mode, with no oldest recording: the
    // camera has never recorded anything (or everything is gone).
    return const NoFootageMessage(
      NoFootageReason.noFootageForCamera,
      'No footage for this camera',
      'no footage',
      'Nothing has been recorded for this camera',
    );
  }
  if (mode == 'motion') {
    return const NoFootageMessage(
      NoFootageReason.noMotion,
      'No motion at this time',
      'no motion',
      'This camera records only when it detects motion',
    );
  }
  return const NoFootageMessage(
    NoFootageReason.recordingGap,
    'Recording gap',
    'gap',
    'This camera records continuously, but nothing was recorded here '
        '(camera offline or recording stopped)',
  );
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `Sep 10, 2026 14:03` in local time.
String formatLocalDateTime(DateTime t) {
  final l = t.toLocal();
  final hh = l.hour.toString().padLeft(2, '0');
  final mm = l.minute.toString().padLeft(2, '0');
  return '${_months[l.month - 1]} ${l.day}, ${l.year} $hh:$mm';
}
