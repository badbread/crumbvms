// Single-plate report: one plate sighting rendered as a clean, helpful one-page
// PDF. This is the composition layer only - a pure function of already-resolved
// inputs (the read, the two embedded images, and the optional sighting-history
// dossier the builder dialog gathered). It does no network I/O so it can't
// stall; the builder dialog (plate_report_dialog.dart) fetches the watchlist,
// the snapshot, crops it to `read.bbox`, and assembles the dossier before
// calling in here.
//
// The header carries the plate, sighting time + timezone, camera, and export
// timestamp. A red watchlist banner leads the page when the plate is on the
// watchlist.
//
// Uses the `pdf` package to compose the document and returns the encoded
// bytes; the builder dialog (plate_report_dialog.dart) previews, prints, or
// shares them. Images arrive as decodable JPEG/PNG bytes and embed as
// `pw.MemoryImage`; the builder skips any that failed to fetch.

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_report_options.dart';

/// A timezone choice for rendering the sighting's moment. [offset] `null` means
/// "use the device's local time"; otherwise it's a fixed offset from UTC that
/// the report applies to the read's instant (Crumb has no IANA tz database, so
/// the picker offers the device local zone plus whole-hour UTC offsets — good
/// enough for a printed report, and the label makes the basis explicit).
class ReportTimezone {
  const ReportTimezone({required this.label, required this.offset});

  final String label; // "Local time", "UTC", "UTC-08:00"
  final Duration? offset; // null → device local; else fixed offset from UTC

  /// Shift [t] into this zone's wall clock. For a fixed offset the result is a
  /// UTC-flagged DateTime whose fields already read as the target zone's local
  /// time; for the device-local choice it's a plain `toLocal()`.
  DateTime shift(DateTime t) =>
      offset == null ? t.toLocal() : t.toUtc().add(offset!);

  /// "Mon D, YYYY  h:mm:ss AM" in this zone.
  String formatDateTime(DateTime t) {
    final d = shift(t);
    final h24 = d.hour;
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final ampm = h24 < 12 ? 'AM' : 'PM';
    final mm = d.minute.toString().padLeft(2, '0');
    final ss = d.second.toString().padLeft(2, '0');
    return '${_months[d.month - 1]} ${d.day}, ${d.year}  $h12:$mm:$ss $ampm';
  }

  /// Short "Mon D, h:mm AM" for compact dossier rows.
  String formatShort(DateTime t) {
    final d = shift(t);
    final h24 = d.hour;
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final ampm = h24 < 12 ? 'AM' : 'PM';
    final mm = d.minute.toString().padLeft(2, '0');
    return '${_months[d.month - 1]} ${d.day}, $h12:$mm $ampm';
  }
}

/// One prior sighting rendered in the dossier thumbnail strip.
class DossierThumb {
  DossierThumb({
    required this.bytes,
    required this.plate,
    required this.cameraName,
    required this.ts,
  });

  final Uint8List bytes; // snapshot JPEG bytes
  final String plate;
  final String cameraName;
  final DateTime ts;
}

/// The "sighting history" section: aggregate stats over every sighting of this
/// plate the caller may see, plus a few thumbnails. Computed client-side by the
/// builder dialog from a `GET /plates?q=<plate>&match=exact` response.
class PlateDossier {
  PlateDossier({
    required this.total,
    required this.distinctCameras,
    required this.firstSeen,
    required this.lastSeen,
    required this.thumbs,
    this.showStats = true,
  });

  /// False when the operator asked for sighting IMAGES but not the summary
  /// counts — the strip still renders, the stat row does not.
  final bool showStats;

  final int total;
  final int distinctCameras;
  final DateTime? firstSeen;
  final DateTime? lastSeen;
  final List<DossierThumb> thumbs;
}

/// One row of the full occurrence table — every sighting of the plate inside
/// the report's window, not just the ones that got a thumbnail. Assembled by
/// the builder dialog from the same `GET /plates` response as the dossier.
class OccurrenceRow {
  const OccurrenceRow({
    required this.ts,
    required this.cameraName,
    required this.source,
    required this.confidence,
    required this.plate,
  });

