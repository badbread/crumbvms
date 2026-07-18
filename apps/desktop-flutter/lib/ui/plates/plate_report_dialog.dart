// Builder dialog for the single-plate report: pick a timezone, choose which
// sections to include, then "Download PDF". On download this gathers everything
// the report composition (plate_pdf_report.dart) needs - the watchlist (for the
// watchlist banner), the detection snapshot (cropped to the plate's `bbox`, or
// the full frame as a fallback), and the sighting-history dossier - then hands
// the assembled PDF to the OS share/save dialog.
//
// The dialog owns no snapshot plumbing of its own: the Plates screen passes a
// [fetchSnapshot] callback wired to its existing bounded-concurrency snapshot
// helper + cache, so this reuses the same fetch path the thumbnails do.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_crop.dart';
import 'package:crumb_desktop/ui/plates/plate_pdf_report.dart';

/// How many other sightings to embed in the dossier's thumbnail strip.
const _dossierThumbCount = 4;

/// Show the single-plate report builder for [read]. Returns when the dialog is
/// dismissed (it drives its own share/save on "Download PDF").
Future<void> showPlateReportBuilder(
  BuildContext context, {
  required CrumbApi api,
  required Session session,
  required PlateRead read,
  required List<Camera> cameras,
  required Future<Uint8List?> Function(String eventId) fetchSnapshot,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _PlateReportDialog(
      api: api,
      session: session,
      read: read,
      cameras: cameras,
      fetchSnapshot: fetchSnapshot,
    ),
  );
}

class _PlateReportDialog extends StatefulWidget {
  const _PlateReportDialog({
    required this.api,
    required this.session,
    required this.read,
    required this.cameras,
    required this.fetchSnapshot,
  });

  final CrumbApi api;
  final Session session;
  final PlateRead read;
  final List<Camera> cameras;
  final Future<Uint8List?> Function(String eventId) fetchSnapshot;

  @override
  State<_PlateReportDialog> createState() => _PlateReportDialogState();
}

class _PlateReportDialogState extends State<_PlateReportDialog> {
  late final List<ReportTimezone> _tzOptions = _buildTimezoneOptions();
  late ReportTimezone _tz = _tzOptions.first; // device-local default
  bool _includeDossier = true;

  bool _busy = false;
  String? _error;

  String _camName(String id) {
    for (final c in widget.cameras) {
      if (c.id == id) return c.name;
    }
    return '(unknown camera)';
  }

  Future<void> _generate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final read = widget.read;

      // Watchlist match -> banner. Only a "watch" entry raises the banner
      // (an "ignore" entry would have dropped the read server-side).
      PlateWatchlistEntry? watchMatch;
      if (read.plate.isNotEmpty) {
        try {
          final wl = await widget.api.listWatchlist(widget.session);
          for (final e in wl) {
            if (!e.isIgnore && e.plate == read.plate) {
              watchMatch = e;
              break;
            }
          }
        } catch (_) {/* no banner on failure */}
      }

      // The detection snapshot: the plate crop (bbox) + the full vehicle frame.
      Uint8List? fullSnapshot;
      final eid = read.eventId;
      if (eid != null && eid.isNotEmpty) {
        fullSnapshot = await widget.fetchSnapshot(eid);
      }
      Uint8List? plateCrop;
      var cropIsFallback = true;
      if (fullSnapshot != null && read.bbox != null) {
        final cropped = await cropPlateToBbox(fullSnapshot, read.bbox!);
        if (cropped != null) {
          plateCrop = cropped.$1;
          cropIsFallback = false;
        }
      }
      // bbox null / crop failed / no snapshot → fall back to the full frame
      // (labeled as such by the report), so we always show what we have.
      plateCrop ??= fullSnapshot;

      // Sighting-history dossier (optional).
      PlateDossier? dossier;
      if (_includeDossier && read.plate.isNotEmpty) {
        dossier = await _buildDossier(read);
      }

