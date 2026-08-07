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
// Uses the `pdf` package to compose the document and `printing`'s share/save
// dialog to write it out (Windows desktop target). Images arrive as decodable
// JPEG/PNG bytes and embed as `pw.MemoryImage`; the builder skips any that
// failed to fetch.

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'package:crumb_desktop/api/plates_api.dart';

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
  });

  final int total;
  final int distinctCameras;
  final DateTime? firstSeen;
  final DateTime? lastSeen;
  final List<DossierThumb> thumbs;
}

/// Build the single-plate report PDF and hand it to the OS share/save dialog.
Future<void> shareSinglePlateReportPdf({
  required PlateRead read,
  required String cameraName,
  required ReportTimezone tz,
  required DateTime exportedAt,
  required PlateWatchlistEntry? watchMatch,
  required Uint8List? plateCropBytes,
  required bool plateCropIsFallback,
  required Uint8List? vehicleBytes,
  required PlateDossier? dossier,
  String? filename,
}) async {
  final bytes = await buildSinglePlateReportPdf(
    read: read,
    cameraName: cameraName,
    tz: tz,
    exportedAt: exportedAt,
    watchMatch: watchMatch,
    plateCropBytes: plateCropBytes,
    plateCropIsFallback: plateCropIsFallback,
    vehicleBytes: vehicleBytes,
    dossier: dossier,
  );
  final plateSlug = read.plate.isEmpty
      ? 'plate'
      : read.plate.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  await Printing.sharePdf(
    bytes: bytes,
    filename: filename ?? 'crumb-plate-$plateSlug-${_fileStamp(exportedAt)}.pdf',
  );
}

/// `yyyyMMdd-HHmm` in the device's local zone, for the PDF filename.
String _fileStamp(DateTime t) {
  final d = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}';
}

/// Compose the report and return the encoded PDF bytes (split out from
/// [shareSinglePlateReportPdf] so it can be unit-tested without the share
/// channel).
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
}) async {
  final doc = pw.Document();
  final plate = read.plate.isEmpty ? '-' : read.plate;

  final plateImg = _tryImage(plateCropBytes);
  final vehicleImg = _tryImage(vehicleBytes);

  final exportedAtStr = tz.formatDateTime(exportedAt);
  final sightingStr = tz.formatDateTime(read.ts);

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.letter,
      margin: const pw.EdgeInsets.fromLTRB(30, 30, 30, 48),
      footer: _footer,
      build: (ctx) => [
        _headerBand(exportedAtStr: exportedAtStr),
        pw.SizedBox(height: 12),
        if (watchMatch != null) ...[
          _boloBanner(watchMatch),
          pw.SizedBox(height: 12),
        ],
        _plateHeaderBlock(
          plate: plate,
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
        ),
        pw.SizedBox(height: 14),
        _detailsBlock(read),
        if (dossier != null) ...[
          pw.SizedBox(height: 16),
          _dossierBlock(dossier, tz),
        ],
      ],
    ),
  );

  return doc.save();
}

// ─── sections ──────────────────────────────────────────────────────────────

pw.Widget _headerBand({required String exportedAtStr}) {
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
        pw.Text(
          'Exported $exportedAtStr',
          style: const pw.TextStyle(
            fontSize: 8,
            color: PdfColor.fromInt(0xFFAAB0BC),
          ),
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
}) {
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        child: _imagePanel(
          title: plateIsFallback
              ? 'Plate region (full frame - no crop box)'
              : 'License plate',
          img: plateImg,
          height: 150,
        ),
      ),
      pw.SizedBox(width: 12),
      pw.Expanded(
        child: _imagePanel(
          title: 'Vehicle',
          img: vehicleImg,
          height: 150,
        ),
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
        if (d.thumbs.isNotEmpty) ...[
          pw.SizedBox(height: 10),
          pw.Text(
            'Other sightings',
            style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 4),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              for (final t in d.thumbs) ...[
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Container(
                        height: 62,
                        width: double.infinity,
                        decoration: pw.BoxDecoration(
                          color: PdfColors.grey200,
                          border: pw.Border.all(
                            color: PdfColors.grey400,
                            width: 0.5,
                          ),
                        ),
                        alignment: pw.Alignment.center,
                        child: decoded[t] == null
                            ? pw.Text(
                                '-',
                                style: const pw.TextStyle(
                                  fontSize: 8,
                                  color: PdfColors.grey,
                                ),
                              )
                            : pw.Image(decoded[t]!, fit: pw.BoxFit.cover),
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        tz.formatShort(t.ts),
                        style: const pw.TextStyle(
                          fontSize: 7,
                          color: PdfColors.grey700,
                        ),
                      ),
                      pw.Text(
                        t.cameraName,
                        maxLines: 1,
                        overflow: pw.TextOverflow.clip,
                        style: const pw.TextStyle(
                          fontSize: 7,
                          color: PdfColors.grey600,
                        ),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(width: 6),
              ],
            ],
          ),
        ],
      ],
    ),
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
