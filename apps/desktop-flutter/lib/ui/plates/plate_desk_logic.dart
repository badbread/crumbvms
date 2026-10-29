// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Pure logic behind the redesigned Plates page ("plate desk"): density
// metrics, plate classification (rails and filters), the derived hints
// (NEW / UNUSUAL HOUR / Nx TODAY), group-by-plate flattening for a
// fixed-extent list, compact relative-time text, the plate profile's visit
// collapsing and summary sentence, and the batched, 60-second plate-history
// cache. No widgets here, so all of it is unit-tested
// (test/plate_desk_logic_test.dart).

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:crumb_desktop/api/plate_desk_api.dart';
import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_collapse.dart';

// ─── density ───────────────────────────────────────────────────────────────

/// The one list display control. Row height, image sizes and type all change
/// together, so each step is obviously different.
enum PlateDensity { compact, standard, large }

/// Fixed sizes for one [PlateDensity]. Every list row has exactly
/// [rowExtent] height, which lets the list use a fixed item extent.
class DensityMetrics {
  const DensityMetrics({
    required this.rowExtent,
    required this.showImages,
    required this.frameWidth,
    required this.frameHeight,
    required this.cropWidth,
    required this.cropHeight,
    required this.plateFont,
    required this.subFont,
    required this.sparkWidth,
    required this.sparkHeight,
  });

  final double rowExtent;

  /// Compact is text-only: no frame thumbnail and no plate crop.
  final bool showImages;
  final double frameWidth;
  final double frameHeight;
  final double cropWidth;
  final double cropHeight;
  final double plateFont;
  final double subFont;
  final double sparkWidth;
  final double sparkHeight;
}

const _compact = DensityMetrics(
  rowExtent: 36,
  showImages: false,
  frameWidth: 0,
  frameHeight: 0,
  cropWidth: 0,
  cropHeight: 0,
  plateFont: 14,
  subFont: 11,
  sparkWidth: 72,
  sparkHeight: 16,
);

const _standard = DensityMetrics(
  rowExtent: 64,
  showImages: true,
  frameWidth: 88,
  frameHeight: 50,
  cropWidth: 112,
  cropHeight: 44,
  plateFont: 17,
  subFont: 11,
  sparkWidth: 90,
  sparkHeight: 22,
);

const _large = DensityMetrics(
  rowExtent: 104,
  showImages: true,
  frameWidth: 160,
  frameHeight: 90,
  cropWidth: 200,
  cropHeight: 80,
  plateFont: 23,
  subFont: 12,
  sparkWidth: 112,
  sparkHeight: 32,
);

DensityMetrics densityMetrics(PlateDensity d) => switch (d) {
  PlateDensity.compact => _compact,
  PlateDensity.standard => _standard,
  PlateDensity.large => _large,
};

// ─── ledger columns ─────────────────────────────────────────────────────────

/// Fixed ledger column widths (logical px).
const double kLedgerHistoryW = 158;
const double kLedgerWhenW = 78;
const double kLedgerConfW = 50;
const double kLedgerActionsW = 32;

/// Rail (3) + left padding (10) + right padding (10).
const double kLedgerPadW = 23;

/// The plate / camera column never gets narrower than this; optional columns
/// drop out first.
const double kLedgerMinPlateW = 150;

/// Which optional columns fit at a given list width.
class LedgerColumns {
  const LedgerColumns({
    required this.frame,
    required this.crop,
    required this.spark,
  });

  final bool frame;
  final bool crop;
  final bool spark;
}

/// Decide the optional columns for [width]: the plate crop goes first (it is
/// the point of the page), then the 30-day sparkline, then the frame. Compact
/// never shows images.
LedgerColumns ledgerColumns(DensityMetrics m, double width) {
  var free =
      width -
      kLedgerPadW -
      kLedgerHistoryW -
      kLedgerWhenW -
      kLedgerConfW -
      kLedgerActionsW -
      kLedgerMinPlateW;
  bool take(double w) {
    if (free < w) return false;
    free -= w;
    return true;
  }

  final crop = m.showImages && take(m.cropWidth + 12);
  final spark = take(m.sparkWidth + 12);
  final frame = m.showImages && take(m.frameWidth + 10);
  return LedgerColumns(frame: frame, crop: crop, spark: spark);
}