  final DateTime ts;
  final String cameraName;
  final String source; // engine/source id, or '-' when the server omitted one
  final double? confidence; // 0..1, or null when the engine reported none
  /// The text of THIS read. Normally identical to the subject plate, but a
  /// fuzzy/near match can differ, and hiding that would misrepresent the
  /// evidence.
  final String plate;
}

/// Everything the report needs about the occurrence list: the printed rows,
/// the true total behind them, and whether the fetch hit its ceiling.
class OccurrenceList {
  const OccurrenceList({
    required this.rows,
    required this.total,
    required this.truncated,
    required this.windowLabel,
    required this.cameraLabel,
  });

  final List<OccurrenceRow> rows;

  /// Sightings matched by the report's filters. Equal to `rows.length` unless
  /// the fetch was truncated.
  final int total;

  /// The fetch hit [kMaxOccurrencesFetched]; the report says so rather than
  /// quietly printing a partial list as if it were complete.
  final bool truncated;

  /// "All time" / "Last 30 days" / "Jul 17, 2026 to Aug 7, 2026".
  final String windowLabel;

  /// "All cameras" or the selected camera names.
  final String cameraLabel;
}

/// Compose the report and return the encoded PDF bytes. Pure composition: the
/// builder dialog owns the preview / print / share of the result, so this can
/// be unit-tested without any platform channel.
Future<Uint8List> buildSinglePlateReportPdf({
  required PlateRead read,
  required String cameraName,
  required ReportTimezone tz,
  required DateTime exportedAt,
  required PlateWatchlistEntry? watchMatch,
  required Uint8List? plateCropBytes,
  required bool plateCropIsFallback,
  required Uint8List? vehicleBytes,
  required PlateDossier? dossier,
  OccurrenceList? occurrences,
  ReportImageType imageType = ReportImageType.both,
  ReportPageSize pageSize = ReportPageSize.letter,
  String notes = '',
  String? serverLabel,
}) async {
  final doc = pw.Document();
  final plate = read.plate.isEmpty ? '-' : read.plate;
  // The server-resolved plate name (issue #363) when there is one. The raw
  // plate stays the prominent element either way — a report whose subject is
  // only "Mom's car" is useless to anyone outside this household.
  final plateName = (read.displayName ?? '').trim();

  final plateImg = _tryImage(plateCropBytes);
  final vehicleImg = _tryImage(vehicleBytes);

  final exportedAtStr = tz.formatDateTime(exportedAt);
  final sightingStr = tz.formatDateTime(read.ts);
  final trimmedNotes = notes.trim();

  doc.addPage(
    pw.MultiPage(
      pageFormat: pageSize == ReportPageSize.a4
          ? PdfPageFormat.a4
          : PdfPageFormat.letter,
      margin: const pw.EdgeInsets.fromLTRB(30, 30, 30, 48),
      footer: _footer,
      build: (ctx) => [
        _headerBand(exportedAtStr: exportedAtStr, serverLabel: serverLabel),
        pw.SizedBox(height: 12),
        if (watchMatch != null) ...[
          _boloBanner(watchMatch),
          pw.SizedBox(height: 12),
        ],
        _plateHeaderBlock(
          plate: plate,
          plateName: plateName,
          confidence: read.confidence,
          sightingStr: sightingStr,
          tzLabel: tz.label,
          cameraName: cameraName,
        ),
        pw.SizedBox(height: 14),
        _imagesRow(
          plateImg: plateImg,
          plateIsFallback: plateCropIsFallback,
          vehicleImg: vehicleImg,
          imageType: imageType,
        ),
        pw.SizedBox(height: 14),
        _detailsBlock(read),
        if (trimmedNotes.isNotEmpty) ...[
          pw.SizedBox(height: 14),
          _notesBlock(trimmedNotes),
        ],
        if (dossier != null) ...[
          pw.SizedBox(height: 16),
          _dossierBlock(dossier, tz),
        ],
        // The occurrence table is returned as its own top-level child so
        // pw.MultiPage can split it across pages; a table nested inside a
        // Container cannot break and would overflow a long history.
        if (occurrences != null && occurrences.rows.isNotEmpty) ...[
          pw.SizedBox(height: 16),
          _occurrenceHeading(occurrences),
          pw.SizedBox(height: 6),
          _occurrenceTable(occurrences, tz),
          if (occurrences.truncated) ...[
            pw.SizedBox(height: 6),
            pw.Text(
              'List truncated at ${occurrences.rows.length} of '
              '${occurrences.total} sightings.',
              style: const pw.TextStyle(
                fontSize: 8,
                color: PdfColor.fromInt(0xFFC22B2B),
              ),
            ),
          ],
        ],
      ],
    ),
  );

  return doc.save();
}

