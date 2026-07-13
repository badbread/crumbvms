// Plates tab: newest-first browser of license-plate reads (LPR). A filter bar
// (plate search + match mode, camera multi-select, time range) over a list of
// reads; each row shows the plate, the sibling snapshot, camera, local time,
// and a confidence chip, and clicking a row jumps to Playback at that read's
// moment on that camera (the same hand-off the Clips tab uses for "View on
// timeline").
//
// Data comes from GET /plates (see plates_api.dart). Snapshots ride the
// detection-event snapshot proxy GET /events/{event_id}/snapshot (Bearer,
// viewer-scoped) — the only authed image source a read exposes — so reads
// without an event_id show a placeholder rather than an unauthenticated
// provider URL.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/plates_api.dart';

/// Time-range presets. `0` is the "all time" sentinel (no start/end sent);
/// every other key is a window length in hours ending at the anchor.
const _rangeOptions = <int, String>{
  0: 'All time',
  1: '1 hour',
  6: '6 hours',
  24: '24 hours',
  72: '3 days',
  168: '7 days',
  720: '30 days',
};

const _platesPageSize = 200;
const _thumbConcurrency = 6;

class PlatesScreen extends StatefulWidget {
  const PlatesScreen({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    required this.onViewFootage,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;

  /// Row click → jump to Playback at [ts] on [cameraId]. Wired in main.dart to
  /// the same one-shot seek/focus hand-off the Clips "View on timeline" uses.
  final void Function(String cameraId, DateTime ts) onViewFootage;

  @override
  State<PlatesScreen> createState() => _PlatesScreenState();
}

class _PlatesScreenState extends State<PlatesScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String _match = 'contains'; // "exact" | "contains" | "fuzzy"
  int _hours = 24;
  DateTime? _anchorEnd; // null = window ends "now"
  late Set<String> _selectedCameraIds;

  bool _loading = false;
  String? _error;
  List<PlateRead> _plates = const [];
  int _total = 0;

  Timer? _searchDebounce;
  final _thumbGate = _ConcurrencyGate(_thumbConcurrency);

  @override
  void initState() {
    super.initState();
    // Default to every visible camera selected — the natural "show me
    // everything" starting point for a plate log.
    _selectedCameraIds = {for (final c in widget.cameras) c.id};
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  List<String> get _effectiveCameraIds =>
      widget.cameras
          .where((c) => _selectedCameraIds.contains(c.id))
          .map((c) => c.id)
          .toList(growable: false);

  Future<void> _load() async {
    final ids = _effectiveCameraIds;
    if (ids.isEmpty) {
      setState(() {
        _plates = const [];
        _total = 0;
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    _thumbGate.reset();
    final DateTime? end;
    final DateTime? start;
    if (_hours == 0) {
      end = null;
      start = null;
    } else {
      end = _anchorEnd ?? DateTime.now();
      start = end.subtract(Duration(hours: _hours));
    }
    try {
      final page = await widget.api.listPlates(
        widget.session,
        cameraIds: ids,
        query: _query,
        match: _match,
        start: start,
        end: end,
        limit: _platesPageSize,
      );
      if (!mounted) return;
      // Guarantee newest-first regardless of server ordering.
      final sorted = page.plates.toList()
        ..sort((a, b) => b.ts.compareTo(a.ts));
      setState(() {
        _plates = sorted;
        _total = page.total;
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

  void _onSearchChanged(String v) {
    setState(() => _query = v); // keep the clear button in sync as you type
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _load();
    });
  }

  Future<void> _pickWhen() async {
    final now = DateTime.now();
    final base = _anchorEnd ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null || !mounted) return;
    setState(() {
      _anchorEnd =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
    _load();
  }

  Future<void> _pickCameras() async {
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => _CameraPickerDialog(
        cameras: widget.cameras,
        selected: _selectedCameraIds,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _selectedCameraIds = result);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF17181C),
      body: SafeArea(
        child: Column(
          children: [
            _buildFilterBar(context),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    final camLabel = _selectedCameraIds.length == widget.cameras.length
        ? 'All cameras'
        : '${_selectedCameraIds.length} of ${widget.cameras.length} cameras';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF1E2026),
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 8,
        children: [
          SizedBox(
            width: 220,
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              onSubmitted: (_) {
                _searchDebounce?.cancel();
                _load();
              },
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search plate…',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                prefixIcon: const Icon(Icons.search, size: 18, color: Colors.white38),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 16, color: Colors.white38),
                        onPressed: () {
                          _searchController.clear();
                          _query = '';
                          _load();
                        },
                      ),
                filled: true,
                fillColor: const Color(0xFF2A2D35),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          _MatchToggle(
            value: _match,
            onChanged: (v) {
              setState(() => _match = v);
              if (_query.trim().isNotEmpty) _load();
            },
          ),
          TextButton.icon(
            onPressed: _pickCameras,
            icon: const Icon(Icons.videocam_outlined, size: 16, color: Colors.white70),
            label: Text(
              camLabel,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          DropdownButton<int>(
            value: _hours,
            dropdownColor: const Color(0xFF23252C),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            underline: const SizedBox.shrink(),
            items: [
              for (final e in _rangeOptions.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _hours = v);
              _load();
            },
          ),
          TextButton.icon(
            onPressed: _hours == 0 ? null : _pickWhen,
            icon: const Icon(Icons.event, size: 16, color: Colors.white70),
            label: Text(
              _anchorEnd == null ? 'Jump to…' : _fmtDateTime(_anchorEnd!),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          if (_anchorEnd != null && _hours != 0)
            TextButton(
              onPressed: () {
                setState(() => _anchorEnd = null);
                _load();
              },
              child: const Text('Now', style: TextStyle(fontSize: 12)),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh, color: Colors.white70, size: 18),
          ),
          if (!_loading)
            Text(
              '$_total plate${_total == 1 ? '' : 's'}',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _plates.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Text(
          "Couldn't load plates: $_error",
          style: const TextStyle(color: Colors.redAccent),
        ),
      );
    }
    if (_plates.isEmpty) {
      return const Center(
        child: Text(
          'No plate reads in this window.',
          style: TextStyle(color: Colors.white38),
        ),
      );
    }
    final byId = {for (final c in widget.cameras) c.id: c};
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: _plates.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: Colors.white10),
      itemBuilder: (context, i) {
        final p = _plates[i];
        return _PlateRow(
          key: ValueKey(p.id),
          read: p,
          cameraName: byId[p.cameraId]?.name ?? '(unknown camera)',
          api: widget.api,
          session: widget.session,
          gate: _thumbGate,
          onTap: () => widget.onViewFootage(p.cameraId, p.ts),
        );
      },
    );
  }
}

// ─── filter widgets ───────────────────────────────────────────────────────

class _MatchToggle extends StatelessWidget {
  const _MatchToggle({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    Widget seg(String v, String label) {
      final active = value == v;
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: ChoiceChip(
          label: Text(label),
          selected: active,
          onSelected: (_) => onChanged(v),
          labelStyle: TextStyle(
            fontSize: 12,
            color: active ? Colors.black : Colors.white70,
          ),
          selectedColor: accent,
          checkmarkColor: Colors.black,
          backgroundColor: const Color(0xFF2A2D35),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        seg('exact', 'Exact'),
        seg('contains', 'Contains'),
        seg('fuzzy', 'Fuzzy'),
      ],
    );
  }
}

/// Camera multi-select dialog with All / None shortcuts. Returns the new
/// selection, or null if cancelled.
class _CameraPickerDialog extends StatefulWidget {
  const _CameraPickerDialog({required this.cameras, required this.selected});
  final List<Camera> cameras;
  final Set<String> selected;

  @override
  State<_CameraPickerDialog> createState() => _CameraPickerDialogState();
}

class _CameraPickerDialogState extends State<_CameraPickerDialog> {
  late final Set<String> _sel = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cameras'),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(
                    () => _sel.addAll(widget.cameras.map((c) => c.id)),
                  ),
                  child: const Text('All'),
                ),
                TextButton(
                  onPressed: () => setState(_sel.clear),
                  child: const Text('None'),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final cam in widget.cameras)
                    CheckboxListTile(
                      dense: true,
                      value: _sel.contains(cam.id),
                      title: Text(cam.name),
                      onChanged: (on) => setState(() {
                        if (on == true) {
                          _sel.add(cam.id);
                        } else {
                          _sel.remove(cam.id);
                        }
                      }),
                    ),
                ],
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
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_sel),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

// ─── plate row + lazy snapshot ─────────────────────────────────────────────

class _PlateRow extends StatelessWidget {
  const _PlateRow({
    super.key,
    required this.read,
    required this.cameraName,
    required this.api,
    required this.session,
    required this.gate,
    required this.onTap,
  });

  final PlateRead read;
  final String cameraName;
  final CrumbApi api;
  final Session session;
  final _ConcurrencyGate gate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            _PlateThumb(
              read: read,
              api: api,
              session: session,
              gate: gate,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    read.plate.isEmpty ? '—' : read.plate,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(Icons.videocam_outlined,
                          size: 13, color: Colors.white38),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          cameraName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      if (read.region != null && read.region!.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          read.region!,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _fmtDateTime(read.ts),
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _ConfidenceChip(read.confidence),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
          ],
        ),
      ),
    );
  }
}

/// The read's snapshot: fetched from the sibling detection event's snapshot
/// proxy (`GET /events/{event_id}/snapshot`, Bearer-authed). Reads with no
/// linked event have no authed image source, so they show a plate placeholder.
class _PlateThumb extends StatefulWidget {
  const _PlateThumb({
    required this.read,
    required this.api,
    required this.session,
    required this.gate,
  });

  final PlateRead read;
  final CrumbApi api;
  final Session session;
  final _ConcurrencyGate gate;

  @override
  State<_PlateThumb> createState() => _PlateThumbState();
}

class _PlateThumbState extends State<_PlateThumb> {
  Uint8List? _bytes;
  bool _requested = false;
  bool _disposed = false;

  static const double _w = 92;
  static const double _h = 56;

  @override
  void initState() {
    super.initState();
    _maybeLoad();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _maybeLoad() {
    final eventId = widget.read.eventId;
    if (eventId == null || eventId.isEmpty) return;
    final cached = _snapshotCache[eventId];
    if (cached != null) {
      _bytes = cached;
      return;
    }
    if (_requested) return;
    _requested = true;
    widget.gate.run(_load);
  }

  Future<void> _load() async {
    if (_disposed) return;
    final eventId = widget.read.eventId;
    if (eventId == null || eventId.isEmpty) return;
    final s = widget.session;
    final url = '${s.base}/events/${Uri.encodeComponent(eventId)}/snapshot';
    try {
      final resp = await http.get(
        Uri.parse(url),
        headers: {'authorization': 'Bearer ${s.token}'},
      );
      if (_disposed || resp.statusCode != 200) return;
      _cacheSnapshot(eventId, resp.bodyBytes);
      if (mounted) setState(() => _bytes = resp.bodyBytes);
    } catch (_) {
      // Leave the placeholder.
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: _w,
        height: _h,
        child: _bytes != null
            ? Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true)
            : Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: const Icon(
                  Icons.directions_car_outlined,
                  color: Colors.white24,
                  size: 22,
                ),
              ),
      ),
    );
  }
}

class _ConfidenceChip extends StatelessWidget {
  const _ConfidenceChip(this.confidence);
  final double? confidence;

  @override
  Widget build(BuildContext context) {
    final c = confidence;
    if (c == null) {
      return const _ChipBox(text: '—', color: Colors.white24);
    }
    final pct = (c * 100).round();
    final color = c >= 0.85
        ? const Color(0xFF57C888) // green
        : c >= 0.6
            ? const Color(0xFFE8A33D) // amber
            : const Color(0xFFD65C5C); // red
    return _ChipBox(text: '$pct%', color: color);
  }
}

class _ChipBox extends StatelessWidget {
  const _ChipBox({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

// ─── shared thumbnail plumbing ─────────────────────────────────────────────

/// Process-wide snapshot byte cache, keyed by event id, bounded so a long
/// browsing session doesn't grow unbounded (mirrors the clips thumb cache).
final Map<String, Uint8List> _snapshotCache = {};
final List<String> _snapshotCacheOrder = [];
const _snapshotCacheMax = 300;

void _cacheSnapshot(String id, Uint8List bytes) {
  if (!_snapshotCache.containsKey(id)) {
    _snapshotCacheOrder.add(id);
    if (_snapshotCacheOrder.length > _snapshotCacheMax) {
      _snapshotCache.remove(_snapshotCacheOrder.removeAt(0));
    }
  }
  _snapshotCache[id] = bytes;
}

/// Bounded-concurrency gate for snapshot loads (mirrors the Clips tab's cap).
/// `reset()` releases queued waiters on a fresh page load so a stale window's
/// loads don't linger.
class _ConcurrencyGate {
  _ConcurrencyGate(this.max);
  final int max;
  int _active = 0;
  final List<Completer<void>> _waiters = [];

  void reset() {
    _active = 0;
    for (final c in _waiters) {
      if (!c.isCompleted) c.complete();
    }
    _waiters.clear();
  }

  Future<void> run(Future<void> Function() task) async {
    if (_active >= max) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _active++;
    try {
      await task();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) {
        final next = _waiters.removeAt(0);
        if (!next.isCompleted) next.complete();
      }
    }
  }
}

// ─── helpers ────────────────────────────────────────────────────────────

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Local, human-readable timestamp for a read — includes seconds since a plate
/// read is a precise moment (unlike a clip's start).
String _fmtDateTime(DateTime t) {
  final local = t.toLocal();
  final h24 = local.hour;
  final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
  final ampm = h24 < 12 ? 'AM' : 'PM';
  final mm = local.minute.toString().padLeft(2, '0');
  final ss = local.second.toString().padLeft(2, '0');
  return '${_months[local.month - 1]} ${local.day}, $h12:$mm:$ss $ampm';
}