      if (!mounted) return;
      await shareSinglePlateReportPdf(
        read: read,
        cameraName: _camName(read.cameraId),
        tz: _tz,
        exportedAt: DateTime.now(),
        watchMatch: watchMatch,
        plateCropBytes: plateCrop,
        plateCropIsFallback: cropIsFallback,
        vehicleBytes: fullSnapshot,
        dossier: dossier,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Report failed: $e';
        _busy = false;
      });
    }
  }

  /// Gather every visible sighting of this plate (`GET /plates?q=<plate>
  /// &match=exact` over all held cameras) and reduce it client-side to the
  /// dossier stats + a few thumbnails.
  Future<PlateDossier> _buildDossier(PlateRead read) async {
    final camIds = widget.cameras.map((c) => c.id).toList(growable: false);
    final page = await widget.api.listPlates(
      widget.session,
      cameraIds: camIds,
      query: read.plate,
      match: 'exact',
      limit: 100,
    );
    final reads = page.plates;
    final cams = <String>{};
    DateTime? first;
    DateTime? last;
    for (final r in reads) {
      cams.add(r.cameraId);
      if (first == null || r.ts.isBefore(first)) first = r.ts;
      if (last == null || r.ts.isAfter(last)) last = r.ts;
    }
    // A few OTHER sightings (newest first) that have a resolvable snapshot.
    final others = reads
        .where((r) =>
            r.id != read.id && (r.eventId != null && r.eventId!.isNotEmpty))
        .toList()
      ..sort((a, b) => b.ts.compareTo(a.ts));
    final thumbs = <DossierThumb>[];
    for (final r in others.take(_dossierThumbCount)) {
      final bytes = await widget.fetchSnapshot(r.eventId!);
      if (bytes != null) {
        thumbs.add(DossierThumb(
          bytes: bytes,
          plate: r.plate,
          cameraName: _camName(r.cameraId),
          ts: r.ts,
        ));
      }
    }
    return PlateDossier(
      total: page.total,
      distinctCameras: cams.length,
      firstSeen: first,
      lastSeen: last,
      thumbs: thumbs,
    );
  }

  @override
  Widget build(BuildContext context) {
    final read = widget.read;
    final plate = read.plate.isEmpty ? '—' : read.plate;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.description_outlined, size: 20),
          const SizedBox(width: 8),
          const Text('Plate report'),
          const Spacer(),
          Text(
            plate,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<ReportTimezone>(
              initialValue: _tz,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Timezone',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final tz in _tzOptions)
                  DropdownMenuItem(value: tz, child: Text(tz.label)),
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      if (v != null) setState(() => _tz = v);
                    },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _includeDossier,
              onChanged:
                  _busy ? null : (v) => setState(() => _includeDossier = v),
              title: const Text('Include sighting history'),
              subtitle: const Text(
                'Every visible sighting of this plate: counts, '
                'first/last seen, and thumbnails.',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _generate,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.picture_as_pdf_outlined, size: 18),
          label: Text(_busy ? 'Building…' : 'Download PDF'),
        ),
      ],
    );
  }
}

// ─── helpers ─────────────────────────────────────────────────────────────

// The plate crop (bbox → cropped JPEG) lives in plate_crop.dart, shared with
// the Plates gallery/detail crop so all three paths use one implementation.

/// The device-local zone plus UTC and whole-hour offsets. Crumb ships no IANA
/// tz database, so a fixed-offset picker is the honest, dependency-free option
/// for a printed timestamp; the label states the basis on the report.
List<ReportTimezone> _buildTimezoneOptions() {
  final local = DateTime.now().timeZoneOffset;
  final opts = <ReportTimezone>[
    ReportTimezone(label: 'Local time (${_offsetLabel(local)})', offset: null),
    const ReportTimezone(label: 'UTC', offset: Duration.zero),
  ];
  for (var hours = -12; hours <= 14; hours++) {
    if (hours == 0) continue; // UTC already added above
    final d = Duration(hours: hours);
    opts.add(ReportTimezone(label: 'UTC${_offsetLabel(d)}', offset: d));
  }
  return opts;
}

String _offsetLabel(Duration d) {
  final neg = d.isNegative;
  final abs = d.abs();
  final hh = abs.inHours.toString().padLeft(2, '0');
  final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
  return '${neg ? '-' : '+'}$hh:$mm';
}