// ─── classification, rails, filters ─────────────────────────────────────────

/// The coloured left rail on a row: watchlist wins over new, new over regular.
enum PlateRail { none, watchlist, newPlate, regular }

PlateRail plateRail({required bool watched, PlateStats? stats}) {
  if (watched) return PlateRail.watchlist;
  if (stats == null) return PlateRail.none;
  if (stats.isNew) return PlateRail.newPlate;
  if (stats.isRegular) return PlateRail.regular;
  return PlateRail.none;
}

/// What the header tiles and split segments filter the list to.
enum DeskFilter { all, firstTime, watchlist, regulars, returning }

/// Whether a plate passes [filter]. Stats-based filters reject a plate whose
/// history has not loaded (yet), so the filtered list only ever shows plates
/// that are known to match.
bool deskFilterMatches(
  DeskFilter filter, {
  required bool watched,
  PlateStats? stats,
}) {
  switch (filter) {
    case DeskFilter.all:
      return true;
    case DeskFilter.watchlist:
      return watched;
    case DeskFilter.firstTime:
      return stats != null && stats.isNew;
    case DeskFilter.regulars:
      return stats != null && stats.isRegular;
    case DeskFilter.returning:
      return stats != null && stats.isReturning;
  }
}

String deskFilterLabel(DeskFilter f) => switch (f) {
  DeskFilter.all => 'All reads',
  DeskFilter.firstTime => 'First-time plates',
  DeskFilter.watchlist => 'Watchlist plates',
  DeskFilter.regulars => 'Regulars',
  DeskFilter.returning => 'Returning plates',
};

// ─── hints ──────────────────────────────────────────────────────────────────

/// An hour bucket is unusual for a plate when it holds under 3% of a history
/// of at least 10 reads.
const int kUnusualHourMinReads = 10;
const double kUnusualHourShare = 0.03;

bool isUnusualHour(List<int> hours, int hour) {
  if (hour < 0 || hour >= hours.length) return false;
  final total = hours.fold<int>(0, (a, b) => a + b);
  if (total < kUnusualHourMinReads) return false;
  return hours[hour] / total < kUnusualHourShare;
}

/// The computed marks on a row or card.
class PlateHints {
  const PlateHints({
    required this.isNew,
    required this.unusualHour,
    required this.todayCount,
  });

  final bool isNew;
  final bool unusualHour;
  final int todayCount;

  /// "4x TODAY" shows from the second read of the day.
  bool get showToday => todayCount >= 2;

  static const none = PlateHints(
    isNew: false,
    unusualHour: false,
    todayCount: 0,
  );
}

/// Hints for a read at [readTs] of a plate with [stats]. The hour is the
/// read's local hour on this machine; the history buckets are in the server's
/// zone, which is the same zone for a client on the site's LAN.
PlateHints plateHints(PlateStats? stats, DateTime readTs) {
  if (stats == null) return PlateHints.none;
  return PlateHints(
    isNew: stats.isNew,
    unusualHour: isUnusualHour(stats.hours, readTs.toLocal().hour),
    todayCount: stats.today,
  );
}

// ─── group by plate ─────────────────────────────────────────────────────────

/// All loaded reads (already de-duplicated into [PlateGroup]s) of one plate.
class PlateBundle {
  PlateBundle(this.plate, this.groups);

  final String plate;

  /// Newest first; [head] is the newest.
  final List<PlateGroup> groups;

  PlateGroup get head => groups.first;

  /// Raw reads across every group (duplicate reads of one pass included).
  int get readCount => groups.fold<int>(0, (a, g) => a + g.count);

  /// Passes (rows) in the bundle.
  int get passCount => groups.length;
}

