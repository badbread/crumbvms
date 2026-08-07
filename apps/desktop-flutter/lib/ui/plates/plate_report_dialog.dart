// Builder for the single-plate report: choose what goes on it, SEE it, then
// print or download. Two panes in one dialog — an options form and an in-app
// PDF preview — because a report you cannot look at before handing it to a
// neighbour, an HOA, or an officer is a report you have to generate twice.
//
// On open the dialog pulls this plate's full sighting history ONCE (paged
// `GET /plates?q=<plate>&match=exact` over the operator's cameras, bounded by
// [kMaxOccurrencesFetched]) and then derives everything from that in memory:
// the live "N sightings across M cameras" summary, the camera filter's
// options, the dossier stats, and the occurrence table. Changing an option
// re-renders the PDF; it does not re-hit the server.
//
// The dialog owns no snapshot plumbing of its own: the Plates screen passes a
// [fetchSnapshot] callback wired to its existing bounded-concurrency snapshot
// helper + cache, so this reuses the same fetch path the thumbnails do.
//
// PDF SIZE. Detection frames are stored at full camera resolution and the
// report draws sighting thumbnails a couple of centimetres wide, so every
// embedded sighting image is downscaled client-side (`downscaleForReport`)
// before it is handed to the composition layer. The subject read's own two
// images stay full quality — they are the evidence. There is no server-side
// downscaled derivative to ask for: `GET /events/:id/snapshot` returns the
// stored frame verbatim, and `GET /plates/:id/crop` the stored crop verbatim
// (the `?w=` / `?tight=1` derivatives proposed under #394 were never merged).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_crop.dart';
import 'package:crumb_desktop/ui/plates/plate_pdf_report.dart';
import 'package:crumb_desktop/ui/plates/plate_report_options.dart';
import 'package:crumb_desktop/ui/plates/plates_prefs.dart';

/// One `GET /plates` page is capped at 1 000 server-side; ask for that and page
/// until [kMaxOccurrencesFetched].
const _historyPageSize = 500;

