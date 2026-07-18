// LPR dual-engine A/B benchmark: Frigate native LPR vs the crumb-alpr
// (fast-alpr) worker, head-to-head on cameras with `lpr_engine == 'both'`.
// Opened from the Plates screen (the button only renders when the server
// reports at least one dual-engine camera). Two side-by-side stat cards
// (reads, passes seen, hit rate, avg confidence, accuracy) around a shared
// agreement summary, over a newest-first list of paired vehicle passes: each
// row shows the pass images (full-frame context + tight plate crop, both
// click-to-enlarge), both engines' plate + confidence, a match/differ/miss
// verdict, and — for admins — a confirm-true-plate control that anchors the
// accuracy stats (`POST /lpr/ab-confirm`); the confirm prompt repeats both
// images so the operator can read the plate before typing.
//
// Data: `GET /lpr/ab-report` (see plates_api.dart). Pass images ride the
// existing authed sources only — the sibling detection-event snapshot
// (`GET /events/{id}/snapshot`) or the stored crumb-alpr crop
// (`GET /plates/{id}/crop`) — never an unauthenticated provider URL. The
// report itself carries no bbox, so the client-side plate crop (Frigate-only
// passes) finds the read's bbox via one narrow `GET /plates` query and crops
// with the shared plate_crop.dart helper, exactly like the Plates screen.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/http_client.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/plates/plate_crop.dart';

// Palette shared with the Plates screen (kept literal — those consts are
// library-private to plates_screen.dart).
const _bg = Color(0xFF17181C);
const _panel = Color(0xFF1E2026);
const _field = Color(0xFF2A2D35);
const _ok = Color(0xFF57C888);
const _warn = Color(0xFFE8A33D);
const _danger = Color(0xFFD65C5C);

/// Report time-range presets (hours). Mirrors the Plates filter presets minus
/// "all time" (stats over an unbounded range invite the read ceiling).
const _abRangeOptions = <int, String>{
  1: '1 hour',
  6: '6 hours',
  24: '24 hours',
  72: '3 days',
  168: '7 days',
  720: '30 days',
};

/// Pass-pairing window presets (seconds between reads of one vehicle pass).
const _abWindowOptions = <int, String>{
  4: '4 s window',
  8: '8 s window',
  15: '15 s window',
  30: '30 s window',
};

const _abPageSize = 200;

/// Open the benchmark as a large dialog over the Plates screen.
Future<void> showAbBenchmark(
  BuildContext context, {
  required CrumbApi api,
  required Session session,
  required bool canConfirm,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: _bg,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180, maxHeight: 860),
        child: _AbBenchmarkView(
          api: api,
          session: session,
          canConfirm: canConfirm,
        ),
      ),
    ),
  );
}

class _AbBenchmarkView extends StatefulWidget {
  const _AbBenchmarkView({
    required this.api,
    required this.session,
    required this.canConfirm,
  });

  final CrumbApi api;
  final Session session;

  /// Admin — may confirm true plates (`POST /lpr/ab-confirm` is admin-only).
  final bool canConfirm;

  @override
  State<_AbBenchmarkView> createState() => _AbBenchmarkViewState();
}

class _AbBenchmarkViewState extends State<_AbBenchmarkView> {
  AbReport? _report;
  bool _loading = true;
  String? _error;