// ─── sections ──────────────────────────────────────────────────────────────

pw.Widget _headerBand({
  required String exportedAtStr,
  String? serverLabel,
}) {
  final site = (serverLabel ?? '').trim();
  return pw.Container(
    decoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF2A2D35)),
    padding: const pw.EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          'License Plate Sighting Report',
          style: pw.TextStyle(
            fontSize: 18,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.white,
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            // Which Crumb produced this. A report handed to a third party is
            // evidence; saying where it came from is part of that.
            if (site.isNotEmpty)
              pw.Text(
                site,
                style: const pw.TextStyle(
                  fontSize: 8,
                  color: PdfColor.fromInt(0xFFAAB0BC),
                ),
              ),
            pw.Text(
              'Generated $exportedAtStr',
              style: const pw.TextStyle(
                fontSize: 8,
                color: PdfColor.fromInt(0xFFAAB0BC),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

pw.Widget _boloBanner(PlateWatchlistEntry entry) {
  final parts = <String>[];
  if (entry.label != null && entry.label!.trim().isNotEmpty) {
    parts.add(entry.label!.trim());
  }
  if (entry.note != null && entry.note!.trim().isNotEmpty) {
    parts.add(entry.note!.trim());
  }
  final detail = parts.isEmpty ? 'On watchlist' : parts.join(' - ');
  return pw.Container(
    width: double.infinity,
    decoration: pw.BoxDecoration(
      color: const PdfColor.fromInt(0xFFFBE7E7),
      border: pw.Border.all(color: const PdfColor.fromInt(0xFFC22B2B), width: 1),
      borderRadius: pw.BorderRadius.circular(4),
    ),
    padding: const pw.EdgeInsets.fromLTRB(12, 10, 12, 10),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(0xFFC22B2B),
            borderRadius: pw.BorderRadius.all(pw.Radius.circular(3)),
          ),
          child: pw.Text(
            'BOLO',
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
              letterSpacing: 1,
            ),
          ),
        ),
        pw.SizedBox(width: 10),
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Watchlisted plate',
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: const PdfColor.fromInt(0xFF8A1F1F),
                ),
              ),
              pw.SizedBox(height: 1),
              pw.Text(
                detail,
                style: const pw.TextStyle(
                  fontSize: 9.5,
                  color: PdfColor.fromInt(0xFF5A1414),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

pw.Widget _plateHeaderBlock({
  required String plate,
  required String plateName,
  required double? confidence,
  required String sightingStr,
  required String tzLabel,
  required String cameraName,
}) {
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.center,
    children: [
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: pw.BoxDecoration(
          color: const PdfColor.fromInt(0xFFF2F3F5),
          border: pw.Border.all(
            color: const PdfColor.fromInt(0xFF20242C),
            width: 1.5,
          ),
          borderRadius: pw.BorderRadius.circular(6),
        ),
        child: pw.Text(
          plate,
          style: pw.TextStyle(
            fontSize: 34,
            font: pw.Font.courierBold(),
            fontWeight: pw.FontWeight.bold,
            letterSpacing: 3,
            color: const PdfColor.fromInt(0xFF14171C),
          ),
        ),
      ),
      pw.SizedBox(width: 18),
      pw.Expanded(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (plateName.isNotEmpty) ...[
              pw.Text(
                plateName,
                maxLines: 1,
                overflow: pw.TextOverflow.clip,
                style: pw.TextStyle(
                  fontSize: 15,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.black,
                ),
              ),
              pw.Text(
                'Operator-assigned name',
                style: const pw.TextStyle(
                  fontSize: 7,
                  color: PdfColors.grey600,
                ),
              ),
              pw.SizedBox(height: 6),
            ],
            _confidenceChip(confidence),
            pw.SizedBox(height: 8),
            pw.Text(
              sightingStr,
              style: pw.TextStyle(
                fontSize: 13,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.black,
              ),
            ),
            pw.Text(
              tzLabel,
              style: const pw.TextStyle(
                fontSize: 8,
                color: PdfColors.grey600,
              ),
            ),
            pw.SizedBox(height: 6),
            pw.Row(
              children: [
                pw.Text(
                  'Camera:  ',
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey700,
                  ),
                ),
                pw.Expanded(
                  child: pw.Text(
                    cameraName,
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.black,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}

pw.Widget _confidenceChip(double? confidence) {
  if (confidence == null) {
    return _chip('Confidence -', const PdfColor.fromInt(0xFF8B92A0));
  }
  final pct = (confidence * 100).round();
  final color = confidence >= 0.85
      ? const PdfColor.fromInt(0xFF2E9E5B)
      : confidence >= 0.6
          ? const PdfColor.fromInt(0xFFC98A1E)
          : const PdfColor.fromInt(0xFFC22B2B);
  return _chip('Confidence $pct%', color);
}

pw.Widget _chip(String text, PdfColor color) => pw.Container(
  padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
  decoration: pw.BoxDecoration(
    border: pw.Border.all(color: color, width: 1),
    borderRadius: pw.BorderRadius.circular(10),
  ),
  child: pw.Text(
    text,
    style: pw.TextStyle(
      fontSize: 9,
      fontWeight: pw.FontWeight.bold,
      color: color,
    ),
  ),
);

pw.Widget _imagesRow({
  required pw.MemoryImage? plateImg,
  required bool plateIsFallback,
  required pw.MemoryImage? vehicleImg,
  required ReportImageType imageType,
}) {
  final wantPlate = imageType != ReportImageType.vehicleOnly;
  final wantVehicle = imageType != ReportImageType.plateOnly;
  // One image alone gets the full width and more height - it is the whole
  // visual evidence on the page, so shrinking it to half a row would be
  // strictly worse than the two-up layout it replaced.
  final solo = wantPlate != wantVehicle;
  final height = solo ? 230.0 : 150.0;
  final panels = <pw.Widget>[
    if (wantPlate)
      _imagePanel(
        title: plateIsFallback
            ? 'Plate region (full frame - no crop box)'
            : 'License plate',
        img: plateImg,
        height: height,
      ),
    if (wantVehicle)
      _imagePanel(title: 'Vehicle', img: vehicleImg, height: height),
  ];
  if (panels.isEmpty) return pw.SizedBox();
  if (panels.length == 1) return panels.first;
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(child: panels[0]),
      pw.SizedBox(width: 12),
      pw.Expanded(child: panels[1]),
    ],
  );
}

/// Free-text operator notes, printed verbatim. What turns the report from a
/// data dump into something you can hand to a neighbour or an officer.
pw.Widget _notesBlock(String notes) {
  return pw.Container(
    width: double.infinity,
    decoration: pw.BoxDecoration(
      color: const PdfColor.fromInt(0xFFFFFBEA),
      border:
          pw.Border.all(color: const PdfColor.fromInt(0xFFE0CE8A), width: 0.5),
      borderRadius: pw.BorderRadius.circular(4),
    ),
    padding: const pw.EdgeInsets.all(10),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Notes',
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.grey800,
          ),
        ),
        pw.SizedBox(height: 5),
        pw.Text(notes, style: const pw.TextStyle(fontSize: 9.5)),
      ],
    ),
  );
}