/// Bundle [groupsNewestFirst] by plate, keeping newest-first order (a bundle
/// sits where its newest read sits). Reads with no plate each stay alone.
List<PlateBundle> bundleByPlate(List<PlateGroup> groupsNewestFirst) {
  final byPlate = <String, List<PlateGroup>>{};
  final order = <String>[];
  var anon = 0;
  for (final g in groupsNewestFirst) {
    final plate = g.representative.plate;
    final key = plate.isEmpty ? '\u0000${anon++}' : plate;
    final list = byPlate[key];
    if (list == null) {
      byPlate[key] = [g];
      order.add(key);
    } else {
      list.add(g);
    }
  }
  return [
    for (final k in order)
      PlateBundle(byPlate[k]!.first.representative.plate, byPlate[k]!),
  ];
}

/// One row of the flattened ledger list.
class LedgerEntry {
  const LedgerEntry({required this.group, this.bundle, this.isChild = false});

  /// The pass this row shows.
  final PlateGroup group;

  /// Set on a group-by-plate head row (null when not grouping).
  final PlateBundle? bundle;

  /// An expanded earlier pass of [bundle]'s plate, drawn indented.
  final bool isChild;

  String get key => '${isChild ? 'c' : 'h'}:${group.representative.id}';
}

/// Flatten into one list so every row keeps the fixed extent. Without
/// grouping, one row per pass. With grouping, one head row per plate, followed
/// by its earlier passes when the plate is in [expanded].
List<LedgerEntry> flattenLedger(
  List<PlateGroup> groupsNewestFirst, {
  required bool groupByPlate,
  Set<String> expanded = const {},
}) {
  if (!groupByPlate) {
    return [for (final g in groupsNewestFirst) LedgerEntry(group: g)];
  }
  final out = <LedgerEntry>[];
  for (final b in bundleByPlate(groupsNewestFirst)) {
    out.add(LedgerEntry(group: b.head, bundle: b));
    if (b.groups.length > 1 && expanded.contains(b.plate)) {
      for (final g in b.groups.skip(1)) {
        out.add(LedgerEntry(group: g, bundle: b, isChild: true));
      }
    }
  }
  return out;
}

// ─── text ───────────────────────────────────────────────────────────────────