  String? _cameraId; // null = all dual-engine cameras
  int _hours = 24;
  int _windowSecs = 8;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final end = DateTime.now();
      final report = await widget.api.getAbReport(
        widget.session,
        cameraId: _cameraId,
        windowSecs: _windowSecs,
        start: end.subtract(Duration(hours: _hours)),
        end: end,
        limit: _abPageSize,
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _confirm(AbPass pass) async {
    // Prefill with the higher-confidence guess — usually right, one keystroke
    // to accept.
    final f = pass.frigate;
    final c = pass.crumbAlpr;
    final prefill = pass.truePlate ??
        ((c?.confidence ?? -1) >= (f?.confidence ?? -1)
            ? (c?.plate ?? f?.plate ?? '')
            : (f?.plate ?? c?.plate ?? ''));
    final plate = await showDialog<String>(
      context: context,
      builder: (ctx) => _ConfirmPlateDialog(
        initial: prefill,
        pass: pass,
        api: widget.api,
        session: widget.session,
      ),
    );
    if (plate == null || plate.trim().isEmpty || !mounted) return;
    try {
      await widget.api.confirmAbPass(
        widget.session,
        cameraId: pass.cameraId,
        bucketTs: pass.bucketTsRaw,
        truePlate: plate,
      );
      // Server truth recorded — refetch so the accuracy cards and every
      // correctness flag come from the same source of truth.
      await _load();
    } on CrumbApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Confirm failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Column(
      children: [
        _buildHeader(context, report),
        const Divider(height: 1, color: Colors.white12),
        if (_loading && report == null)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Expanded(
            child: Center(
              child: Text(
                "Couldn't load benchmark: $_error",
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          )
        else if (report != null) ...[
          _buildStats(report),
          const Divider(height: 1, color: Colors.white12),
          Expanded(child: _buildPassList(report)),
        ],
      ],
    );
  }

  Widget _buildHeader(BuildContext context, AbReport? report) {
    final cameras = report?.cameras ?? const <AbCamera>[];
    return Container(
      color: _panel,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.speed, size: 18, color: Colors.white70),
          const SizedBox(width: 8),
          const Text(
            'Engine Benchmark',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'Frigate vs Crumb ALPR',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const Spacer(),
          if (cameras.length > 1) ...[
            DropdownButton<String?>(
              value: _cameraId,
              dropdownColor: const Color(0xFF23252C),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All cameras'),
                ),
                for (final c in cameras)
                  DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) {
                setState(() => _cameraId = v);
                _load();
              },
            ),
            const SizedBox(width: 10),
          ],
          DropdownButton<int>(
            value: _hours,
            dropdownColor: const Color(0xFF23252C),
            style: const TextStyle(color: Colors.white, fontSize: 12),
            underline: const SizedBox.shrink(),
            items: [
              for (final e in _abRangeOptions.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _hours = v);
              _load();
            },
          ),
          const SizedBox(width: 10),
          DropdownButton<int>(
            value: _windowSecs,
            dropdownColor: const Color(0xFF23252C),
            style: const TextStyle(color: Colors.white, fontSize: 12),
            underline: const SizedBox.shrink(),
            items: [
              for (final e in _abWindowOptions.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _windowSecs = v);
              _load();
            },
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh, color: Colors.white70, size: 18),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, color: Colors.white70, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildStats(AbReport r) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _EngineCard(
              title: 'Frigate',
              stats: r.frigate,
              accent: const Color(0xFF5B9BD5),
            ),
          ),
          SizedBox(width: 170, child: _SummaryColumn(report: r)),
          Expanded(
            child: _EngineCard(
              title: 'Crumb ALPR',
              stats: r.crumbAlpr,
              accent: const Color(0xFF57C888),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPassList(AbReport r) {
    if (r.cameras.isEmpty) {
      return const Center(
        child: Text(
          'No camera is set to run both LPR engines.',
          style: TextStyle(color: Colors.white38),
        ),
      );
    }
    if (r.passes.isEmpty) {
      return const Center(
        child: Text(
          'No vehicle passes in this window.',
          style: TextStyle(color: Colors.white38),
        ),
      );
    }
    final camName = {for (final c in r.cameras) c.id: c.name};
    return Column(
      children: [
        if (r.truncated)
          Container(
            width: double.infinity,
            color: _warn.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: const Text(
              'Too many reads in this range — stats cover only the newest '
              'slice. Narrow the time range.',
              style: TextStyle(color: _warn, fontSize: 12),
            ),
          ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: r.passes.length,
            separatorBuilder: (_, _) =>
                const Divider(height: 1, color: Colors.white10),
            itemBuilder: (context, i) {
              final p = r.passes[i];
              return _PassRow(
                key: ValueKey('${p.cameraId}/${p.bucketTsRaw}'),
                pass: p,
                cameraName: camName[p.cameraId] ?? '(unknown camera)',
                api: widget.api,
                session: widget.session,
                canConfirm: widget.canConfirm,
                onConfirm: () => _confirm(p),
              );
            },
          ),
        ),
        if (r.hasMore)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Showing newest ${r.passes.length} of ${r.passTotal} passes.',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
      ],
    );
  }
}

// ─── stat cards ────────────────────────────────────────────────────────────

String _pct(double? v) => v == null ? '—' : '${(v * 100).round()}%';

class _EngineCard extends StatelessWidget {
  const _EngineCard({
    required this.title,
    required this.stats,
    required this.accent,
  });

  final String title;
  final AbEngineStats stats;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Stat(label: 'Reads', value: '${stats.totalReads}'),
              _Stat(label: 'Passes seen', value: '${stats.passesSeen}'),
              _Stat(label: 'Hit rate', value: _pct(stats.hitRate)),
              _Stat(label: 'Avg conf', value: _pct(stats.avgConfidence)),
              _Stat(
                label: 'Accuracy',
                value: stats.confirmed == 0
                    ? '—'
                    : '${_pct(stats.accuracy)} '
                        '(${stats.correct}/${stats.confirmed})',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

/// Shared middle column: totals + agreement (symmetric between engines).
class _SummaryColumn extends StatelessWidget {
  const _SummaryColumn({required this.report});
  final AbReport report;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        children: [
          Text(
            '${report.totalPasses}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Text(
            'vehicle passes',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 8),
          Text(
            '${report.bothSeen} seen by both',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            'Agreement ${_pct(report.agreementRate)}',
            style: TextStyle(
              color: report.agreementRate == null
                  ? Colors.white38
                  : (report.agreementRate! >= 0.8 ? _ok : _warn),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── pass rows ─────────────────────────────────────────────────────────────

class _PassRow extends StatelessWidget {
  const _PassRow({
    super.key,
    required this.pass,
    required this.cameraName,
    required this.api,
    required this.session,
    required this.canConfirm,
    required this.onConfirm,
  });

  final AbPass pass;
  final String cameraName;
  final CrumbApi api;
  final Session session;
  final bool canConfirm;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          _AbThumb(pass: pass, api: api, session: session),
          const SizedBox(width: 12),
          SizedBox(
            width: 150,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _fmtDateTime(pass.bucketTs),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  cameraName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
          Expanded(
            child: _EngineGuess(
              label: 'Frigate',
              read: pass.frigate,
              correct: pass.frigateCorrect,
            ),
          ),
          Expanded(
            child: _EngineGuess(
              label: 'Crumb ALPR',
              read: pass.crumbAlpr,
              correct: pass.crumbAlprCorrect,
            ),
          ),
          SizedBox(width: 86, child: Center(child: _verdictChip())),
          SizedBox(width: 150, child: _truthCell(context)),
        ],
      ),
    );
  }

  Widget _verdictChip() {
    final agree = pass.agree;
    if (agree == null) {
      final missed = pass.frigate == null ? 'Frigate' : 'Crumb';
      return _chip('$missed miss', _danger);
    }
    return agree ? _chip('Match', _ok) : _chip('Differ', _warn);
  }

  Widget _truthCell(BuildContext context) {
    final truth = pass.truePlate;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (truth != null)
          Flexible(
            child: Text(
              truth,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _ok,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                fontFamily: 'monospace',
              ),
            ),
          )
        else
          const Text(
            'unconfirmed',
            style: TextStyle(color: Colors.white24, fontSize: 11),
          ),
        if (canConfirm) ...[
          const SizedBox(width: 4),
          IconButton(
            tooltip:
                truth == null ? 'Confirm true plate' : 'Edit true plate',
            visualDensity: VisualDensity.compact,
            onPressed: onConfirm,
            icon: Icon(
              truth == null ? Icons.fact_check_outlined : Icons.edit_outlined,
              size: 17,
              color: truth == null ? Colors.white54 : Colors.white38,
            ),
          ),
        ],
      ],
    );
  }
}

/// One engine's guess inside a pass row: plate (mono) + confidence + the
/// per-engine correctness mark once a truth is confirmed.
class _EngineGuess extends StatelessWidget {
  const _EngineGuess({
    required this.label,
    required this.read,
    required this.correct,
  });

  final String label;
  final AbPassRead? read;
  final bool? correct;

  @override
  Widget build(BuildContext context) {
    final r = read;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
        const SizedBox(height: 2),
        if (r == null)
          const Text(
            '— no read —',
            style: TextStyle(color: Colors.white24, fontSize: 12),
          )
        else
          Row(
            children: [
              Flexible(
                child: Text(
                  r.plate,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.3,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _confChip(r.confidence),
              if (r.readCount > 1) ...[
                const SizedBox(width: 4),
                Text(
                  '×${r.readCount}',
                  style: const TextStyle(color: Colors.white38, fontSize: 10),
                ),
              ],
              if (correct != null) ...[
                const SizedBox(width: 4),
                Icon(
                  correct! ? Icons.check_circle : Icons.cancel,
                  size: 14,
                  color: correct! ? _ok : _danger,
                ),
              ],
            ],
          ),
      ],
    );
  }
}

Widget _confChip(double? confidence) {
  if (confidence == null) return _chip('—', Colors.white24);
  final pct = (confidence * 100).round();
  final color = confidence >= 0.85
      ? _ok
      : confidence >= 0.6
          ? _warn
          : _danger;
  return _chip('$pct%', color);
}

Widget _chip(String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.6)),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}

// ─── pass images ───────────────────────────────────────────────────────────

/// The two images that describe one pass: the full-frame detection snapshot
/// (scene context) and the tight plate crop (readable plate). Either may be
/// null when no source exists or a fetch failed.
class _AbPassImages {
  const _AbPassImages({this.full, this.crop});