/// Heading above the occurrence table: what the list covers and how much of it
/// there is. Separate from the table itself so pw.MultiPage can page-break
/// between them.
pw.Widget _occurrenceHeading(OccurrenceList list) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        'All sightings (${list.total})',
        style: pw.TextStyle(
          fontSize: 11,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.grey800,
        ),
      ),
      pw.SizedBox(height: 2),
      pw.Text(
        '${list.windowLabel}  -  ${list.cameraLabel}',
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
      ),
    ],
  );
}

/// Every sighting as a row. A direct child of the pw.MultiPage build list, so
/// the `pdf` package splits it across pages and repeats the header row.
pw.Widget _occurrenceTable(OccurrenceList list, ReportTimezone tz) {
  pw.Widget cell(String text, {bool head = false, bool mono = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        child: pw.Text(
          text,
          maxLines: 1,
          overflow: pw.TextOverflow.clip,
          style: pw.TextStyle(
            fontSize: head ? 7.5 : 8.5,
            font: mono ? pw.Font.courier() : null,
            fontWeight: head ? pw.FontWeight.bold : pw.FontWeight.normal,
            color: head ? PdfColors.grey700 : PdfColors.black,
            letterSpacing: head ? 0.4 : 0,
          ),
        ),
      );

  return pw.Table(
    border: pw.TableBorder.symmetric(
      inside: const pw.BorderSide(color: PdfColors.grey300, width: 0.4),
    ),
    columnWidths: const {
      0: pw.FixedColumnWidth(28), // #
      1: pw.FlexColumnWidth(3.1), // when
      2: pw.FlexColumnWidth(2.6), // camera
      3: pw.FlexColumnWidth(1.7), // plate as read
      4: pw.FlexColumnWidth(1.7), // source
      5: pw.FixedColumnWidth(46), // confidence
    },
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        repeat: true, // header repeats on every page the table spills onto
        children: [
          cell('#', head: true),
          cell('WHEN', head: true),
          cell('CAMERA', head: true),
          cell('READ AS', head: true),
          cell('SOURCE', head: true),
          cell('CONF.', head: true),
        ],
      ),
      for (var i = 0; i < list.rows.length; i++)
        pw.TableRow(
          children: [
            cell('${i + 1}'),
            cell(tz.formatDateTime(list.rows[i].ts)),
            cell(list.rows[i].cameraName),
            cell(
              list.rows[i].plate.isEmpty ? '-' : list.rows[i].plate,
              mono: true,
            ),
            cell(list.rows[i].source),
            cell(list.rows[i].confidence == null
                ? '-'
                : '${(list.rows[i].confidence! * 100).round()}%'),
          ],
        ),
    ],
  );
}

