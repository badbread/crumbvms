// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The single-plate report's operator options, and the PURE logic that turns
// them into the report's contents. Kept out of the dialog (which owns widgets
// and network I/O) and out of the composition layer (which owns `pw.Widget`s)
// so the decisions that actually change what lands on the page — which window,
// which cameras, what order, how many images — can be unit-tested directly.
//
// Nothing here touches the network, the clock (except through an injected
// `now`), or `dart:ui`.

import 'package:crumb_desktop/api/plates_api.dart';

/// The report's time window. [custom] uses the operator's own start/end; every
/// other value is a window of N days ending "now".
///
/// An incident report almost always wants a window: a plate that has been
/// around for weeks produces a list nobody wants to read, and the recipient
/// only cares about the period being reported.
enum ReportRange { allTime, days7, days30, days90, custom }

/// Which images the report embeds for a sighting.
///
/// Meaningfully changes both usefulness and file size: the plate crop is what
/// proves the read, the vehicle frame is what identifies the car, and a
/// handout often only needs one of the two.
enum ReportImageType { plateOnly, vehicleOnly, both }

/// Occurrence-list order. Newest-first matches the Plates tab; oldest-first
/// reads as a narrative when the report documents a pattern over time.
enum ReportSort { newestFirst, oldestFirst }

/// Paper size. Letter is the default (Crumb's operators are mostly US); A4 is
/// one line of code away, so there is no reason to make anyone else convert.
enum ReportPageSize { letter, a4 }

/// How many sighting thumbnails the report embeds. [all] is capped by
/// [kMaxReportThumbs] so a plate with hundreds of sightings cannot produce a
/// PDF nobody can email.
enum ReportThumbCount { none, four, eight, twelve, all }

/// Hard ceiling on embedded sighting thumbnails, even for [ReportThumbCount.all].
/// Each downscaled thumbnail costs roughly 15-25 KB, so 24 keeps the worst case
/// under about half a megabyte of images.
const int kMaxReportThumbs = 24;

/// Above this many embedded thumbnails the dialog warns that the PDF will be
/// large and slow to build (every thumbnail is a separate authed fetch).
const int kThumbSizeWarningThreshold = 8;

/// Ceiling on how many reads the builder will pull for the occurrence list.
/// `GET /plates` caps a single page at 1 000; four pages is more history than
/// any handout needs, and the report says so when it truncates.
const int kMaxOccurrencesFetched = 2000;

/// The requested thumbnail count as a number. [ReportThumbCount.all] resolves
/// to [kMaxReportThumbs] — the cap, not "unbounded".
int reportThumbTarget(ReportThumbCount c) => switch (c) {
      ReportThumbCount.none => 0,
      ReportThumbCount.four => 4,
      ReportThumbCount.eight => 8,
      ReportThumbCount.twelve => 12,
      ReportThumbCount.all => kMaxReportThumbs,
    };

/// How many thumbnails will actually be embedded given [available] candidate
/// sightings: the requested count, capped by both [kMaxReportThumbs] and what
/// exists. Never negative.
int cappedThumbCount(ReportThumbCount requested, int available) {
  final target = reportThumbTarget(requested);
  final capped = target > kMaxReportThumbs ? kMaxReportThumbs : target;
  return capped < available ? capped : (available < 0 ? 0 : available);
}

/// Human label for the count control.
String reportThumbCountLabel(ReportThumbCount c) => switch (c) {
      ReportThumbCount.none => 'No images',
      ReportThumbCount.four => '4 images',
      ReportThumbCount.eight => '8 images',
      ReportThumbCount.twelve => '12 images',
      ReportThumbCount.all => 'All (max $kMaxReportThumbs)',
    };

String reportRangeLabel(ReportRange r) => switch (r) {
      ReportRange.allTime => 'All time',
      ReportRange.days7 => 'Last 7 days',
      ReportRange.days30 => 'Last 30 days',
      ReportRange.days90 => 'Last 90 days',
      ReportRange.custom => 'Custom range',
    };

String reportImageTypeLabel(ReportImageType t) => switch (t) {
      ReportImageType.plateOnly => 'Plate crop only',
      ReportImageType.vehicleOnly => 'Vehicle frame only',
      ReportImageType.both => 'Plate crop and vehicle frame',
    };

String reportSortLabel(ReportSort s) => switch (s) {
      ReportSort.newestFirst => 'Newest first',
      ReportSort.oldestFirst => 'Oldest first',
    };

String reportPageSizeLabel(ReportPageSize p) =>
    p == ReportPageSize.a4 ? 'A4' : 'Letter';

/// A resolved `[start, end)` window. Either bound may be null, meaning
/// unbounded on that side; `ReportRange.allTime` yields both null so the
/// request sends no window at all.
class ReportWindow {
  const ReportWindow(this.start, this.end);

  final DateTime? start;
  final DateTime? end;