  final Uint8List? full;
  final Uint8List? crop;

  bool get isEmpty => full == null && crop == null;
}

String _abPassKey(AbPass p) => '${p.cameraId}/${p.bucketTsRaw}';

/// Bounded cache of resolved pass images (same pattern as the Plates
/// thumbnails), keyed by the stable pass key. Only resolutions that produced
/// at least one image are cached, so a transient fetch failure retries on the
/// next mount — parity with the previous single-image cache.
final Map<String, _AbPassImages> _abImagesCache = {};
const _abImagesCacheMax = 200;

/// In-flight resolutions, deduped by pass key so a row thumb and the confirm
/// dialog racing for the same pass share one set of fetches.
final Map<String, Future<_AbPassImages>> _abImagesInFlight = {};

/// Bbox lookup memo (read id → bbox or null-for-none). The ab-report carries
/// no bbox, so the crop path re-finds the read via `GET /plates`; memoized so
/// scrolling back over rows doesn't re-query.
final Map<String, List<double>?> _abBboxCache = {};
const _abBboxCacheMax = 400;

/// Resolve (and cache) both images for [p]. Shared by the row thumbnails and
/// the confirm-true-plate dialog so both hit the same cache.
Future<_AbPassImages> _resolvePassImages(CrumbApi api, Session s, AbPass p) {
  final key = _abPassKey(p);
  final cached = _abImagesCache[key];
  if (cached != null) return Future.value(cached);
  final inFlight = _abImagesInFlight[key];
  if (inFlight != null) return inFlight;
  final future = _resolvePassImagesUncached(api, s, p).then((images) {
    if (!images.isEmpty) {
      if (_abImagesCache.length >= _abImagesCacheMax) {
        _abImagesCache.remove(_abImagesCache.keys.first);
      }
      _abImagesCache[key] = images;
    }
    return images;
  }).whenComplete(() => _abImagesInFlight.remove(key));
  _abImagesInFlight[key] = future;
  return future;
}

Future<_AbPassImages> _resolvePassImagesUncached(
  CrumbApi api,
  Session s,
  AbPass p,
) async {
  // Full frame: the sibling detection-event snapshot of whichever engine has
  // one (Frigate first). That read also "owns" the frame for bbox-crop
  // purposes — a bbox is only valid against the exact frame its read was made
  // on, so never mix one engine's bbox with the other engine's snapshot.
  AbPassRead? owner;
  String? ownerEventId;
  for (final r in [p.frigate, p.crumbAlpr]) {
    final eid = r?.eventId;
    if (r != null && eid != null && eid.isNotEmpty) {
      owner = r;
      ownerEventId = eid;
      break;
    }
  }
  Uint8List? full;
  if (ownerEventId != null) {
    full = await _fetchAbBytes(
      s,
      '${s.base}/events/${Uri.encodeComponent(ownerEventId)}/snapshot',
    );
  }

  // Tight plate crop: prefer the stored crumb-alpr crop (already plate-tight,
  // no client work); else derive one from the full frame + the owner read's
  // bbox, exactly like the Plates screen does.
  Uint8List? crop;
  final c = p.crumbAlpr;
  if (c != null) {
    crop = await _fetchAbBytes(
      s,
      '${s.base}/plates/${Uri.encodeComponent(c.readId)}/crop',
    );
  }
  if (crop == null && full != null && owner != null) {
    final bbox = await _lookupAbBbox(api, s, p.cameraId, owner);
    if (bbox != null && bbox.length >= 4) {
      try {
        crop = await cachedPlateCrop(owner.readId, full, bbox);
      } catch (_) {
        crop = null; // undecodable frame — the full frame still shows
      }
    }
  }
  return _AbPassImages(full: full, crop: crop);
}

/// One Bearer-authed GET returning body bytes, or null on any non-200/error
/// (callers fall back to a placeholder).
Future<Uint8List?> _fetchAbBytes(Session s, String url) async {
  try {
    final resp = await sharedHttpClient.get(
      Uri.parse(url),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
      return resp.bodyBytes;
    }
  } catch (_) {
    // fall through
  }
  return null;
}

/// Find [read]'s bbox: one narrow `GET /plates` query (same camera, ±2 s
/// around the read's timestamp) and match the row by read id. A read with no
/// bbox memoizes null (no point re-querying); a failed query is not memoized.
Future<List<double>?> _lookupAbBbox(
  CrumbApi api,
  Session s,
  String cameraId,
  AbPassRead read,
) async {
  if (_abBboxCache.containsKey(read.readId)) return _abBboxCache[read.readId];
  List<double>? bbox;
  try {
    final page = await api.listPlates(
      s,
      cameraIds: [cameraId],
      start: read.ts.subtract(const Duration(seconds: 2)),
      end: read.ts.add(const Duration(seconds: 2)),
      limit: 50,
    );
    for (final r in page.plates) {
      if (r.id == read.readId) {
        bbox = r.bbox;
        break;
      }
    }
  } catch (_) {
    return null; // transient — retry on the next mount
  }
  if (_abBboxCache.length >= _abBboxCacheMax) {
    _abBboxCache.remove(_abBboxCache.keys.first);
  }
  _abBboxCache[read.readId] = bbox;
  return bbox;
}

/// The pass images cell: full-frame context thumb + tight plate crop side by
/// side (crop slot reserved so columns stay aligned), each click-to-enlarge.
class _AbThumb extends StatefulWidget {
  const _AbThumb({
    required this.pass,
    required this.api,
    required this.session,
  });