pw.Widget _imagePanel({
  required String title,
  required pw.MemoryImage? img,
  required double height,
}) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        title,
        style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
      ),
      pw.SizedBox(height: 3),
      pw.Container(
        height: height,
        width: double.infinity,
        decoration: pw.BoxDecoration(
          color: PdfColors.grey200,
          border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
        ),
        alignment: pw.Alignment.center,
        child: img == null
            ? pw.Text(
                'No image',
                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey),
              )
            : pw.Image(img, height: height, fit: pw.BoxFit.contain),
      ),
    ],
  );
}

pw.Widget _detailsBlock(PlateRead read) {
  final rows = <List<String>>[
    ['OCR raw', read.plateRaw.isEmpty ? '-' : read.plateRaw],
    ['Source', (read.sourceId ?? '').isEmpty ? '-' : read.sourceId!],
  ];
  return pw.Container(
    width: double.infinity,
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
      borderRadius: pw.BorderRadius.circular(4),
    ),
    padding: const pw.EdgeInsets.all(10),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Read details',
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.grey800,
          ),
        ),
        pw.SizedBox(height: 6),
        pw.Table(
          columnWidths: const {
            0: pw.FixedColumnWidth(90),
            1: pw.FlexColumnWidth(),
          },
          children: [
            for (final r in rows)
              pw.TableRow(
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(vertical: 2),
                    child: pw.Text(
                      r[0],
                      style: const pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.grey600,
                      ),
                    ),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(vertical: 2),
                    child: pw.Text(
                      r[1],
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    ),
  );
}