/// Show the single-plate report builder for [read]. Returns when the dialog is
/// dismissed (it drives its own preview/print/share).
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
  PlateReportOptions _opts = PlateReportOptions();
  final TextEditingController _notesCtrl = TextEditingController();

  /// Every sighting of this plate the operator may see, all-time, newest first.
  /// Fetched once on open; the options filter this list rather than re-querying.
  List<PlateRead> _history = const [];
  bool _historyLoading = true;
  bool _historyTruncated = false;
  String? _historyError;

  bool _busy = false;
  String? _error;

  /// Rendered PDF for the preview pane; null while showing the options form.
  Uint8List? _preview;

  @override
  void initState() {
    super.initState();
    _restoreOptions();
    _loadHistory();
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _restoreOptions() async {
    final saved = await PlatesPrefs.getReportOptions();
    if (!mounted) return;
    setState(() => _opts = saved);
  }

  String _camName(String id) {
    for (final c in widget.cameras) {
      if (c.id == id) return c.name;
    }
    return '(unknown camera)';
  }

  /// Pull this plate's whole visible history, paging up to the ceiling. Errors
  /// are surfaced but non-fatal: the subject read's own page still renders.
  Future<void> _loadHistory() async {
    final plate = widget.read.plate;
    if (plate.isEmpty) {
      setState(() => _historyLoading = false);
      return;
    }
    final camIds = widget.cameras.map((c) => c.id).toList(growable: false);
    final all = <PlateRead>[];
    var truncated = false;
    try {
      var offset = 0;
      while (true) {
        final page = await widget.api.listPlates(
          widget.session,
          cameraIds: camIds,
          query: plate,
          match: 'exact',
          limit: _historyPageSize,
          offset: offset,
        );
        all.addAll(page.plates);
        if (!page.hasMore || page.plates.isEmpty) break;
        offset += page.plates.length;
        if (all.length >= kMaxOccurrencesFetched) {
          truncated = true;
          break;
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _historyError = 'Could not load sighting history: $e';
        _historyLoading = false;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _history = all;
      _historyTruncated = truncated;
      _historyLoading = false;
    });
  }

  ReportWindow get _window => resolveReportWindow(
        _opts.range,
        now: DateTime.now(),
        customStart: _opts.customStart,
        customEnd: _opts.customEnd,
      );

  List<PlateRead> get _occurrences => buildOccurrenceList(
        _history,
        window: _window,
        cameraIds: _opts.cameraIds,
        sort: _opts.sort,
      );

  /// Cameras this plate was actually seen on. The camera filter only earns its
  /// place when there is more than one.
  List<String> get _historyCameras {
    final ids = camerasInReads(_history).toList()
      ..sort((a, b) => _camName(a).compareTo(_camName(b)));
    return ids;
  }

  String get _windowLabel {
    if (_opts.range != ReportRange.custom) return reportRangeLabel(_opts.range);
    final w = _window;
    if (w.isUnbounded) return 'All time';
    final from = w.start == null ? 'earliest' : _tz.formatShort(w.start!);
    final to = w.end == null ? 'now' : _tz.formatShort(w.end!);
    return '$from to $to';
  }

  String get _cameraLabel {
    if (_opts.cameraIds.isEmpty) return 'All cameras';
    final names = _opts.cameraIds.map(_camName).toList()..sort();
    return names.join(', ');
  }

  // ─── assembly ────────────────────────────────────────────────────────────

  /// Gather everything the composition layer needs and return the PDF bytes.
  /// Pure-ish: no dialog state is mutated here beyond the caller's busy flag.
  Future<Uint8List> _composePdf() async {
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

    // The subject read's own images, kept at full quality — this is the
    // evidence the report exists to show.
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

    final occurrences = _occurrences;

    // Sighting thumbnails, downscaled before embedding.
    final thumbs = <DossierThumb>[];
    final wanted = cappedThumbCount(_opts.thumbCount, occurrences.length);
    for (final r in selectThumbCandidates(
      occurrences,
      excludeId: read.id,
      count: wanted,
    )) {
      final bytes = await widget.fetchSnapshot(r.eventId!);
      if (bytes == null) continue;
      thumbs.add(DossierThumb(
        bytes: await downscaleForReport(bytes),
        plate: r.plate,
        cameraName: _camName(r.cameraId),
        ts: r.ts,
      ));
    }

    PlateDossier? dossier;
    if (_opts.includeHistory) {
      DateTime? first;
      DateTime? last;
      for (final r in occurrences) {
        if (first == null || r.ts.isBefore(first)) first = r.ts;
        if (last == null || r.ts.isAfter(last)) last = r.ts;
      }
      dossier = PlateDossier(
        total: occurrences.length,
        distinctCameras: camerasInReads(occurrences).length,
        firstSeen: first,
        lastSeen: last,
        thumbs: thumbs,
      );
    } else if (thumbs.isNotEmpty) {
      // Sighting images without the summary counts the operator turned off.
      dossier = PlateDossier(
        total: occurrences.length,
        distinctCameras: camerasInReads(occurrences).length,
        firstSeen: null,
        lastSeen: null,
        thumbs: thumbs,
        showStats: false,
      );
    }

    OccurrenceList? list;
    if (_opts.includeOccurrenceList && occurrences.isNotEmpty) {
      list = OccurrenceList(
        rows: [
          for (final r in occurrences)
            OccurrenceRow(
              ts: r.ts,
              cameraName: _camName(r.cameraId),
              source: (r.sourceId ?? '').isEmpty ? '-' : r.sourceId!,
              confidence: r.confidence,
              plate: r.plate,
            ),
        ],
        total: occurrences.length,
        truncated: _historyTruncated,
        windowLabel: _windowLabel,
        cameraLabel: _cameraLabel,
      );
    }

    return buildSinglePlateReportPdf(
      read: read,
      cameraName: _camName(read.cameraId),
      tz: _tz,
      exportedAt: DateTime.now(),
      watchMatch: watchMatch,
      plateCropBytes: plateCrop,
      plateCropIsFallback: cropIsFallback,
      vehicleBytes: fullSnapshot,
      dossier: dossier,
      occurrences: list,
      imageType: _opts.imageType,
      pageSize: _opts.pageSize,
      notes: _notesCtrl.text,
      serverLabel: widget.session.base,
    );
  }

  /// Build and switch to the preview pane.
  Future<void> _showPreview() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await _composePdf();
      await PlatesPrefs.setReportOptions(_opts);
      if (!mounted) return;
      setState(() {
        _preview = bytes;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Report failed: $e';
        _busy = false;
      });
    }
  }

  /// Build (if needed) and hand the PDF to the OS share/save dialog. Kept as a
  /// first-class action so an operator who does not want the preview never has
  /// to wait for one.
  Future<void> _download() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = _preview ?? await _composePdf();
      await PlatesPrefs.setReportOptions(_opts);
      await Printing.sharePdf(bytes: bytes, filename: _filename());
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

  String _filename() {
    final slug = widget.read.plate.isEmpty
        ? 'plate'
        : widget.read.plate.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'crumb-plate-$slug-${d.year}${two(d.month)}${two(d.day)}'
        '-${two(d.hour)}${two(d.minute)}.pdf';
  }

  /// Any option edit invalidates a rendered preview, so the pane can never show
  /// a document that no longer matches the form.
  void _edit(VoidCallback change) {
    setState(() {
      change();
      _preview = null;
    });
  }

  // ─── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final read = widget.read;
    final plate = read.plate.isEmpty ? '—' : read.plate;
    final name = (read.displayName ?? '').trim();
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.description_outlined, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    _preview == null ? 'Plate report' : 'Plate report preview',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (name.isNotEmpty) ...[
                    Text(name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 10),
                  ],
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
            ),
            const Divider(height: 1),
            Expanded(
              child: _preview == null
                  ? _buildOptions(context)
                  : PdfPreview(
                      build: (_) => _preview!,
                      allowPrinting: true,
                      allowSharing: true,
                      canChangePageFormat: false,
                      canChangeOrientation: false,
                      canDebug: false,
                      pdfFileName: _filename(),
                      useActions: true,
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  if (_error != null)
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : _preview == null
                            ? () => Navigator.of(context).pop()
                            : () => setState(() => _preview = null),
                    child: Text(_preview == null ? 'Cancel' : 'Back to options'),
                  ),
                  const SizedBox(width: 8),
                  if (_preview == null)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _showPreview,
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      label: const Text('Preview'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _busy ? null : _download,
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOptions(BuildContext context) {
    final occ = _occurrences;
    final cams = _historyCameras;
    final thumbs = cappedThumbCount(_opts.thumbCount, occ.length);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      children: [
        _summaryBar(occ.length, cams.length),
        const SizedBox(height: 14),
        _sectionLabel('What to include'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _opts.includeOccurrenceList,
          onChanged: _busy
              ? null
              : (v) => _edit(() => _opts.includeOccurrenceList = v),
          title: const Text('Full list of sightings'),
          subtitle: const Text(
            'Every sighting in the window as a table: time, camera, how it was '
            'read, source, confidence.',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: _opts.includeHistory,
          onChanged:
              _busy ? null : (v) => _edit(() => _opts.includeHistory = v),
          title: const Text('Summary counts'),
          subtitle: const Text(
            'Totals, distinct cameras, and first/last seen.',
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _dropdown<ReportRange>(
                label: 'Date range',
                value: _opts.range,
                items: ReportRange.values,
                labelOf: reportRangeLabel,
                onChanged: (v) => _edit(() => _opts.range = v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _dropdown<ReportSort>(
                label: 'Order',
                value: _opts.sort,
                items: ReportSort.values,
                labelOf: reportSortLabel,
                onChanged: (v) => _edit(() => _opts.sort = v),
              ),
            ),
          ],
        ),
        if (_opts.range == ReportRange.custom) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _dateField(
                  'From',
                  _opts.customStart,
                  (d) => _edit(() => _opts.customStart = d),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _dateField(
                  'To',
                  _opts.customEnd,
                  (d) => _edit(() => _opts.customEnd = d),
                ),
              ),
            ],
          ),
        ],
        // Only worth showing when the plate actually spans cameras.
        if (cams.length > 1) ...[
          const SizedBox(height: 12),
          _sectionLabel('Cameras'),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              FilterChip(
                label: const Text('All cameras'),
                selected: _opts.cameraIds.isEmpty,
                onSelected:
                    _busy ? null : (_) => _edit(() => _opts.cameraIds.clear()),
              ),
              for (final id in cams)
                FilterChip(
                  label: Text(_camName(id)),
                  selected: _opts.cameraIds.contains(id),
                  onSelected: _busy
                      ? null
                      : (on) => _edit(() {
                            if (on) {
                              _opts.cameraIds.add(id);
                            } else {
                              _opts.cameraIds.remove(id);
                            }
                          }),
                ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        _sectionLabel('Images'),
        Row(
          children: [
            Expanded(
              child: _dropdown<ReportImageType>(
                label: 'Image type',
                value: _opts.imageType,
                items: ReportImageType.values,
                labelOf: reportImageTypeLabel,
                onChanged: (v) => _edit(() => _opts.imageType = v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _dropdown<ReportThumbCount>(
                label: 'Sighting images',
                value: _opts.thumbCount,
                items: ReportThumbCount.values,
                labelOf: reportThumbCountLabel,
                onChanged: (v) => _edit(() => _opts.thumbCount = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          thumbs == 0
              ? 'No sighting images will be embedded.'
              : '$thumbs sighting image${thumbs == 1 ? '' : 's'} will be '
                  'embedded, downscaled for size.'
                  '${_opts.warnsAboutSize ? ' A large PDF takes longer to build.' : ''}',
          style: TextStyle(
            fontSize: 12,
            color: _opts.warnsAboutSize
                ? Theme.of(context).colorScheme.tertiary
                : Theme.of(context).hintColor,
          ),
        ),
        const SizedBox(height: 14),
        _sectionLabel('Presentation'),
        Row(
          children: [
            Expanded(
              child: _dropdown<ReportTimezone>(
                label: 'Timezone',
                value: _tz,
                items: _tzOptions,
                labelOf: (t) => t.label,
                onChanged: (v) => _edit(() => _tz = v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _dropdown<ReportPageSize>(
                label: 'Page size',
                value: _opts.pageSize,
                items: ReportPageSize.values,
                labelOf: reportPageSizeLabel,
                onChanged: (v) => _edit(() => _opts.pageSize = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _notesCtrl,
          minLines: 3,
          maxLines: 6,
          enabled: !_busy,
          onChanged: (_) {
            if (_preview != null) setState(() => _preview = null);
          },
          decoration: const InputDecoration(
            labelText: 'Notes (printed on the report)',
            hintText:
                'Context for whoever receives this: what happened, when, what '
                'you are asking for.',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        if (_historyError != null) ...[
          const SizedBox(height: 10),
          Text(
            _historyError!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }

  Widget _summaryBar(int matching, int camCount) {
    if (_historyLoading) {
      return const Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text('Loading sighting history…'),
        ],
      );
    }
    final total = _history.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$matching of $total sighting${total == 1 ? '' : 's'} match this '
        'report, across $camCount camera${camCount == 1 ? '' : 's'}.'
        '${_historyTruncated ? ' History was truncated at $kMaxOccurrencesFetched reads.' : ''}',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: Theme.of(context).hintColor,
          ),
        ),
      );

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) labelOf,
    required void Function(T) onChanged,
  }) {
    return DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final i in items)
          DropdownMenuItem(value: i, child: Text(labelOf(i))),
      ],
      onChanged: _busy
          ? null
          : (v) {
              if (v != null) onChanged(v);
            },
    );
  }

  Widget _dateField(String label, DateTime? value, void Function(DateTime) set) {
    return OutlinedButton.icon(
      onPressed: _busy
          ? null
          : () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: value ?? now,
                firstDate: DateTime(now.year - 5),
                lastDate: DateTime(now.year + 1),
              );
              if (picked != null) set(picked);
            },
      icon: const Icon(Icons.calendar_today_outlined, size: 16),
      label: Text(
        value == null ? label : '$label: ${_tz.formatShort(value)}',
        overflow: TextOverflow.ellipsis,
      ),
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