  final AbPass pass;
  final CrumbApi api;
  final Session session;

  @override
  State<_AbThumb> createState() => _AbThumbState();
}

class _AbThumbState extends State<_AbThumb> {
  _AbPassImages? _images;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_AbThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refresh can hand a reused element a different pass — reload then.
    if (_abPassKey(oldWidget.pass) != _abPassKey(widget.pass)) {
      _images = null;
      _load();
    }
  }

  Future<void> _load() async {
    final pass = widget.pass;
    final images = await _resolvePassImages(widget.api, widget.session, pass);
    // Drop a stale resolution if the widget moved on to another pass.
    if (mounted && _abPassKey(widget.pass) == _abPassKey(pass)) {
      setState(() => _images = images);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _AbTappableImage(
          bytes: _images?.full,
          width: 132,
          height: 74,
          fit: BoxFit.cover,
          cacheWidth: (132 * dpr).round(),
          placeholderIcon: Icons.directions_car_outlined,
          lightboxLabel: 'Full frame',
        ),
        const SizedBox(width: 6),
        _AbTappableImage(
          bytes: _images?.crop,
          width: 110,
          height: 74,
          fit: BoxFit.contain,
          cacheWidth: (110 * dpr).round(),
          placeholderIcon: Icons.no_photography_outlined,
          lightboxLabel: 'Plate crop',
        ),
      ],
    );
  }
}