pw.Widget _dossierBlock(PlateDossier d, ReportTimezone tz) {
  final decoded = <DossierThumb, pw.MemoryImage>{};
  for (final t in d.thumbs) {
    final img = _tryImage(t.bytes);
    if (img != null) decoded[t] = img;
  }
  return pw.Container(
    width: double.infinity,
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
      borderRadius: pw.BorderRadius.circular(4),
    ),
    padding: const pw.EdgeInsets.all(10),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Sighting history',
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.grey800,
          ),
        ),
        if (d.showStats) ...[
          pw.SizedBox(height: 8),
          pw.Row(
            children: [
              _statCol('Total sightings', '${d.total}'),
              _statCol('Distinct cameras', '${d.distinctCameras}'),
              _statCol(
                'First seen',
                d.firstSeen == null ? '-' : tz.formatShort(d.firstSeen!),
              ),
              _statCol(
                'Last seen',
                d.lastSeen == null ? '-' : tz.formatShort(d.lastSeen!),
              ),
            ],
          ),
        ],
        if (d.thumbs.isNotEmpty) ...[
          pw.SizedBox(height: 10),
          pw.Text(
            'Other sightings',
            style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 4),
          // Wrapped into fixed-width rows rather than one Row of Expanded
          // children: the operator can now ask for up to kMaxReportThumbs
          // images, and 24 of them sharing one row would be a smear.
          for (var start = 0; start < d.thumbs.length; start += _thumbsPerRow)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 6),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  for (var i = start;
                      i < start + _thumbsPerRow && i < d.thumbs.length;
                      i++) ...[
                    pw.Expanded(child: _thumbCell(d.thumbs[i], decoded, tz)),
                    pw.SizedBox(width: 6),
                  ],
                  // Pad a short final row so its cells keep the same width as
                  // the full rows above instead of stretching.
                  for (var i = d.thumbs.length; i < start + _thumbsPerRow; i++)
                    ...[
                      pw.Expanded(child: pw.SizedBox()),
                      pw.SizedBox(width: 6),
                    ],
                ],
              ),
            ),
        ],
      ],
    ),
  );
}

/// How many sighting thumbnails share one row of the strip.
const int _thumbsPerRow = 4;

/// One thumbnail cell: the image over its time and camera.
pw.Widget _thumbCell(
  DossierThumb t,
  Map<DossierThumb, pw.MemoryImage> decoded,
  ReportTimezone tz,
) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Container(
        height: 62,
        width: double.infinity,
        decoration: pw.BoxDecoration(
          color: PdfColors.grey200,
          border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
        ),
        alignment: pw.Alignment.center,
        child: decoded[t] == null
            ? pw.Text(
                '-',
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey),
              )
            : pw.Image(decoded[t]!, fit: pw.BoxFit.cover),
      ),
      pw.SizedBox(height: 2),
      pw.Text(
        tz.formatShort(t.ts),
        style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
      ),
      pw.Text(
        t.cameraName,
        maxLines: 1,
        overflow: pw.TextOverflow.clip,
        style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
      ),
    ],
  );
}

pw.Widget _statCol(String label, String value) => pw.Expanded(
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        label.toUpperCase(),
        style: const pw.TextStyle(
          fontSize: 7,
          color: PdfColors.grey600,
          letterSpacing: 0.5,
        ),
      ),
      pw.SizedBox(height: 2),
      pw.Text(
        value,
        style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
      ),
    ],
  ),
);

pw.Widget _footer(pw.Context ctx) {
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Container(height: 0.5, color: PdfColors.grey400),
      pw.SizedBox(height: 4),
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
        ),
      ),
    ],
  );
}

// ─── helpers ─────────────────────────────────────────────────────────────

/// Decode image bytes into a `pw.MemoryImage`, or null if undecodable — a bad
/// byte-run drops that one image rather than failing the whole report.
pw.MemoryImage? _tryImage(Uint8List? bytes) {
  if (bytes == null) return null;
  try {
    return pw.MemoryImage(bytes);
  } catch (_) {
    return null;
  }
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