  bool get isUnbounded => start == null && end == null;

  /// True when [t] falls inside the window (start inclusive, end exclusive).
  bool contains(DateTime t) {
    if (start != null && t.isBefore(start!)) return false;
    if (end != null && !t.isBefore(end!)) return false;
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is ReportWindow && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ReportWindow($start, $end)';
}

/// Resolve [range] against [now] into a concrete window.
///
/// The N-day presets end at [now] and start N days earlier. [ReportRange.custom]
/// uses the operator's bounds verbatim, swapping them when they arrive
/// backwards (a date picker makes that easy to do by accident, and silently
/// producing an empty report would be the wrong answer).
ReportWindow resolveReportWindow(
  ReportRange range, {
  required DateTime now,
  DateTime? customStart,
  DateTime? customEnd,
}) {
  switch (range) {
    case ReportRange.allTime:
      return const ReportWindow(null, null);
    case ReportRange.days7:
      return ReportWindow(now.subtract(const Duration(days: 7)), now);
    case ReportRange.days30:
      return ReportWindow(now.subtract(const Duration(days: 30)), now);
    case ReportRange.days90:
      return ReportWindow(now.subtract(const Duration(days: 90)), now);
    case ReportRange.custom:
      var s = customStart;
      var e = customEnd;
      if (s != null && e != null && e.isBefore(s)) {
        final swap = s;
        s = e;
        e = swap;
      }
      return ReportWindow(s, e);
  }
}

/// The occurrence list the report prints: every sighting of the plate that
/// passes the operator's filters, in the chosen order.
///
/// The window is also sent to the server, but it is re-applied here so the
/// printed list can never disagree with the printed window (an older server, a
/// clock skew, or a future caller that skips the query params would otherwise
/// leak rows outside the stated range).
///
/// [cameraIds] empty means "every camera", matching the dialog's "All cameras".
List<PlateRead> buildOccurrenceList(
  List<PlateRead> reads, {
  required ReportWindow window,
  required Set<String> cameraIds,
  required ReportSort sort,
}) {
  final out = <PlateRead>[
    for (final r in reads)
      if (window.contains(r.ts) &&
          (cameraIds.isEmpty || cameraIds.contains(r.cameraId)))
        r,
  ];
  out.sort((a, b) => sort == ReportSort.oldestFirst
      ? a.ts.compareTo(b.ts)
      : b.ts.compareTo(a.ts));
  return out;
}

/// Pick which occurrences get a thumbnail: the first [count] entries of the
/// already-filtered, already-ordered [occurrences] that carry a linked
/// detection event (the only authed image source a read exposes), excluding
/// [excludeId] — the subject read, whose images already lead the report.
List<PlateRead> selectThumbCandidates(
  List<PlateRead> occurrences, {
  required String excludeId,
  required int count,
}) {
  if (count <= 0) return const [];
  final out = <PlateRead>[];
  for (final r in occurrences) {
    if (out.length >= count) break;
    if (r.id == excludeId) continue;
    final eid = r.eventId;
    if (eid == null || eid.isEmpty) continue;
    out.add(r);
  }
  return out;
}

/// Every camera the plate was seen on across [reads], for the camera filter.
/// The filter only earns its place when this is more than one.
Set<String> camerasInReads(List<PlateRead> reads) =>
    {for (final r in reads) r.cameraId};

/// The operator's full set of report choices. Mutable — the dialog edits it in
/// place — and cheap to copy for the persistence layer.
class PlateReportOptions {
  PlateReportOptions({
    this.includeHistory = true,
    this.includeOccurrenceList = true,
    this.thumbCount = ReportThumbCount.four,
    this.range = ReportRange.allTime,
    this.customStart,
    this.customEnd,
    Set<String>? cameraIds,
    this.imageType = ReportImageType.both,
    this.sort = ReportSort.newestFirst,
    this.notes = '',
    this.pageSize = ReportPageSize.letter,
  }) : cameraIds = cameraIds ?? <String>{};

  /// The aggregate stats block (totals, first/last seen, distinct cameras).
  bool includeHistory;

  /// The full sighting TABLE. This is the thing the old report was missing:
  /// a plate with 27 sightings printed 4 thumbnails and no list.
  bool includeOccurrenceList;

  ReportThumbCount thumbCount;
  ReportRange range;
  DateTime? customStart;
  DateTime? customEnd;

  /// Empty = every camera.
  Set<String> cameraIds;

  ReportImageType imageType;
  ReportSort sort;

  /// Free text printed on the report. The thing that makes it usable as a
  /// handout to a neighbour, an HOA, or the police.
  String notes;

  ReportPageSize pageSize;

  /// True when the chosen image count is large enough to be worth warning about.
  bool get warnsAboutSize =>
      reportThumbTarget(thumbCount) > kThumbSizeWarningThreshold;
}