/// One clickable benchmark image cell: rounded, black-backed, opens the
/// lightbox on click when it has bytes; a dim placeholder icon otherwise.
class _AbTappableImage extends StatelessWidget {
  const _AbTappableImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.fit,
    required this.cacheWidth,
    required this.placeholderIcon,
    required this.lightboxLabel,
  });

  final Uint8List? bytes;
  final double width;
  final double height;
  final BoxFit fit;
  final int cacheWidth;
  final IconData placeholderIcon;
  final String lightboxLabel;

  @override
  Widget build(BuildContext context) {
    final b = bytes;
    final cell = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: width,
        height: height,
        color: Colors.black,
        alignment: Alignment.center,
        child: b == null
            ? Icon(placeholderIcon, color: Colors.white24, size: 22)
            : Image.memory(
                b,
                fit: fit,
                gaplessPlayback: true,
                cacheWidth: cacheWidth,
              ),
      ),
    );
    if (b == null) return cell;
    return MouseRegion(
      cursor: SystemMouseCursors.zoomIn,
      child: GestureDetector(
        onTap: () => _showAbLightbox(context, b, label: lightboxLabel),
        child: Tooltip(
          message: 'Click to enlarge',
          waitDuration: const Duration(milliseconds: 600),
          child: cell,
        ),
      ),
    );
  }
}