const _monthsShort = [
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

/// "just now", "12 min ago", "3 h ago", "2 d ago".
String fmtAgo(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// "today", "Jun 3", or "Jun 3, 2025" (local time).
String fmtShortDate(DateTime t, DateTime now) {
  final l = t.toLocal();
  final n = now.toLocal();
  if (l.year == n.year && l.month == n.month && l.day == n.day) return 'today';
  final base = '${_monthsShort[l.month - 1]} ${l.day}';
  return l.year == n.year ? base : '$base, ${l.year}';
}

/// "5 PM", "12 AM".
String fmtHour(int h) {
  final h24 = h % 24;
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  return '$h12 ${h24 < 12 ? 'AM' : 'PM'}';
}

/// The two lines of the ledger's history cell, e.g. ("14x seen",
/// "prev 2 d ago, first Jun 3"). "-" when the history is unavailable.
(String, String) historyCellText(PlateStats? s, DateTime now) {
  if (s == null) return ('-', '');
  final prev = s.prevSeen;
  final second = s.isNew
      ? 'first seen today'
      : 'prev ${prev == null ? '-' : fmtAgo(prev, now)}, '
            'first ${fmtShortDate(s.firstSeen, now)}';
  return ('${s.total}x seen', second);
}

// ─── plate profile: visits and the summary sentence ────────────────────────

/// Reads of one plate on the same camera no more than this far apart are one
/// visit (a car pulling in, sitting at the gate, and leaving).
const Duration kVisitGap = Duration(minutes: 5);

/// One visit of a plate: consecutive reads on one camera, each within
/// [kVisitGap] of the next.
class PlateVisit {
  PlateVisit(this.cameraId, this.reads);

  final String cameraId;

  /// Newest first.
  final List<PlateRead> reads;

  DateTime get start => reads.last.ts;
  DateTime get end => reads.first.ts;
  int get count => reads.length;

  /// The most confident read (ties: the newest).
  PlateRead get best {
    var b = reads.first;
    for (final r in reads) {
      if ((r.confidence ?? 0) > (b.confidence ?? 0)) b = r;
    }
    return b;
  }

  double? get bestConfidence => best.confidence;
}

/// Collapse [reads] (any order) into visits, newest visit first. A read joins
/// the newest open visit on its camera when it is within [gap] of that
/// visit's oldest read; otherwise it starts a new visit.
List<PlateVisit> collapseVisits(
  List<PlateRead> reads, {
  Duration gap = kVisitGap,
}) {
  final sorted = reads.toList()..sort((a, b) => b.ts.compareTo(a.ts));
  final open = <String, List<PlateRead>>{};
  final visits = <List<PlateRead>>[];
  final cams = <List<PlateRead>, String>{};
  for (final r in sorted) {
    final cur = open[r.cameraId];
    if (cur != null && cur.last.ts.difference(r.ts) <= gap) {
      cur.add(r);
      continue;
    }
    final v = <PlateRead>[r];
    open[r.cameraId] = v;
    visits.add(v);
    cams[v] = r.cameraId;
  }
  return [for (final v in visits) PlateVisit(cams[v]!, v)];
}

/// "5 and 6 PM", "11 AM and 12 PM", "11 PM and 12 AM".
String fmtHourRange(int h, int span) {
  final a = h % 24;
  final b = (h + span) % 24;
  final aPm = a >= 12;
  final bPm = b >= 12;
  final a12 = a % 12 == 0 ? 12 : a % 12;
  if (aPm == bPm && b != 0 && b != 12) return '$a12 and ${fmtHour(b)}';
  return '${fmtHour(a)} and ${fmtHour(b)}';
}

/// The busiest window of [span] consecutive hours (wrapping at midnight):
/// `(startHour, reads)`.
(int, int) busiestHours(List<int> hours, int span) {
  var bestH = 0;
  var bestN = -1;
  for (var h = 0; h < 24; h++) {
    var n = 0;
    for (var k = 0; k < span; k++) {
      n += hours[(h + k) % 24];
    }
    if (n > bestN) {
      bestN = n;
      bestH = h;
    }
  }
  return (bestH, bestN < 0 ? 0 : bestN);
}

/// The profile's plain-English summary, e.g. "Usually arrives between 5 and
/// 6 PM, mostly on .06 LPR." [focus] is the read the profile was opened from;
/// when its hour is unusual for this plate the summary says so.
String plateSummary(
  PlateStats s, {
  required String Function(String cameraId) camName,
  DateTime? focus,
  DateTime? now,
}) {
  if (s.total <= 0) return '';
  final n = now ?? DateTime.now();
  final parts = <String>[];
  String where() {
    if (s.cameras.isEmpty) return '';
    final top = s.cameras.first;
    if (s.cameras.length == 1 || top.n / s.total >= 0.6) {
      return ', mostly on ${camName(top.cameraId)}';
    }
    return ', across ${s.cameras.length} cameras';
  }

  if (s.isNew) {
    final times = s.today == 1 ? 'once' : '${s.today} times';
    final cam = s.cameras.isEmpty
        ? ''
        : ' on ${camName(s.cameras.first.cameraId)}';
    parts.add('First seen today$cam, $times so far.');
  } else if (s.total < 3) {
    parts.add(
      'Seen ${s.total == 1 ? 'once' : 'twice'} before, first on '
      '${fmtShortDate(s.firstSeen, n)}${where()}.',
    );
  } else {
    final (h1, n1) = busiestHours(s.hours, 1);
    final (h3, n3) = busiestHours(s.hours, 3);
    final String when;
    if (n1 / s.total >= 0.25) {
      when = 'Usually arrives between ${fmtHourRange(h1, 1)}';
    } else if (n3 / s.total >= 0.4) {
      when = 'Usually arrives between ${fmtHourRange(h3, 3)}';
    } else {
      when = 'Comes and goes at all hours';
    }
    parts.add('$when${where()}.');
  }
  if (focus != null && isUnusualHour(s.hours, focus.toLocal().hour)) {
    final l = focus.toLocal();
    final today = l.year == n.year && l.month == n.month && l.day == n.day;
    final h12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
    final t =
        '$h12:${l.minute.toString().padLeft(2, '0')} '
        '${l.hour < 12 ? 'AM' : 'PM'}';
    parts.add(
      today
          ? "Today's $t read is unusual for this plate."
          : 'The $t read on ${fmtShortDate(focus, n)} is unusual for this plate.',
    );
  }
  return parts.join(' ');
}

// ─── history cache ──────────────────────────────────────────────────────────

typedef PlateStatsFetcher =
    Future<Map<String, PlateStats>?> Function(List<String> plates);

/// Batched, de-duplicated plate-history cache. Rows call [want] for the plates
/// they show; requests are coalesced into batches of at most
/// [kPlateStatsMaxBatch] and kept for [ttl] (stale values keep showing while a
/// refresh is in flight). A null fetch result means the server predates the
/// endpoint: [unsupported] latches true and nothing is requested again.
class PlateStatsCache extends ChangeNotifier {
  PlateStatsCache(
    this._fetch, {
    this.ttl = const Duration(seconds: 60),
    this.debounce = const Duration(milliseconds: 40),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PlateStatsFetcher _fetch;
  final Duration ttl;
  final Duration debounce;
  final DateTime Function() _clock;

  final Map<String, PlateStats> _stats = {};
  final Map<String, DateTime> _fetchedAt = {};
  final Set<String> _inFlight = {};
  final Set<String> _queued = {};
  Timer? _timer;
  bool _disposed = false;
  int _generation = 0;

  bool _unsupported = false;

  /// The server has no `/lpr/plates/stats` (older server).
  bool get unsupported => _unsupported;

  PlateStats? operator [](String plate) => _stats[plate];

  /// Whether [plate] was asked for and answered (with stats or with none).
  bool isResolved(String plate) => _fetchedAt.containsKey(plate);

  bool _fresh(String plate) {
    final at = _fetchedAt[plate];
    return at != null && _clock().difference(at) < ttl;
  }

  /// Queue [plates] that are missing or stale. Flushes after [debounce].
  void want(Iterable<String> plates) {
    if (_unsupported || _disposed) return;
    var added = false;
    for (final p in plates) {
      if (p.isEmpty || _fresh(p) || _inFlight.contains(p)) continue;
      if (_queued.add(p)) added = true;
    }
    if (!added) return;
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(flush()));
  }

  /// Fetch everything queued now, in batches.
  Future<void> flush() async {
    _timer?.cancel();
    if (_queued.isEmpty || _unsupported || _disposed) return;
    final all = _queued.toList()..sort();
    _queued.clear();
    _inFlight.addAll(all);
    final gen = _generation;
    for (var i = 0; i < all.length; i += kPlateStatsMaxBatch) {
      final end = (i + kPlateStatsMaxBatch).clamp(0, all.length);
      final batch = all.sublist(i, end);
      Map<String, PlateStats>? got;
      var failed = false;
      try {
        got = await _fetch(batch);
      } catch (_) {
        failed = true;
      }
      if (_disposed) return;
      _inFlight.removeAll(batch);
      if (gen != _generation) continue;
      if (!failed && got == null) {
        _unsupported = true;
        _queued.clear();
        notifyListeners();
        return;
      }
      final now = _clock();
      for (final p in batch) {
        // A failed batch is retried after the TTL too, instead of hammering
        // a server that just errored on every rebuild.
        _fetchedAt[p] = now;
        final s = got?[p];
        if (s != null) {
          _stats[p] = s;
        } else if (!failed) {
          _stats.remove(p);
        }
      }
      notifyListeners();
    }
  }

  /// Forget everything (e.g. after a plate was renamed or the filters
  /// changed what "visible" means). Keeps the [unsupported] latch.
  void invalidate() {
    _generation++;
    _stats.clear();
    _fetchedAt.clear();
    _queued.clear();
    _inFlight.clear();
    _timer?.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
