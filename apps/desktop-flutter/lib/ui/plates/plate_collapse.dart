// Client-side collapse of duplicate plate reads into one row per physical car.
//
// Two independent things create duplicate rows in the Plates list:
//   1. "both"-mode cameras: Frigate AND the crumb-alpr worker each read every
//      car, so one pass yields one row per engine (often a character apart).
//   2. Frigate on its own emits several reads for a single pass as its OCR
//      refines (e.g. 9GXVL98 then 9GXV498 a few seconds later).
//
// Both are the SAME underlying event — one car going by — so the list should
// show one representative row, annotated with which engine(s) saw it and (when
// they disagree) the alternate reading. The raw reads are untouched server-side;
// this is purely how the client presents them, and the operator can switch it
// off to see every raw read (e.g. to eyeball the A/B disagreement directly).
//
// Grouping key: same camera + fuzzy-equal plate + within a short time window.
// The time+camera gate makes the fuzzy plate threshold safe — two genuinely
// different cars with near-identical plates on the same camera seconds apart
// essentially never happens, whereas one car misread twice is common.

import 'dart:math' as math;

import '../../api/plates_api.dart';

/// How far apart (in time) two reads on the same camera can be and still be
/// treated as the same pass. Comfortably covers Frigate's multi-second OCR
/// refinements and the ~2s offset between the two engines, while staying well
/// under the worker's 45s parked-car re-appear gap (a genuine re-appearance is
/// a new row, as it should be).
const Duration kPlateCollapseWindow = Duration(seconds: 15);

/// One physical vehicle pass: the best read plus every raw read that collapsed
/// into it. [members] and the group list stay newest-first.
class PlateGroup {
  PlateGroup(this.representative, this.members);

  /// Highest-confidence read in the group — its plate/image/confidence are what
  /// the collapsed row shows.
  final PlateRead representative;

  /// Every raw read that collapsed here, newest-first (includes [representative]).
  final List<PlateRead> members;

  int get count => members.length;
  DateTime get ts => representative.ts;

  /// Distinct engines that saw this car, in first-seen order (stable for UI).
  List<String> get sources {
    final out = <String>[];
    for (final m in members) {
      final s = m.sourceId;
      if (s != null && s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    return out;
  }

  /// The best (highest-confidence) read from a given engine, or null.
  PlateRead? bestFrom(String source) {
    PlateRead? best;
    for (final m in members) {
      if (m.sourceId != source) continue;
      if (best == null ||
          (m.confidence ?? 0) > (best.confidence ?? 0)) {
        best = m;
      }
    }
    return best;
  }

  /// Alternate readings that differ from the representative's plate, keyed by
  /// engine — i.e. the engines that disagreed. Empty when everyone agreed.
  Map<String, String> get disagreements {
    final out = <String, String>{};
    for (final s in sources) {
      final r = bestFrom(s);
      if (r != null && r.plate.isNotEmpty && r.plate != representative.plate) {
        out[s] = r.plate;
      }
    }
    return out;
  }
}

/// Collapse [readsNewestFirst] into one [PlateGroup] per physical car. The input
/// must be sorted newest-first (the Plates screen already guarantees this); the
/// output preserves that order by representative timestamp.
List<PlateGroup> collapsePlateReads(
  List<PlateRead> readsNewestFirst, {
  Duration window = kPlateCollapseWindow,
}) {
  final groups = <_MutableGroup>[];
  for (final r in readsNewestFirst) {
    _MutableGroup? target;
    for (final g in groups) {
      if (g.cameraId != r.cameraId) continue;
      // Reads arrive newest→oldest, so `r` is at or before the group's oldest
      // member; the closest boundary is that oldest ts.
      if (g.oldestTs.difference(r.ts).abs() > window) continue;
      if (_platesSimilar(g.keyPlate, r.plate)) {
        target = g;
        break;
      }
    }
    if (target != null) {
      target.add(r);
    } else {
      groups.add(_MutableGroup(r));
    }
  }
  return groups.map((g) => g.freeze()).toList(growable: false);
}

class _MutableGroup {
  _MutableGroup(PlateRead first)
      : cameraId = first.cameraId,
        _best = first,
        oldestTs = first.ts,
        _members = [first];

  final String cameraId;
  PlateRead _best;
  DateTime oldestTs;
  final List<PlateRead> _members;

  /// Match new reads against the current best plate (updated as the best read
  /// changes) so a low-confidence garbage first read doesn't anchor the group.
  String get keyPlate => _best.plate;

  void add(PlateRead r) {
    _members.add(r);
    if (r.ts.isBefore(oldestTs)) oldestTs = r.ts;
    if ((r.confidence ?? 0) > (_best.confidence ?? 0)) _best = r;
  }

  PlateGroup freeze() {
    // Keep members newest-first for display.
    _members.sort((a, b) => b.ts.compareTo(a.ts));
    return PlateGroup(_best, List.unmodifiable(_members));
  }
}

/// Two normalized plates are "the same car" when they're within a small,
/// length-scaled edit distance (~a third of the characters). Plates arrive
/// already normalized (uppercase alphanumeric) from the server.
bool _platesSimilar(String a, String b) {
  if (a == b) return true;
  if (a.isEmpty || b.isEmpty) return false;
  final maxLen = math.max(a.length, b.length);
  final maxEdits = math.max(1, (maxLen * 0.34).round());
  return _boundedLevenshtein(a, b, maxEdits) <= maxEdits;
}

/// Levenshtein distance, short-circuiting once it provably exceeds [maxEdits]
/// (returns maxEdits + 1). Two-row DP — fine for the short strings here.
int _boundedLevenshtein(String a, String b, int maxEdits) {
  if ((a.length - b.length).abs() > maxEdits) return maxEdits + 1;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var curr = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    var rowMin = curr[0];
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = math.min(
        math.min(curr[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + cost,
      );
      if (curr[j] < rowMin) rowMin = curr[j];
    }
    if (rowMin > maxEdits) return maxEdits + 1;
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[b.length];
}