/// Full-size dismissible viewer: dark backdrop, wheel-zoom + drag-pan via
/// [InteractiveViewer], click anywhere or Esc to close.
Future<void> _showAbLightbox(
  BuildContext context,
  Uint8List bytes, {
  String? label,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.88),
    builder: (ctx) => Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // Click-anywhere-to-close, the image included (zoom rides the wheel
          // and pan rides drags, neither of which registers as a tap).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(ctx).pop(),
              child: InteractiveViewer(
                maxScale: 8,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (label != null)
            Positioned(
              left: 16,
              top: 12,
              child: Text(
                label,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          Positioned(
            right: 8,
            top: 8,
            child: IconButton(
              tooltip: 'Close (Esc)',
              onPressed: () => Navigator.of(ctx).pop(),
              icon: const Icon(Icons.close, color: Colors.white70, size: 22),
            ),
          ),
        ],
      ),
    ),
  );
}

// ─── confirm dialog ────────────────────────────────────────────────────────

class _ConfirmPlateDialog extends StatefulWidget {
  const _ConfirmPlateDialog({
    required this.initial,
    required this.pass,
    required this.api,
    required this.session,
  });

  final String initial;
  final AbPass pass;
  final CrumbApi api;
  final Session session;

  @override
  State<_ConfirmPlateDialog> createState() => _ConfirmPlateDialogState();
}

class _ConfirmPlateDialogState extends State<_ConfirmPlateDialog> {
  late final TextEditingController _controller;
  _AbPassImages? _images;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _loadImages();
  }

  /// Usually instant — the row thumbnail already resolved and cached these.
  Future<void> _loadImages() async {
    final images =
        await _resolvePassImages(widget.api, widget.session, widget.pass);
    if (mounted) setState(() => _images = images);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _controller.text.trim();
    if (v.isEmpty) return;
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final images = _images;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return AlertDialog(
      backgroundColor: _panel,
      title: const Text(
        'Confirm true plate',
        style: TextStyle(color: Colors.white, fontSize: 15),
      ),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Read the plate off the image and correct the guess if needed. '
              'Both engines are scored against this. Click an image to '
              'enlarge.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            // Both pass images (full frame + tight plate crop) so the plate is
            // readable right here before typing. Absent sources are skipped.
            if (images != null && images.full != null) ...[
              const SizedBox(height: 10),
              _AbTappableImage(
                bytes: images.full,
                width: 340,
                height: 191,
                fit: BoxFit.contain,
                cacheWidth: (340 * dpr).round(),
                placeholderIcon: Icons.directions_car_outlined,
                lightboxLabel: 'Full frame',
              ),
            ],
            if (images != null && images.crop != null) ...[
              const SizedBox(height: 8),
              _AbTappableImage(
                bytes: images.crop,
                width: 340,
                height: 64,
                fit: BoxFit.contain,
                cacheWidth: (340 * dpr).round(),
                placeholderIcon: Icons.no_photography_outlined,
                lightboxLabel: 'Plate crop',
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
                fontFamily: 'monospace',
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: _field,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Confirm')),
      ],
    );
  }
}

// ─── helpers ───────────────────────────────────────────────────────────────

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _fmtDateTime(DateTime t) {
  final local = t.toLocal();
  final h24 = local.hour;
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final ampm = h24 < 12 ? 'AM' : 'PM';
  final mm = local.minute.toString().padLeft(2, '0');
  final ss = local.second.toString().padLeft(2, '0');
  return '${_months[local.month - 1]} ${local.day}, $h12:$mm:$ss $ampm';
}
