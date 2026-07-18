// Plates tab: newest-first browser of license-plate reads (LPR). A filter bar
// (plate search + match mode, camera multi-select, time range) over a list of
// reads; each row shows the plate, the sibling snapshot, camera, local time,
// and a confidence chip. Clicking a row with a linked detection event opens a
// dismissible pop-up that plays the short plate-hit clip (the same style as the
// Clips tab's clip player — closes on Esc / a close button), with a "View on
// timeline" button that hands off to Playback at that read's moment (the same
// one-shot seek/focus hand-off the Clips tab uses). A read with no linked event
// has no clip, so its row falls back to that timeline hand-off directly.
//
// The pop-up resolves the clip exactly like Clips resolves a detection clip:
// the read's event_id becomes the `d:<event-uuid>` clip id and plays via
// GET /clip/d:<event-uuid>/clip.mp4?q=preview on a scoped media `?token=`.
//
// Data comes from GET /plates (see plates_api.dart). Snapshots ride the
// detection-event snapshot proxy GET /events/{event_id}/snapshot (Bearer,
// viewer-scoped) — the only authed image source a read exposes — so reads
// without an event_id show a placeholder rather than an unauthenticated
// provider URL.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:crumb_desktop/api/clips_api.dart' show ClipsApi;
import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/http_client.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/clips/clip_player_shell.dart';
import 'package:crumb_desktop/ui/plates/ab_benchmark.dart';
import 'package:crumb_desktop/ui/plates/plate_collapse.dart';
import 'package:crumb_desktop/ui/plates/plate_crop.dart';
import 'package:crumb_desktop/ui/plates/plate_report_dialog.dart';
import 'package:crumb_desktop/ui/plates/plates_prefs.dart';

/// A plate-hit clip that stalls this long without progressing is retried (the
/// clip is transcoded on demand server-side, so a cold clip can be slow). Same
/// watchdog shape as the Clips tab's clip player.
const _plateClipLoadTimeout = Duration(milliseconds: 4500);
const _plateClipMaxRetries = 2;

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
    this.canManageWatchlist = false,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;

  /// Hand off to Playback at [ts] on [cameraId] — driven by the pop-up clip
  /// player's "View on timeline" button (and, for a read with no linked clip,
  /// directly from the row). Wired in main.dart to the same one-shot seek/focus
  /// hand-off the Clips "View on timeline" uses.
  final void Function(String cameraId, DateTime ts) onViewFootage;

  /// Whether this account may add/remove watchlist entries (admin-only on the
  /// server). Reading the watchlist is allowed for any `view_plates` account,
  /// so the panel always renders; when false the add form and the per-row/
  /// per-entry management affordances are hidden. Server-side 403s are still
  /// handled defensively even when this is true (stale/edge cases).
  final bool canManageWatchlist;

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

  // The read whose pop-up clip player is open (null = none). Set by tapping a
  // row that has a linked detection event; the overlay plays that read's clip.
  PlateRead? _playing;

  // Watchlist side panel. Readable by any account that can see this tab; the
  // add/remove affordances are gated on [widget.canManageWatchlist].
  bool _showWatchlist = true;
  List<PlateWatchlistEntry> _watchlist = const [];
  bool _watchlistLoading = false;
  String? _watchlistError;

  // LPR feature config — only fetched for admins (GET /config/lpr is admin-
  // only). Holds the current watchlist fuzziness the admin can tune; null until
  // loaded (or when the caller isn't an admin / the load 403s).
  LprConfig? _lprConfig;
  bool _lprConfigLoading = false;

  // Whether the dual-engine A/B benchmark applies here (the server reports at
  // least one `lpr_engine == 'both'` camera in this account's scope). Probed
  // once via a minimal GET /lpr/ab-report; the Benchmark button only renders
  // when true, so single-engine setups never see it.
  bool _abAvailable = false;

  // Which layout the results render in (persisted via [PlatesPrefs]).
  PlatesViewMode _viewMode = PlatesViewMode.list;
  // How plate previews show their image(s) (persisted via [PlatesPrefs]).
  PlateImageDisplay _imageDisplay = PlateImageDisplay.both;
  PlateCropCorner _cropCorner = PlateCropCorner.bottomRight;
  PlateCropSize _cropSize = PlateCropSize.medium;
  // Collapse duplicate reads of one car (both engines + Frigate OCR refinements)
  // into a single row (persisted via [PlatesPrefs]).
  bool _collapse = true;

  Timer? _searchDebounce;
  final _thumbGate = _ConcurrencyGate(_thumbConcurrency);

  @override
  void initState() {
    super.initState();
    // Default to every visible camera selected — the natural "show me
    // everything" starting point for a plate log.
    _selectedCameraIds = {for (final c in widget.cameras) c.id};
    _restoreViewMode();
    _load();
    _loadWatchlist();
    if (widget.canManageWatchlist) _loadLprConfig();
    _probeAbBenchmark();
  }

  /// Cheap applicability probe for the A/B benchmark: a minimal report over
  /// the last minute. The server returns its `both`-engine camera list even
  /// when the range holds no reads, so `cameras.isNotEmpty` is exactly "show
  /// the Benchmark button". Any error (403, offline, old server without the
  /// endpoint) just leaves the button hidden — never surfaced to the UI.
  Future<void> _probeAbBenchmark() async {
    try {
      final end = DateTime.now();
      final report = await widget.api.getAbReport(
        widget.session,
        start: end.subtract(const Duration(minutes: 1)),
        end: end,
        limit: 1,
      );
      if (!mounted) return;
      setState(() => _abAvailable = report.cameras.isNotEmpty);
    } catch (_) {
      // Leave hidden.
    }
  }

  Future<void> _restoreViewMode() async {
    final mode = await PlatesPrefs.getViewMode();
    final display = await PlatesPrefs.getImageDisplay();
    final corner = await PlatesPrefs.getCropCorner();
    final size = await PlatesPrefs.getCropSize();
    final collapse = await PlatesPrefs.getCollapseDuplicates();
    if (!mounted) return;
    setState(() {
      _viewMode = mode;
      _imageDisplay = display;
      _cropCorner = corner;
      _cropSize = size;
      _collapse = collapse;
    });
  }

  void _setCollapse(bool on) {
    if (on == _collapse) return;
    setState(() => _collapse = on);
    PlatesPrefs.setCollapseDuplicates(on);
  }

  void _setViewMode(PlatesViewMode mode) {
    if (mode == _viewMode) return;
    setState(() => _viewMode = mode);
    PlatesPrefs.setViewMode(mode);
  }

  void _setImageDisplay(PlateImageDisplay mode) {
    if (mode == _imageDisplay) return;
    setState(() => _imageDisplay = mode);
    PlatesPrefs.setImageDisplay(mode);
  }

  void _setCropCorner(PlateCropCorner corner) {
    if (corner == _cropCorner) return;
    setState(() => _cropCorner = corner);
    PlatesPrefs.setCropCorner(corner);
  }

  void _setCropSize(PlateCropSize size) {
    if (size == _cropSize) return;
    setState(() => _cropSize = size);
    PlatesPrefs.setCropSize(size);
  }

  /// Load the LPR config so the admin fuzziness control can render. A 403
  /// (stale admin flag) just leaves the control hidden — never throws to the
  /// UI. Non-admins never call this.
  Future<void> _loadLprConfig() async {
    setState(() => _lprConfigLoading = true);
    try {
      final cfg = await widget.api.getLprConfig(widget.session);
      if (!mounted) return;
      setState(() {
        _lprConfig = cfg;
        _lprConfigLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _lprConfigLoading = false);
    }
  }

  /// Persist a new watchlist fuzziness, preserving `enabled`/`retention_days`
  /// (the desktop client only edits fuzziness). Rethrows so the panel can
  /// surface a 403 inline.
  Future<void> _saveFuzz(double fuzz) async {
    final cfg = _lprConfig;
    if (cfg == null) return;
    final updated = await widget.api.putLprConfig(
      widget.session,
      enabled: cfg.enabled,
      retentionDays: cfg.retentionDays,
      watchlistFuzz: fuzz,
    );
    if (!mounted) return;
    setState(() => _lprConfig = updated);
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

  Future<void> _loadWatchlist() async {
    setState(() {
      _watchlistLoading = true;
      _watchlistError = null;
    });
    try {
      final entries = await widget.api.listWatchlist(widget.session);
      if (!mounted) return;
      setState(() {
        _watchlist = entries;
        _watchlistLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _watchlistError = '$e';
        _watchlistLoading = false;
      });
    }
  }

  /// Add (or, keyed on the normalized plate, edit) a watchlist entry, then
  /// refresh the panel. Rethrows so callers can surface the message (e.g. a
  /// non-admin 403) inline or via a SnackBar.
  Future<void> _addToWatchlist({
    required String plate,
    String? label,
    bool notify = true,
    String kind = 'watch',
  }) async {
    await widget.api.addWatchlist(
      widget.session,
      plate: plate,
      label: label,
      notify: notify,
      kind: kind,
    );
    await _loadWatchlist();
  }

  /// Remove a watchlist entry, then refresh. Rethrows for the caller to report.
  Future<void> _removeFromWatchlist(PlateWatchlistEntry entry) async {
    await widget.api.deleteWatchlist(widget.session, entry.id);
    await _loadWatchlist();
  }

  /// Per-read "add to watchlist" affordance: opens the Watch/Ignore chooser for
  /// the row's already-normalized plate, then upserts the operator's choice.
  /// Feedback + graceful 403 via a SnackBar.
  Future<void> _addReadToWatchlist(PlateRead read) async {
    if (read.plate.isEmpty) return;
    final choice = await showWatchlistDialog(
      context,
      plate: read.plate,
      title: 'Add to watchlist',
      fuzz: _lprConfig?.watchlistFuzz,
      onSaveFuzz: _lprConfig != null ? _saveFuzz : null,
    );
    if (choice == null || !mounted) return;
    try {
      await _addToWatchlist(
        plate: read.plate,
        kind: choice.kind,
        label: choice.label,
        notify: choice.notify,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(choice.kind == 'ignore'
              ? '${read.plate} added to ignore list'
              : '${read.plate} added to watchlist'),
        ),
      );
    } on CrumbApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.statusCode == 403
                ? 'Only admins can manage the watchlist.'
                : e.message,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Add to watchlist failed: $e')),
      );
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

  /// Row tap. A read linked to a detection event opens the pop-up clip player
  /// on that read's short plate-hit clip; a read with no event has no clip, so
  /// it falls back to the Playback timeline hand-off directly (the previous
  /// row-click behavior).
  void _openRead(PlateRead read) {
    final eventId = read.eventId;
    if (eventId == null || eventId.isEmpty) {
      widget.onViewFootage(read.cameraId, read.ts);
      return;
    }
    setState(() => _playing = read);
  }

  /// Open the single-plate report builder for [read] (OpenALPR-style: case
  /// reference + timezone + section toggles → a one-page forensic PDF). The
  /// builder reuses this screen's bounded-concurrency snapshot helper/cache via
  /// the [fetchSnapshot] callback so it hits the same fetch path the thumbnails
  /// do (for the plate crop, vehicle photo, and dossier thumbnails).
  void _openPlateReport(PlateRead read) {
    showPlateReportBuilder(
      context,
      api: widget.api,
      session: widget.session,
      read: read,
      cameras: widget.cameras,
      fetchSnapshot: (eventId) async {
        Uint8List? out;
        await _thumbGate.run(() async {
          out = await _fetchSnapshotBytes(widget.session, eventId);
        });
        return out;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final playing = _playing;
    final byId = {for (final c in widget.cameras) c.id: c};
    return Scaffold(
      backgroundColor: const Color(0xFF17181C),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildFilterBar(context),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: _buildBody(context)),
                      if (_showWatchlist)
                        _WatchlistPanel(
                          entries: _watchlist,
                          loading: _watchlistLoading,
                          error: _watchlistError,
                          canManage: widget.canManageWatchlist,
                          fuzz: _lprConfig?.watchlistFuzz,
                          fuzzLoading: _lprConfigLoading,
                          onSaveFuzz: _saveFuzz,
                          onAdd: _addToWatchlist,
                          onRemove: _removeFromWatchlist,
                          onRefresh: _loadWatchlist,
                          onClose: () =>
                              setState(() => _showWatchlist = false),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (playing != null)
              _PlateClipPlayer(
                key: ValueKey(playing.id),
                api: widget.api,
                session: widget.session,
                read: playing,
                cameraName:
                    byId[playing.cameraId]?.name ?? '(unknown camera)',
                imageMode: _imageDisplay,
                cropSize: _cropSize,
                onReport: () => _openPlateReport(playing),
                onClose: () => setState(() => _playing = null),
                // Same one-shot seek/focus hand-off the Clips "View on
                // timeline" uses: close the pop-up, then jump Playback to this
                // read's moment on its camera.
                onViewOnTimeline: () {
                  setState(() => _playing = null);
                  widget.onViewFootage(playing.cameraId, playing.ts);
                },
              ),
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
          _ViewModeToggle(value: _viewMode, onChanged: _setViewMode),
          if (_viewMode == PlatesViewMode.list)
            Tooltip(
              message: _collapse
                  ? 'Collapsing duplicate reads of the same car (both engines +\nrepeat reads) into one row. Click to show every raw read.'
                  : 'Showing every raw read. Click to collapse duplicates of the\nsame car into one row.',
              child: IconButton(
                onPressed: () => _setCollapse(!_collapse),
                icon: Icon(
                  _collapse ? Icons.layers : Icons.layers_clear,
                  size: 18,
                  color: _collapse
                      ? Theme.of(context).colorScheme.primary
                      : Colors.white54,
                ),
              ),
            ),
          _DisplayOptionsButton(
            imageMode: _imageDisplay,
            cropCorner: _cropCorner,
            cropSize: _cropSize,
            onModeChanged: _setImageDisplay,
            onCornerChanged: _setCropCorner,
            onSizeChanged: _setCropSize,
          ),
          if (_abAvailable)
            TextButton.icon(
              onPressed: () => showAbBenchmark(
                context,
                api: widget.api,
                session: widget.session,
                canConfirm: widget.canManageWatchlist,
              ),
              icon: const Icon(Icons.speed, size: 16, color: Colors.white70),
              label: const Text(
                'Benchmark',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          TextButton.icon(
            onPressed: () =>
                setState(() => _showWatchlist = !_showWatchlist),
            icon: Icon(
              _showWatchlist
                  ? Icons.playlist_add_check
                  : Icons.playlist_add,
              size: 16,
              color: Colors.white70,
            ),
            label: Text(
              _watchlist.isEmpty
                  ? 'Watchlist'
                  : 'Watchlist (${_watchlist.length})',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
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
    final watched = {for (final e in _watchlist) e.plate};
    String camName(String id) => byId[id]?.name ?? '(unknown camera)';
    switch (_viewMode) {
      case PlatesViewMode.list:
        // Collapse duplicate reads of one car (both engines + Frigate's own OCR
        // refinements) into a single representative row; off = every raw read.
        final groups = _collapse
            ? collapsePlateReads(_plates)
            : [for (final p in _plates) PlateGroup(p, [p])];
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: groups.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, color: Colors.white10),
          itemBuilder: (context, i) {
            final g = groups[i];
            final p = g.representative;
            return _PlateRow(
              key: ValueKey(p.id),
              read: p,
              group: g,
              cameraName: camName(p.cameraId),
              api: widget.api,
              session: widget.session,
              gate: _thumbGate,
              imageMode: _imageDisplay,
              cropCorner: _cropCorner,
              cropSize: _cropSize,
              onTap: () => _openRead(p),
              canManage: widget.canManageWatchlist,
              watched: watched.contains(p.plate),
              onAddToWatchlist: () => _addReadToWatchlist(p),
              onReport: () => _openPlateReport(p),
            );
          },
        );
      case PlatesViewMode.gallery:
        return _PlateGallery(
          reads: _plates,
          camName: camName,
          api: widget.api,
          session: widget.session,
          gate: _thumbGate,
          imageMode: _imageDisplay,
          cropCorner: _cropCorner,
          cropSize: _cropSize,
          onTap: _openRead,
        );
      case PlatesViewMode.grouped:
        return _PlateGroupedList(
          reads: _plates,
          camName: camName,
          api: widget.api,
          session: widget.session,
          gate: _thumbGate,
          imageMode: _imageDisplay,
          cropCorner: _cropCorner,
          cropSize: _cropSize,
          onTap: _openRead,
          canManage: widget.canManageWatchlist,
          watched: watched,
          onAddToWatchlist: _addReadToWatchlist,
          onReport: _openPlateReport,
        );
      case PlatesViewMode.timeline:
        return _PlateTimeline(
          reads: _plates,
          camName: camName,
          api: widget.api,
          session: widget.session,
          gate: _thumbGate,
          imageMode: _imageDisplay,
          cropCorner: _cropCorner,
          cropSize: _cropSize,
          onTap: _openRead,
        );
    }
  }
}

// ─── view-mode switcher ────────────────────────────────────────────────────

/// Segmented control for the four Plates layouts, styled to match
/// [_MatchToggle] (icon-only ChoiceChips with tooltips to stay compact in the
/// filter bar's Wrap).
class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle({required this.value, required this.onChanged});
  final PlatesViewMode value;
  final ValueChanged<PlatesViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    Widget seg(PlatesViewMode mode, IconData icon, String tip) {
      final active = value == mode;
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Tooltip(
          message: tip,
          child: ChoiceChip(
            label: Icon(
              icon,
              size: 16,
              color: active ? Colors.black : Colors.white70,
            ),
            selected: active,
            onSelected: (_) => onChanged(mode),
            showCheckmark: false,
            selectedColor: accent,
            backgroundColor: const Color(0xFF2A2D35),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        seg(PlatesViewMode.list, Icons.view_list, 'List'),
        seg(PlatesViewMode.gallery, Icons.grid_view, 'Gallery'),
        seg(PlatesViewMode.grouped, Icons.workspaces_outline, 'Grouped by plate'),
        seg(PlatesViewMode.timeline, Icons.timeline, 'Timeline feed'),
      ],
    );
  }
}

/// Toolbar popover to configure how plate previews show their image(s):
/// full frame + crop / full only / crop only, and (when both) which corner the
/// crop pins to over the full frame. Persisted via [PlatesPrefs].
class _DisplayOptionsButton extends StatelessWidget {
  const _DisplayOptionsButton({
    required this.imageMode,
    required this.cropCorner,
    required this.cropSize,
    required this.onModeChanged,
    required this.onCornerChanged,
    required this.onSizeChanged,
  });

  final PlateImageDisplay imageMode;
  final PlateCropCorner cropCorner;
  final PlateCropSize cropSize;
  final ValueChanged<PlateImageDisplay> onModeChanged;
  final ValueChanged<PlateCropCorner> onCornerChanged;
  final ValueChanged<PlateCropSize> onSizeChanged;

  @override
  Widget build(BuildContext context) {
    final cornersEnabled = imageMode == PlateImageDisplay.both;
    final cropEnabled = imageMode != PlateImageDisplay.fullOnly;
    PopupMenuItem<Object> header(String text) => PopupMenuItem<Object>(
          enabled: false,
          height: 26,
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        );
    CheckedPopupMenuItem<Object> modeItem(PlateImageDisplay m, String label) =>
        CheckedPopupMenuItem<Object>(
          value: m,
          checked: imageMode == m,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        );
    CheckedPopupMenuItem<Object> cornerItem(PlateCropCorner c, String label) =>
        CheckedPopupMenuItem<Object>(
          value: c,
          checked: cropCorner == c,
          enabled: cornersEnabled,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        );
    CheckedPopupMenuItem<Object> sizeItem(PlateCropSize s, String label) =>
        CheckedPopupMenuItem<Object>(
          value: s,
          checked: cropSize == s,
          enabled: cropEnabled,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        );
    return PopupMenuButton<Object>(
      tooltip: 'Image display',
      icon: const Icon(Icons.photo_size_select_large,
          color: Colors.white70, size: 18),
      color: const Color(0xFF23262E),
      onSelected: (v) {
        if (v is PlateImageDisplay) onModeChanged(v);
        if (v is PlateCropCorner) onCornerChanged(v);
        if (v is PlateCropSize) onSizeChanged(v);
      },
      itemBuilder: (context) => [
        header('SHOW'),
        modeItem(PlateImageDisplay.both, 'Full frame + plate crop'),
        modeItem(PlateImageDisplay.fullOnly, 'Full frame only'),
        modeItem(PlateImageDisplay.cropOnly, 'Plate crop only'),
        const PopupMenuDivider(),
        header('CROP SIZE'),
        sizeItem(PlateCropSize.small, 'Small'),
        sizeItem(PlateCropSize.medium, 'Medium'),
        sizeItem(PlateCropSize.large, 'Large'),
        const PopupMenuDivider(),
        header('CROP CORNER (IN CARDS)'),
        cornerItem(PlateCropCorner.topLeft, 'Top-left'),
        cornerItem(PlateCropCorner.topRight, 'Top-right'),
        cornerItem(PlateCropCorner.bottomLeft, 'Bottom-left'),
        cornerItem(PlateCropCorner.bottomRight, 'Bottom-right'),
      ],
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
    required this.imageMode,
    required this.cropCorner,
    required this.cropSize,
    required this.onTap,
    required this.canManage,
    required this.watched,
    required this.onAddToWatchlist,
    required this.onReport,
    this.group,
  });

  final PlateRead read;

  /// The collapsed group this row represents — which engine(s) saw the car, how
  /// many raw reads merged, and any disagreeing readings. Null renders a plain
  /// row (no engine chips). A single-read group shows just its source chip.
  final PlateGroup? group;
  final String cameraName;
  final CrumbApi api;
  final Session session;
  final _ConcurrencyGate gate;
  final PlateImageDisplay imageMode;
  final PlateCropCorner cropCorner;
  final PlateCropSize cropSize;
  final VoidCallback onTap;

  /// Admin — may add this read's plate to the watchlist.
  final bool canManage;

  /// This read's plate is already on the watchlist (shows a filled star).
  final bool watched;

  /// Add this read's plate to the watchlist.
  final VoidCallback onAddToWatchlist;

  /// Open the single-plate report builder for this read.
  final VoidCallback onReport;

  /// A small engine chip per source that saw this car (Frigate / Crumb), plus a
  /// "×N" badge when more than one raw read collapsed here. Empty when there's
  /// no group or no known source.
  List<Widget> _engineChips() {
    final g = group;
    if (g == null) return const [];
    final chips = <Widget>[];
    for (final s in g.sources) {
      chips
        ..add(const SizedBox(width: 6))
        ..add(_engineChip(s));
    }
    if (g.count > 1) {
      chips
        ..add(const SizedBox(width: 6))
        ..add(Text(
          '×${g.count}',
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ));
    }
    return chips;
  }

  /// When the engines disagreed on the plate, a subtle line naming each engine's
  /// alternate reading — the at-a-glance A/B signal in the collapsed list.
  List<Widget> _disagreementLine() {
    final d = group?.disagreements;
    if (d == null || d.isEmpty) return const [];
    final parts =
        d.entries.map((e) => '${_engineLabel(e.key)} read ${e.value}').join('  •  ');
    return [
      const SizedBox(height: 2),
      Row(
        children: [
          const Icon(Icons.compare_arrows, size: 12, color: Color(0xFFE8A33D)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              parts,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFE8A33D), fontSize: 11),
            ),
          ),
        ],
      ),
    ];
  }

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
              imageMode: imageMode,
              cropCorner: cropCorner,
              cropSize: cropSize,
              // The list row has plenty of horizontal room — show both large,
              // side-by-side.
              sideBySide: true,
              width: imageMode == PlateImageDisplay.both ? 320 : 180,
              height: 92,
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
                      ..._engineChips(),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _fmtDateTime(read.ts),
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  ..._disagreementLine(),
                ],
              ),
            ),
            if (canManage && read.plate.isNotEmpty) ...[
              const SizedBox(width: 4),
              IconButton(
                tooltip: watched ? 'On watchlist' : 'Add to watchlist',
                visualDensity: VisualDensity.compact,
                onPressed: watched ? null : onAddToWatchlist,
                icon: Icon(
                  watched ? Icons.star : Icons.star_border,
                  size: 18,
                  color: watched ? const Color(0xFFE8A33D) : Colors.white38,
                ),
              ),
            ],
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Report (PDF)',
              visualDensity: VisualDensity.compact,
              onPressed: onReport,
              icon: const Icon(
                Icons.description_outlined,
                size: 18,
                color: Colors.white38,
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
    this.width = 92,
    this.height = 56,
    this.radius = 6,
    this.iconSize = 22,
    this.imageMode = PlateImageDisplay.fullOnly,
    this.cropCorner = PlateCropCorner.bottomRight,
    this.cropSize = PlateCropSize.medium,
    this.sideBySide = false,
  });

  final PlateRead read;
  final CrumbApi api;
  final Session session;
  final _ConcurrencyGate gate;
  final double width;
  final double height;
  final double radius;
  final double iconSize;

  /// Which image(s) to show — the full frame, the plate crop, or both. The crop
  /// is derived client-side from the fetched snapshot (off the UI isolate,
  /// cached) and always falls back to the full frame when the read has no bbox
  /// or the crop fails.
  final PlateImageDisplay imageMode;

  /// When [imageMode] is `both` and [sideBySide] is false, the corner of the
  /// full frame the crop is pinned to.
  final PlateCropCorner cropCorner;

  /// How large the crop renders (pinned inset fraction / side-by-side width).
  final PlateCropSize cropSize;

  /// When [imageMode] is `both`, lay the full frame and crop out side-by-side
  /// (list rows, which have the horizontal room) instead of pinning the crop as
  /// a corner inset over the full frame (compact/gallery thumbs).
  final bool sideBySide;

  @override
  State<_PlateThumb> createState() => _PlateThumbState();
}

class _PlateThumbState extends State<_PlateThumb> {
  Uint8List? _bytes;
  Uint8List? _crop; // plate-region crop (when imageMode wants it + bbox exists)
  bool _requested = false;
  bool _disposed = false;

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
      _maybeCrop(cached); // may set _crop synchronously from the crop cache
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
    final bytes = await _fetchSnapshotBytes(widget.session, eventId);
    if (_disposed || bytes == null) return;
    if (mounted) setState(() => _bytes = bytes);
    _maybeCrop(bytes);
  }

  /// Derive the plate-region crop from [bytes] (no network) when this thumb is
  /// a cropping one and the read has a bbox. Uses the shared crop cache: a hit
  /// is applied synchronously; a miss computes off the UI isolate and then
  /// setState-s. Keyed by read id (bbox belongs to the read).
  void _maybeCrop(Uint8List bytes) {
    if (widget.imageMode == PlateImageDisplay.fullOnly || _disposed) return;
    final bbox = widget.read.bbox;
    if (bbox == null || bbox.length < 4) return;
    final key = widget.read.id;
    final existing = peekPlateCrop(key);
    if (existing != null) {
      _crop = existing;
      return;
    }
    unawaited(() async {
      final crop = await cachedPlateCrop(key, bytes, bbox);
      if (_disposed || crop == null) return;
      if (mounted) setState(() => _crop = crop);
    }());
  }

  @override
  Widget build(BuildContext context) {
    // Decode the full-res JPEG down to roughly the thumbnail's pixel size
    // rather than at native resolution — a 1080p snapshot shown in a 92px cell
    // otherwise pins a multi-MB decoded bitmap in the image cache per row. The
    // cached BYTES stay full-res (the report crop needs them); only the decode
    // is downscaled. Gallery/expanded tiles pass an infinite width, so cap the
    // decode target for those at a sensible thumbnail ceiling.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final logicalW = widget.width.isFinite ? widget.width : 320.0;
    final cacheW = (logicalW * dpr).round().clamp(1, 1024);

    final full = _bytes;
    final crop = _crop;
    // Resolve the operator's display preference against what we actually have.
    // A crop only exists when the read had a bbox and the client crop succeeded;
    // when it doesn't, every mode gracefully falls back to the full frame.
    final wantCrop = widget.imageMode != PlateImageDisplay.fullOnly;
    final wantFull = widget.imageMode != PlateImageDisplay.cropOnly;
    final showCrop = wantCrop && crop != null;
    final showFull = wantFull || !showCrop;

    // List / grouped / timeline "both" layout: a natural-aspect full frame plus
    // a reserved crop slot (filled or empty), sized to content — NOT the wide
    // fixed box, which would cover-crop the full frame into a stretched-looking
    // horizontal slice when there's no crop. The reserved slot keeps the plate
    // text aligned across rows whether or not a given read has a crop.
    if (widget.sideBySide &&
        widget.imageMode == PlateImageDisplay.both &&
        full != null) {
      return _sideBySide(full, crop, cacheW);
    }

    Widget content;
    if (full == null && crop == null) {
      content = _placeholder();
    } else if (showCrop && showFull && full != null) {
      content = _overlay(full, crop, cacheW);
    } else if (showCrop) {
      // Crop only: box the crop at its OWN aspect (from the read's bbox) so
      // `contain` fills it edge-to-edge — a wide/short plate no longer floats
      // between big black letterbox bars in a near-square slot.
      content = _fittedCrop(crop, cacheW);
    } else if (full != null) {
      content = _img(full, BoxFit.cover, cacheW);
    } else {
      content = _placeholder();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(width: widget.width, height: widget.height, child: content),
    );
  }

  Widget _img(Uint8List bytes, BoxFit fit, int cacheW, {bool background = false}) {
    final image = Image.memory(
      bytes,
      fit: fit,
      gaplessPlayback: true,
      cacheWidth: cacheW,
    );
    if (!background) return image;
    return Container(color: Colors.black, child: image);
  }

  /// Display aspect (w/h) of the plate crop, derived from the read's
  /// normalized bbox. The bbox is in frame FRACTIONS, so its w/h must be
  /// scaled by the frame's own aspect (snapshots are 16:9 — the same
  /// assumption [_sideBySide] makes for the full frame) to get the crop's
  /// pixel aspect. Clamped to a sane band so a degenerate box can't produce
  /// an absurd slot. Null when the read has no usable bbox.
  double? get _cropAspect {
    final bb = widget.read.bbox;
    if (bb == null || bb.length < 4) return null;
    final bw = bb[2], bh = bb[3];
    if (bw <= 0 || bh <= 0) return null;
    return ((bw / bh) * (16 / 9)).clamp(1.0, 8.0).toDouble();
  }

  /// The crop centered in its (fixed) slot with the black backing sized to
  /// the crop's OWN aspect instead of the whole slot — `contain` then fills
  /// the backing edge-to-edge, so a wide/short plate shows no letterbox bars.
  /// Falls back to the old letterboxed render when the bbox is unusable.
  Widget _fittedCrop(Uint8List crop, int cacheW) {
    final aspect = _cropAspect;
    final image = _img(crop, BoxFit.contain, cacheW, background: true);
    if (aspect == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: image,
      );
    }
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: AspectRatio(aspectRatio: aspect, child: image),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Icon(
        Icons.directions_car_outlined,
        color: Colors.white24,
        size: widget.iconSize,
      ),
    );
  }

  /// Full frame with the plate crop pinned as a bordered inset in the chosen
  /// corner — the compact/gallery layout.
  Widget _overlay(Uint8List full, Uint8List crop, int cacheW) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _img(full, BoxFit.cover, cacheW),
        Align(
          alignment: switch (widget.cropCorner) {
            PlateCropCorner.topLeft => Alignment.topLeft,
            PlateCropCorner.topRight => Alignment.topRight,
            PlateCropCorner.bottomLeft => Alignment.bottomLeft,
            PlateCropCorner.bottomRight => Alignment.bottomRight,
          },
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: FractionallySizedBox(
              widthFactor: switch (widget.cropSize) {
                PlateCropSize.small => 0.34,
                PlateCropSize.medium => 0.46,
                PlateCropSize.large => 0.62,
              },
              heightFactor: switch (widget.cropSize) {
                PlateCropSize.small => 0.30,
                PlateCropSize.medium => 0.42,
                PlateCropSize.large => 0.56,
              },
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white70, width: 1),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 4),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.memory(
                  crop,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Full frame + plate crop laid out horizontally (list / grouped / timeline).
  /// The full frame is shown at its natural 16:9 aspect (so it never looks
  /// stretched), and the crop sits in a fixed-width slot to its right — sized by
  /// the crop-size preference. The slot is reserved even when there's no crop
  /// (a subtle placeholder), so text stays aligned across rows. Intrinsic width.
  Widget _sideBySide(Uint8List full, Uint8List? crop, int cacheW) {
    final h = widget.height;
    final fullW = h * 16 / 9;
    final cropW = switch (widget.cropSize) {
      PlateCropSize.small => h * 1.5,
      PlateCropSize.medium => h * 2.0,
      PlateCropSize.large => h * 2.6,
    };
    final r = BorderRadius.circular(widget.radius);
    return SizedBox(
      height: h,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: r,
            child: SizedBox(
              width: fullW,
              height: h,
              child: _img(full, BoxFit.cover, cacheW),
            ),
          ),
          const SizedBox(width: 6),
          // Crop slot: fixed OUTER width so the plate text stays aligned
          // across rows, but the black backing inside is sized to the crop's
          // own aspect (via [_fittedCrop]) so the plate fills it edge-to-edge
          // instead of floating between black letterbox bars.
          SizedBox(
            width: cropW,
            height: h,
            child: crop != null
                ? _fittedCrop(crop, cacheW)
                : ClipRRect(
                    borderRadius: r,
                    child: Container(
                      color: Colors.black,
                      alignment: Alignment.center,
                      child: Icon(Icons.no_photography_outlined,
                          color: Colors.white24, size: widget.iconSize),
                    ),
                  ),
          ),
        ],
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

// ─── gallery view ──────────────────────────────────────────────────────────

/// Responsive grid of plate cards: snapshot thumbnail (or placeholder), the
/// plate (mono), camera, time, and a confidence chip. A card tap routes through
/// the same [onTap] the list uses (pop-up clip player, or timeline hand-off for
/// a read with no linked event).
class _PlateGallery extends StatelessWidget {
  const _PlateGallery({
    required this.reads,
    required this.camName,
    required this.api,
    required this.session,
    required this.gate,
    required this.imageMode,
    required this.cropCorner,
    required this.cropSize,
    required this.onTap,
  });

  final List<PlateRead> reads;
  final String Function(String cameraId) camName;
  final CrumbApi api;
  final Session session;
  final _ConcurrencyGate gate;
  final PlateImageDisplay imageMode;
  final PlateCropCorner cropCorner;
  final PlateCropSize cropSize;
  final void Function(PlateRead) onTap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.15,
      ),
      itemCount: reads.length,
      itemBuilder: (context, i) {
        final p = reads[i];
        return _PlateGalleryCard(
          key: ValueKey(p.id),
          read: p,
          cameraName: camName(p.cameraId),
          api: api,
          session: session,
          gate: gate,
          imageMode: imageMode,
          cropCorner: cropCorner,
          cropSize: cropSize,
          onTap: () => onTap(p),
        );
      },
    );
  }
}

class _PlateGalleryCard extends StatelessWidget {
  const _PlateGalleryCard({
    super.key,
    required this.read,
    required this.cameraName,
    required this.api,
    required this.session,
    required this.gate,
    required this.imageMode,
    required this.cropCorner,
    required this.cropSize,
    required this.onTap,
  });

  final PlateRead read;
  final String cameraName;
  final CrumbApi api;
  final Session session;
  final _ConcurrencyGate gate;
  final PlateImageDisplay imageMode;
  final PlateCropCorner cropCorner;
  final PlateCropSize cropSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1E2026),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _PlateThumb(
                read: read,
                api: api,
                session: session,
                gate: gate,
                width: double.infinity,
                height: double.infinity,
                radius: 0,
                iconSize: 34,
                // Gallery cards feature the plate: the crop pins to the chosen
                // corner over the full frame (or per the operator's display
                // preference — full-only / crop-only). Falls back gracefully
                // when there's no bbox.
                imageMode: imageMode,
                cropCorner: cropCorner,
                cropSize: cropSize,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          read.plate.isEmpty ? '—' : read.plate,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.3,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _ConfidenceChip(read.confidence),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.videocam_outlined,
                          size: 12, color: Colors.white38),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          cameraName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _fmtDateTime(read.ts),
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── grouped-by-plate view ─────────────────────────────────────────────────

/// One collapsed group: a unique normalized plate, its sighting count,
/// first/last seen, and the distinct cameras it was seen on.
class _PlateGroup {
  _PlateGroup(this.plate);
  final String plate;
  final List<PlateRead> reads = [];
  final Set<String> cameraIds = {};
  DateTime? first;
  DateTime? last;

  void add(PlateRead r) {
    reads.add(r);
    cameraIds.add(r.cameraId);
    if (first == null || r.ts.isBefore(first!)) first = r.ts;
    if (last == null || r.ts.isAfter(last!)) last = r.ts;
  }
}

/// Collapses the fetched page by normalized plate — one expandable row per
/// unique plate (count + first/last seen + camera list), expanding to the
/// individual reads (reusing [_PlateRow]). Pure client-side grouping over the
/// current page; groups are ordered by most-recent sighting.
class _PlateGroupedList extends StatelessWidget {
  const _PlateGroupedList({
    required this.reads,
    required this.camName,
    required this.api,
    required this.session,
    required this.gate,
    required this.imageMode,
    required this.cropCorner,
    required this.cropSize,
    required this.onTap,
    required this.canManage,
    required this.watched,
    required this.onAddToWatchlist,
    required this.onReport,
  });

  final List<PlateRead> reads;
  final String Function(String cameraId) camName;
  final CrumbApi api;
  final Session session;
  final _ConcurrencyGate gate;
  final PlateImageDisplay imageMode;
  final PlateCropCorner cropCorner;
  final PlateCropSize cropSize;
  final void Function(PlateRead) onTap;
  final bool canManage;
  final Set<String> watched;
  final void Function(PlateRead) onAddToWatchlist;
  final void Function(PlateRead) onReport;

  List<_PlateGroup> _group() {
    final byPlate = <String, _PlateGroup>{};
    for (final r in reads) {
      final key = r.plate.isEmpty ? '—' : r.plate;
      (byPlate[key] ??= _PlateGroup(key)).add(r);
    }
    final groups = byPlate.values.toList()
      ..sort((a, b) => (b.last ?? DateTime(0)).compareTo(a.last ?? DateTime(0)));
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _group();
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: groups.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: Colors.white10),
      itemBuilder: (context, i) {
        final g = groups[i];
        final cams = g.cameraIds.map(camName).toList()..sort();
        final camLabel = cams.length == 1
            ? cams.first
            : '${cams.length} cameras';
        // Newest-first within the group so the expansion mirrors the list view.
        final sorted = g.reads.toList()
          ..sort((a, b) => b.ts.compareTo(a.ts));
        return Theme(
          // Strip ExpansionTile's default dividers so it blends with the list.
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            iconColor: Colors.white54,
            collapsedIconColor: Colors.white54,
            leading: _PlateThumb(
              read: sorted.first,
              api: api,
              session: session,
              gate: gate,
              imageMode: imageMode,
              cropCorner: cropCorner,
              cropSize: cropSize,
              sideBySide: imageMode == PlateImageDisplay.both,
              width: imageMode == PlateImageDisplay.both ? 200 : 110,
              height: 64,
            ),
            title: Text(
              g.plate,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
                fontFamily: 'monospace',
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                '${g.reads.length} sighting${g.reads.length == 1 ? '' : 's'}  •  '
                '$camLabel\n'
                'First ${_fmtDateTime(g.first ?? sorted.last.ts)}  •  '
                'Last ${_fmtDateTime(g.last ?? sorted.first.ts)}',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
            childrenPadding: const EdgeInsets.only(bottom: 4),
            children: [
              for (final r in sorted)
                _PlateRow(
                  key: ValueKey(r.id),
                  read: r,
                  cameraName: camName(r.cameraId),
                  api: api,
                  session: session,
                  gate: gate,
                  imageMode: imageMode,
                  cropCorner: cropCorner,
                  cropSize: cropSize,
                  onTap: () => onTap(r),
                  canManage: canManage,
                  watched: watched.contains(r.plate),
                  onAddToWatchlist: () => onAddToWatchlist(r),
                  onReport: () => onReport(r),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ─── timeline feed view ────────────────────────────────────────────────────

/// Chronological (newest-first) large-row feed — bigger thumbnail, plate,
/// camera, and time per row for touch/scan-friendly browsing. Taps route
/// through the same [onTap] as the list.
class _PlateTimeline extends StatelessWidget {
  const _PlateTimeline({
    required this.reads,
    required this.camName,
    required this.api,
    required this.session,
    required this.gate,
    required this.imageMode,
    required this.cropCorner,
    required this.cropSize,
    required this.onTap,
  });

  final List<PlateRead> reads;
  final String Function(String cameraId) camName;
  final CrumbApi api;
  final Session session;
  final _ConcurrencyGate gate;
  final PlateImageDisplay imageMode;
  final PlateCropCorner cropCorner;
  final PlateCropSize cropSize;
  final void Function(PlateRead) onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      itemCount: reads.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final p = reads[i];
        return Material(
          color: const Color(0xFF1E2026),
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onTap(p),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  _PlateThumb(
                    read: p,
                    api: api,
                    session: session,
                    gate: gate,
                    imageMode: imageMode,
                    cropCorner: cropCorner,
                    cropSize: cropSize,
                    // Big feed rows have the room — show both side-by-side, wide.
                    sideBySide: imageMode == PlateImageDisplay.both,
                    width: imageMode == PlateImageDisplay.both ? 320 : 190,
                    height: 108,
                    iconSize: 34,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          p.plate.isEmpty ? '—' : p.plate,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(Icons.videocam_outlined,
                                size: 14, color: Colors.white38),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                camName(p.cameraId),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            if (p.region != null && p.region!.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Text(
                                p.region!,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _fmtDateTime(p.ts),
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _ConfidenceChip(p.confidence),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right,
                      color: Colors.white24, size: 22),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── pop-up plate-hit clip player ──────────────────────────────────────────

/// Dismissible overlay that plays a plate read's short detection clip — the
/// same style/behavior as the Clips tab's clip player (both render through the
/// shared [ClipPlayerShell]: Positioned.fill overlay over the tab, closes on
/// Esc / the close X / a tap on the dark backdrop, actions under the video),
/// trimmed to what a plate hit needs: no zoom/snapshot/bookmark, plus a "View
/// on timeline" hand-off.
///
/// The clip is resolved exactly like a Clips detection clip: the read's
/// [PlateRead.eventId] is the `d:<event-uuid>` clip id, played from
/// `/clip/d:<event-uuid>/clip.mp4?q=preview` on a scoped media `?token=`
/// minted for the read's camera (mirrors `_ClipPlayerState._open`). Only opened
/// for reads that have an event_id, so a clip always exists to resolve.
class _PlateClipPlayer extends StatefulWidget {
  const _PlateClipPlayer({
    super.key,
    required this.api,
    required this.session,
    required this.read,
    required this.cameraName,
    required this.imageMode,
    required this.cropSize,
    required this.onReport,
    required this.onClose,
    required this.onViewOnTimeline,
  });

  final CrumbApi api;
  final Session session;
  final PlateRead read;
  final String cameraName;

  /// Operator's plate-image preference — hides the prominent plate crop above
  /// the clip when set to full-frame-only.
  final PlateImageDisplay imageMode;

  /// How tall the prominent plate crop renders above the clip.
  final PlateCropSize cropSize;
  final VoidCallback onReport;
  final VoidCallback onClose;
  final VoidCallback onViewOnTimeline;

  @override
  State<_PlateClipPlayer> createState() => _PlateClipPlayerState();
}

class _PlateClipPlayerState extends State<_PlateClipPlayer> {
  Player? _player;
  VideoController? _controller;
  int _loadAttempt = 0;
  Timer? _watchdog;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;
  String? _error;
  // Clip rendition: 'preview' (SD, fast on-demand transcode) or 'full' (HD, the
  // original segment quality). Mirrors the Clips player's quality toggle — a
  // clip has exactly these two renditions (there is no live "Auto" to pick).
  String _quality = 'preview';
  bool _qualityBusy = false;
  // Drives the custom transport bar's play/pause icon (issue #143): we render
  // our own minimal controls, not media_kit's native overlay.
  bool _playing = false;
  // Latches true once the clip has ever started playing. The cold-load watchdog
  // must only retry a stalled INITIAL load — once playback has begun, a paused
  // state is the user pausing (or a seek/frame-step), NOT a stall, so the
  // watchdog must never re-open the clip from the start again.
  bool _everPlayed = false;

  @override
  void initState() {
    super.initState();
    // Esc closes the pop-up regardless of which node holds keyboard focus — a
    // HardwareKeyboard handler fires for every key event, independent of the
    // focus chain (same rationale as the Clips clip player's _onKeyEvent).
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    unawaited(_open(resetAttempt: true));
  }

  /// Lifetime-of-the-open-clip Esc handler; consumes only the Esc it acts on.
  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    if (!mounted) return false;
    // A pushed route on top (dialog, menu) owns Esc — don't close under it.
    if (Navigator.of(context).canPop()) return false;
    widget.onClose();
    return true;
  }

  /// `/clip/d:<event-uuid>/clip.mp4?q=preview` — the detection clip for this
  /// read's sibling event, the same media route the Clips tab plays.
  String? _clipRelUrl({int? retry}) {
    final eventId = widget.read.eventId;
    if (eventId == null || eventId.isEmpty) return null;
    final id = Uri.encodeComponent('d:$eventId');
    final r = retry != null ? '&_r=$retry' : '';
    return '/clip/$id/clip.mp4?q=$_quality$r';
  }

  /// Switch the clip rendition (SD=preview / HD=full) and re-open in place at
  /// the current position-agnostic start, mirroring the Clips player's toggle.
  Future<void> _setQuality(String q) async {
    if (_qualityBusy || _player == null || q == _quality) return;
    setState(() {
      _quality = q;
      _qualityBusy = true;
      _error = null;
    });
    try {
      final rel = _clipRelUrl();
      if (rel == null) return;
      final url = await widget.api.mediaUrlForCamera(
        widget.session,
        widget.read.cameraId,
        rel,
      );
      if (url == null || !mounted) return;
      await _player?.open(Media(url));
      await _player?.play();
      _armWatchdog();
    } finally {
      if (mounted) setState(() => _qualityBusy = false);
    }
  }

  Future<void> _open({bool resetAttempt = false, int? retry}) async {
    if (resetAttempt) _loadAttempt = 0;
    final rel = _clipRelUrl(retry: retry);
    if (rel == null) {
      if (mounted) setState(() => _error = 'No clip for this read.');
      return;
    }
    final url = await widget.api.mediaUrlForCamera(
      widget.session,
      widget.read.cameraId,
      rel,
    );
    if (!mounted) return;
    if (url == null) {
      setState(() => _error = 'Could not authorize this clip.');
      return;
    }
    var player = _player;
    if (player == null) {
      player = Player();
      final p = player.platform;
      if (p is NativePlayer) {
        for (final kv in const [
          ['hwdec', 'auto'],
          ['cache', 'yes'],
          ['demuxer-readahead-secs', '2.0'],
          ['demuxer-max-bytes', '32MiB'],
          ['demuxer-max-back-bytes', '1MiB'],
          ['network-timeout', '10'],
          ['demuxer-lavf-o', 'analyzeduration=500000,probesize=500000'],
          // Frame-accurate seeking. Without exact seeks, a small backward seek
          // snaps to the same keyframe (frame-back appears to do nothing) while
          // forward crosses into the next frame — so the ± one-frame buttons in
          // the transport only worked one direction. Force exact seeks.
          ['hr-seek', 'yes'],
        ]) {
          try {
            await p.setProperty(kv[0], kv[1]);
          } catch (_) {
            /* non-fatal */
          }
        }
      }
      _playingSub = player.stream.playing.listen((playing) {
        if (playing) {
          _everPlayed = true;
          _watchdog?.cancel();
        }
        if (mounted) setState(() => _playing = playing);
      });
      // Rebuild once the video's dimensions are known so the pane can
      // shrink-wrap the video's aspect — the dark space around it is then
      // genuine backdrop (tap = close) rather than letterbox inside an
      // oversized video box.
      _widthSub = player.stream.width.listen((w) {
        if (w != null && w > 0 && mounted) setState(() {});
      });
      _heightSub = player.stream.height.listen((h) {
        if (h != null && h > 0 && mounted) setState(() {});
      });
      final controller = VideoController(player);
      setState(() {
        _player = player;
        _controller = controller;
      });
    }
    await player.open(Media(url));
    await player.play();
    _armWatchdog();
  }

  /// A cold plate-hit clip is transcoded on demand, so a slow first load is
  /// expected; retry a stalled load a couple of times before giving up.
  void _armWatchdog() {
    _watchdog?.cancel();
    // Only the initial cold load is watched. Once the clip has ever played, a
    // non-playing state is a user pause/seek — never re-open on that.
    if (_everPlayed) return;
    _watchdog = Timer(_plateClipLoadTimeout, () {
      if (!mounted || _everPlayed) return;
      final st = _player?.state;
      final playing = st != null && st.playing && st.position > Duration.zero;
      if (playing) return;
      unawaited(_retryLoad());
    });
  }

  Future<void> _retryLoad() async {
    _watchdog?.cancel();
    if (_loadAttempt >= _plateClipMaxRetries) {
      if (mounted) setState(() => _error = 'Clip is slow to load — try again.');
      return;
    }
    _loadAttempt++;
    final rel = _clipRelUrl(retry: _loadAttempt);
    if (rel == null) return;
    final url = await widget.api.mediaUrlForCamera(
      widget.session,
      widget.read.cameraId,
      rel,
    );
    if (url == null || !mounted) return;
    await _player?.open(Media(url));
    await _player?.play();
    _armWatchdog();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _watchdog?.cancel();
    _playingSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final read = widget.read;
    final plate = read.plate.isEmpty ? '—' : read.plate;
    return Positioned.fill(
      child: ClipPlayerShell(
        title: '$plate — ${widget.cameraName}',
        titleStyle: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
          fontFamily: 'monospace',
        ),
        onClose: widget.onClose,
        // Prominent plate crop (bbox region of the snapshot) pinned above
        // the clip. Fetches the snapshot itself if a tile hasn't cached it,
        // so it shows reliably. Renders nothing when the read has no bbox;
        // hidden entirely when the operator chose full-frame-only.
        header: widget.imageMode != PlateImageDisplay.fullOnly
            ? _PlateDetailCrop(
                read: read,
                session: widget.session,
                cropSize: widget.cropSize,
              )
            : null,
        video: _buildVideoPane(),
        // Our own minimal transport (issue #143): restart + frame-step +
        // play/pause, directly under the video. Native media_kit controls are
        // suppressed via NoVideoControls.
        transport: (_error == null && _controller != null) ? _buildTransport() : null,
        // Primary actions live in a row under the transport (the shell lays
        // them out); the title bar keeps just the plate label and the X.
        actions: [
          _QualityToggle(
            quality: _quality,
            busy: _qualityBusy,
            onChanged: _setQuality,
          ),
          TextButton.icon(
            onPressed: widget.onReport,
            icon: const Icon(Icons.description_outlined,
                size: 16, color: Colors.white70),
            label: const Text(
              'Report',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
          TextButton.icon(
            onPressed: widget.onViewOnTimeline,
            icon: const Icon(Icons.timeline, size: 16, color: Colors.white70),
            label: const Text(
              'View on timeline',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  /// The video pane, shrink-wrapped to the video's aspect once known so the
  /// dark space around it is genuine backdrop (tap = close) rather than
  /// letterbox inside an oversized video box.
  Widget _buildVideoPane() {
    if (_error != null) {
      return Text(_error!, style: const TextStyle(color: Colors.redAccent));
    }
    if (_controller == null) return const CircularProgressIndicator();
    final video = Video(
      controller: _controller!,
      controls: NoVideoControls,
      fit: BoxFit.contain,
    );
    final vw = (_player?.state.width ?? 0).toDouble();
    final vh = (_player?.state.height ?? 0).toDouble();
    if (vw > 0 && vh > 0) {
      return AspectRatio(aspectRatio: vw / vh, child: video);
    }
    return video;
  }

  /// Minimal control bar: back-to-start and play/pause, driven by the player.
  /// Nudge the clip by roughly one frame. media_kit has no frame-step API, so
  /// pause and seek by ~1/30 s relative to the current position (clamped ≥ 0).
  void _stepFrame(bool forward) {
    final p = _player;
    if (p == null) return;
    p.pause();
    const frame = Duration(milliseconds: 33);
    final pos = p.state.position;
    var target = forward ? pos + frame : pos - frame;
    if (target < Duration.zero) target = Duration.zero;
    p.seek(target);
  }

  Widget _buildTransport() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Back to start',
            onPressed: () {
              final p = _player;
              if (p == null) return;
              p.seek(Duration.zero);
              p.play();
            },
            icon: const Icon(Icons.replay, color: Colors.white70, size: 24),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Back one frame',
            onPressed: () => _stepFrame(false),
            icon: const Icon(Icons.navigate_before,
                color: Colors.white70, size: 26),
          ),
          IconButton(
            tooltip: _playing ? 'Pause' : 'Play',
            onPressed: () {
              final p = _player;
              if (p == null) return;
              if (p.state.playing) {
                p.pause();
              } else {
                p.play();
              }
            },
            icon: Icon(
              _playing ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 28,
            ),
          ),
          IconButton(
            tooltip: 'Forward one frame',
            onPressed: () => _stepFrame(true),
            icon: const Icon(Icons.navigate_next,
                color: Colors.white70, size: 26),
          ),
        ],
      ),
    );
  }
}

/// The prominent plate crop shown in the detail pop-up: the plate region
/// cropped from the snapshot bytes already fetched for this read's tile (read
/// straight from the shared snapshot cache — no network). The crop itself is
/// computed off the UI isolate and cached (see plate_crop.dart). Renders
/// nothing when there's no cached snapshot or no bbox, so the pop-up simply
/// shows the clip in that case.
class _PlateDetailCrop extends StatefulWidget {
  const _PlateDetailCrop({
    required this.read,
    required this.session,
    required this.cropSize,
  });

  final PlateRead read;
  final Session session;
  final PlateCropSize cropSize;

  @override
  State<_PlateDetailCrop> createState() => _PlateDetailCropState();
}

class _PlateDetailCropState extends State<_PlateDetailCrop> {
  Uint8List? _crop;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _compute();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _compute() async {
    final read = widget.read;
    final bbox = read.bbox;
    final eventId = read.eventId;
    if (bbox == null || bbox.length < 4 || eventId == null || eventId.isEmpty) {
      return;
    }
    final existing = peekPlateCrop(read.id);
    if (existing != null) {
      setState(() => _crop = existing);
      return;
    }
    // Prefer the tile's cached snapshot; if none (the popup was opened without
    // the tile ever rendering), fetch it here so the crop still shows.
    var bytes = _snapshotCache[eventId];
    bytes ??= await _fetchSnapshotBytes(widget.session, eventId);
    if (_disposed || bytes == null) return;
    final crop = await cachedPlateCrop(read.id, bytes, bbox);
    if (_disposed || crop == null) return;
    if (mounted) setState(() => _crop = crop);
  }

  @override
  Widget build(BuildContext context) {
    final crop = _crop;
    if (crop == null) return const SizedBox.shrink();
    final height = switch (widget.cropSize) {
      PlateCropSize.small => 60.0,
      PlateCropSize.medium => 96.0,
      PlateCropSize.large => 150.0,
    };
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 4, bottom: 8),
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white38),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.memory(
            crop,
            height: height,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}

/// Compact SD/HD rendition toggle for the plate-hit clip player. SD = the fast
/// on-demand preview transcode, HD = the original full-quality clip. A clip has
/// exactly these two renditions, so there is no live "Auto" to choose.
class _QualityToggle extends StatelessWidget {
  const _QualityToggle({
    required this.quality,
    required this.busy,
    required this.onChanged,
  });

  final String quality; // 'preview' (SD) | 'full' (HD)
  final bool busy;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    Widget seg(String label, String value) {
      final sel = quality == value;
      return InkWell(
        onTap: (busy || sel) ? null : () => onChanged(value),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
              color: sel ? accent : Colors.white54,
            ),
          ),
        ),
      );
    }

    return Opacity(
      opacity: busy ? 0.5 : 1,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            seg('SD', 'preview'),
            Container(width: 1, height: 16, color: Colors.white24),
            seg('HD', 'full'),
          ],
        ),
      ),
    );
  }
}

// ─── watchlist panel ───────────────────────────────────────────────────────

/// Right-hand side panel: the LPR plate watchlist. Any account that can see
/// the Plates tab may read it; [canManage] (admin) gates the add form and the
/// per-entry Remove button. Add/remove call back into the screen (which owns
/// the list + refresh) via [onAdd]/[onRemove], which rethrow so this panel can
/// surface a friendly message — notably the non-admin 403.
class _WatchlistPanel extends StatefulWidget {
  const _WatchlistPanel({
    required this.entries,
    required this.loading,
    required this.error,
    required this.canManage,
    required this.fuzz,
    required this.fuzzLoading,
    required this.onSaveFuzz,
    required this.onAdd,
    required this.onRemove,
    required this.onRefresh,
    required this.onClose,
  });

  final List<PlateWatchlistEntry> entries;
  final bool loading;
  final String? error;
  final bool canManage;

  /// Current watchlist fuzziness (0.0..0.5) from `GET /config/lpr`, or null
  /// when not an admin / not yet loaded — the control only renders when set.
  final double? fuzz;
  final bool fuzzLoading;

  /// Persist a new fuzziness (0.0..0.5). Rethrows so a 403 can surface inline.
  final Future<void> Function(double fuzz) onSaveFuzz;

  final Future<void> Function({
    required String plate,
    String? label,
    bool notify,
    String kind,
  }) onAdd;
  final Future<void> Function(PlateWatchlistEntry entry) onRemove;
  final VoidCallback onRefresh;
  final VoidCallback onClose;

  @override
  State<_WatchlistPanel> createState() => _WatchlistPanelState();
}

class _WatchlistPanelState extends State<_WatchlistPanel> {
  final TextEditingController _plateCtrl = TextEditingController();
  final TextEditingController _labelCtrl = TextEditingController();
  bool _notify = true;
  String _kind = 'watch'; // "watch" | "ignore"
  bool _saving = false;
  String? _addError;

  @override
  void initState() {
    super.initState();
    // Rebuild as the operator types so the fuzziness control can preview the
    // accepted misreads for the plate currently in the add field.
    _plateCtrl.addListener(_onPlateChanged);
  }

  void _onPlateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _plateCtrl.removeListener(_onPlateChanged);
    _plateCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final plate = _plateCtrl.text.trim();
    if (plate.isEmpty) {
      setState(() => _addError = 'Enter a plate.');
      return;
    }
    setState(() {
      _saving = true;
      _addError = null;
    });
    try {
      final label = _labelCtrl.text.trim();
      await widget.onAdd(
        plate: plate,
        label: label.isEmpty ? null : label,
        notify: _notify,
        kind: _kind,
      );
      if (!mounted) return;
      _plateCtrl.clear();
      _labelCtrl.clear();
      setState(() {
        _notify = true;
        _kind = 'watch';
        _saving = false;
      });
    } on CrumbApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _addError = e.statusCode == 403
            ? 'Only admins can manage the watchlist.'
            : e.message;
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _addError = 'Add failed: $e';
        _saving = false;
      });
    }
  }

  Future<void> _remove(PlateWatchlistEntry entry) async {
    try {
      await widget.onRemove(entry);
    } on CrumbApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.statusCode == 403
                ? 'Only admins can manage the watchlist.'
                : e.message,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Remove failed: $e')),
      );
    }
  }

  /// Edit an existing entry: reuse the shared chooser prefilled from the entry,
  /// then upsert via [onAdd] (keyed on the normalized plate).
  Future<void> _editEntry(PlateWatchlistEntry entry) async {
    final choice = await showWatchlistDialog(
      context,
      plate: entry.plate,
      title: 'Edit watchlist entry',
      initialKind: entry.isIgnore ? 'ignore' : 'watch',
      initialLabel: entry.label,
      initialNotify: entry.notify,
      fuzz: widget.fuzz,
      onSaveFuzz: widget.fuzz != null ? widget.onSaveFuzz : null,
    );
    if (choice == null || !mounted) return;
    try {
      await widget.onAdd(
        plate: entry.plate,
        kind: choice.kind,
        label: choice.label,
        notify: choice.notify,
      );
    } on CrumbApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.statusCode == 403
              ? 'Only admins can manage the watchlist.'
              : e.message),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      decoration: const BoxDecoration(
        color: Color(0xFF1E2026),
        border: Border(left: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context),
          const Divider(height: 1, color: Colors.white12),
          if (widget.canManage)
            _buildAddForm(context)
          else
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text(
                'Only admins can manage the watchlist.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          if (widget.canManage && widget.fuzz != null) ...[
            const Divider(height: 1, color: Colors.white12),
            _FuzzControl(
              fuzz: widget.fuzz!,
              plate: _plateCtrl.text,
              onSave: widget.onSaveFuzz,
            ),
          ] else if (widget.canManage && widget.fuzzLoading) ...[
            const Divider(height: 1, color: Colors.white12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Loading match fuzziness…',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
          const Divider(height: 1, color: Colors.white12),
          Expanded(child: _buildList(context)),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: Row(
        children: [
          const Icon(Icons.fact_check_outlined,
              size: 16, color: Colors.white70),
          const SizedBox(width: 8),
          const Text(
            'Watchlist',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${widget.entries.length}',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Refresh',
            onPressed: widget.onRefresh,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, color: Colors.white54, size: 16),
          ),
          IconButton(
            tooltip: 'Hide watchlist',
            onPressed: widget.onClose,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, color: Colors.white54, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildAddForm(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _KindSelector(
            value: _kind,
            onChanged: _saving ? null : (v) => setState(() => _kind = v),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _plateCtrl,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              letterSpacing: 1.2,
              fontFamily: 'monospace',
            ),
            textCapitalization: TextCapitalization.characters,
            onSubmitted: (_) {
              if (!_saving) _add();
            },
            decoration: _fieldDecoration('Plate'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _labelCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            onSubmitted: (_) {
              if (!_saving) _add();
            },
            decoration: _fieldDecoration('Label (optional)'),
          ),
          // Notifying only makes sense for a "watch" — an "ignore" drops the
          // read before it could alert, so the switch is disabled there.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _kind == 'ignore' ? false : _notify,
            onChanged: (_saving || _kind == 'ignore')
                ? null
                : (v) => setState(() => _notify = v),
            title: Text(
              _kind == 'ignore' ? 'Drops matching reads' : 'Notify on sighting',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          if (_addError != null) ...[
            const SizedBox(height: 2),
            Text(
              _addError!,
              style: const TextStyle(color: Color(0xFFD65C5C), fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _saving ? null : _add,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add, size: 16),
              label: Text(_kind == 'ignore' ? 'Add to ignore' : 'Add to watch'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (widget.loading && widget.entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          "Couldn't load watchlist: ${widget.error}",
          style: const TextStyle(color: Colors.redAccent, fontSize: 12),
        ),
      );
    }
    if (widget.entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'No watched plates yet.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: widget.entries.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: Colors.white10),
      itemBuilder: (context, i) {
        final e = widget.entries[i];
        return _WatchlistTile(
          onEdit: () => _editEntry(e),
          entry: e,
          canManage: widget.canManage,
          onRemove: () => _remove(e),
        );
      },
    );
  }

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF2A2D35),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide.none,
        ),
      );
}

/// Watch/Ignore toggle for the add form. "Watch" alerts on a sighting;
/// "Ignore" tells the server to drop matching reads.
class _KindSelector extends StatelessWidget {
  const _KindSelector({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    Widget seg(String v, IconData icon, String label, Color activeColor) {
      final active = value == v;
      return Expanded(
        child: GestureDetector(
          onTap: onChanged == null ? null : () => onChanged!(v),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: active
                  ? activeColor.withValues(alpha: 0.18)
                  : const Color(0xFF2A2D35),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: active ? activeColor : Colors.transparent,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: active ? activeColor : Colors.white54,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: active ? activeColor : Colors.white54,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        seg('watch', Icons.notifications_active, 'Watch',
            const Color(0xFF57C888)),
        const SizedBox(width: 6),
        seg('ignore', Icons.block, 'Ignore', const Color(0xFFE8A33D)),
      ],
    );
  }
}

/// Admin-only "Match fuzziness" slider (0–50%, mapped to `watchlist_fuzz`
/// 0.0–0.5). Debounces the PUT until the operator settles on a value; a 403
/// (stale admin flag) surfaces inline. Tolerates OCR misreads for both watch
/// and ignore matching.
// ─── fuzzy-match model (mirrors the server's watchlist/ignore matching) ──────
// The backend matches a read against a watch/ignore plate by *character
// tolerance*: normalize both (uppercase, keep only A–Z0–9), and accept when the
// edit distance is within `floor(fuzz * plateLength)`. These helpers reproduce
// that rule exactly so the slider can preview which misreads it would accept.

/// Uppercase and keep only alphanumerics (drops spaces, dashes, punctuation).
String _normalizePlate(String s) {
  final b = StringBuffer();
  for (final r in s.toUpperCase().runes) {
    final c = String.fromCharCode(r);
    if (RegExp(r'[A-Z0-9]').hasMatch(c)) b.write(c);
  }
  return b.toString();
}

/// Allowed character edits for a reference plate at [fuzz] (0..0.5).
int _allowedEdits(String reference, double fuzz) =>
    (fuzz.clamp(0.0, 0.5) * _normalizePlate(reference).length).floor();

/// Classic Levenshtein edit distance over characters.
int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 0; i < a.length; i++) {
    cur[0] = i + 1;
    for (var j = 0; j < b.length; j++) {
      final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
      final del = prev[j + 1] + 1;
      final ins = cur[j] + 1;
      final sub = prev[j] + cost;
      cur[j + 1] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
    }
    final tmp = prev;
    prev = cur;
    cur = tmp;
  }
  return prev[b.length];
}

/// Common ALPR character confusions (the pairs Frigate's OCR most often swaps).
const Map<String, String> _ocrConfusions = {
  '0': 'O', 'O': '0', '1': 'I', 'I': '1', 'L': '1', '2': 'Z', 'Z': '2',
  '5': 'S', 'S': '5', '8': 'B', 'B': '8', '6': 'G', 'G': '6', '4': 'A',
  'A': '4', 'D': '0', 'Q': 'O', '7': 'T',
};

/// A few realistic misreads of [plate] that the server WOULD accept at the
/// given [allowed] tolerance — one/two OCR-confusion substitutions, verified by
/// the same edit-distance rule the server uses. Returns [] when tolerance is 0
/// (exact only) or the plate is empty.
List<String> _acceptedMisreadExamples(String plate, int allowed) {
  final norm = _normalizePlate(plate);
  if (norm.isEmpty || allowed <= 0) return const [];
  final out = <String>[];
  // Distance-1 variants first: swap one confusable character.
  for (var i = 0; i < norm.length && out.length < 4; i++) {
    final rep = _ocrConfusions[norm[i]];
    if (rep == null) continue;
    final cand = norm.substring(0, i) + rep + norm.substring(i + 1);
    if (cand != norm &&
        !out.contains(cand) &&
        _levenshtein(cand, norm) <= allowed) {
      out.add(cand);
    }
  }
  // If two edits are allowed, add a couple of double-swaps to show the range.
  if (allowed >= 2) {
    for (var i = 0; i < norm.length && out.length < 4; i++) {
      final r1 = _ocrConfusions[norm[i]];
      if (r1 == null) continue;
      for (var j = i + 1; j < norm.length && out.length < 4; j++) {
        final r2 = _ocrConfusions[norm[j]];
        if (r2 == null) continue;
        final cand = norm.substring(0, i) +
            r1 +
            norm.substring(i + 1, j) +
            r2 +
            norm.substring(j + 1);
        if (cand != norm &&
            !out.contains(cand) &&
            _levenshtein(cand, norm) <= allowed) {
          out.add(cand);
        }
      }
    }
  }
  return out;
}

class _FuzzControl extends StatefulWidget {
  const _FuzzControl({
    required this.fuzz,
    required this.plate,
    required this.onSave,
  });
  final double fuzz;

  /// The plate currently typed into the add form (may be empty). Drives the
  /// live "accepted misreads" preview so the slider means something concrete.
  final String plate;
  final Future<void> Function(double fuzz) onSave;

  @override
  State<_FuzzControl> createState() => _FuzzControlState();
}

class _FuzzControlState extends State<_FuzzControl> {
  late double _value = widget.fuzz.clamp(0.0, 0.5);
  bool _saving = false;
  String? _error;

  /// The plate to illustrate with — the typed plate, or a sample when empty.
  String get _sampleBasis {
    final n = _normalizePlate(widget.plate);
    return n.isEmpty ? '7ABC123' : n;
  }

  bool get _usingSample => _normalizePlate(widget.plate).isEmpty;

  @override
  void didUpdateWidget(_FuzzControl old) {
    super.didUpdateWidget(old);
    // Adopt a server-confirmed value when it changes and we're not mid-drag.
    if (!_saving && widget.fuzz != old.fuzz) {
      _value = widget.fuzz.clamp(0.0, 0.5);
    }
  }

  Future<void> _commit(double v) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(v);
      if (mounted) setState(() => _saving = false);
    } on CrumbApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.statusCode == 403
            ? 'Only admins can change fuzziness.'
            : e.message;
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Save failed: $e';
        _saving = false;
      });
    }
  }

  /// A pill showing an accepted misread [cand], with the character(s) that
  /// differ from [basis] highlighted in the accent colour.
  Widget _misreadChip(String basis, String cand, Color accent) {
    final spans = <TextSpan>[
      for (var i = 0; i < cand.length; i++)
        TextSpan(
          text: cand[i],
          style: TextStyle(
            color: (i >= basis.length || cand[i] != basis[i])
                ? accent
                : Colors.white70,
            fontWeight: (i >= basis.length || cand[i] != basis[i])
                ? FontWeight.w800
                : FontWeight.w500,
          ),
        ),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white12),
      ),
      child: Text.rich(
        TextSpan(children: spans),
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          letterSpacing: 1,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pct = (_value * 100).round();
    final basis = _sampleBasis;
    final allowed = _allowedEdits(basis, _value);
    final examples = _acceptedMisreadExamples(basis, allowed);
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'Match fuzziness',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (_saving)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Text(
                  allowed == 0
                      ? 'Exact'
                      : '$pct%  ·  up to $allowed char${allowed == 1 ? '' : 's'}',
                  style: TextStyle(
                    color: allowed == 0 ? Colors.white70 : accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: _value,
              max: 0.5,
              divisions: 50,
              label: '$pct%',
              onChanged: _saving
                  ? null
                  : (v) => setState(() => _value = v),
              onChangeEnd: (v) => _commit(v),
            ),
          ),
          if (allowed == 0)
            const Text(
              'Exact match only. A single misread character will not match.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            )
          else ...[
            Text(
              _usingSample
                  ? 'Tolerates up to $allowed misread character${allowed == 1 ? '' : 's'}. Example on a 7-char plate — type a plate above to preview yours:'
                  : 'Tolerates up to $allowed misread character${allowed == 1 ? '' : 's'} on this plate. Would still match:',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            if (examples.isNotEmpty) ...[
              const SizedBox(height: 7),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final ex in examples) _misreadChip(basis, ex, accent),
                ],
              ),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(
              _error!,
              style: const TextStyle(color: Color(0xFFD65C5C), fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

/// One watchlist entry: optional color swatch, plate (mono), label subtitle, a
/// notify indicator, and (admin only) a Remove button.
/// Shared Watch/Ignore chooser — used both by the per-read quick-add (the star
/// on a plate row) and by editing an existing watchlist entry. Returns null on
/// cancel. `plate` is the normalized key, shown read-only. On confirm returns
/// the chosen kind ('watch'/'ignore'), optional label, and notify flag.
Future<({String kind, String? label, bool notify})?> showWatchlistDialog(
  BuildContext context, {
  required String plate,
  required String title,
  String initialKind = 'watch',
  String? initialLabel,
  bool initialNotify = true,
  double? fuzz,
  Future<void> Function(double fuzz)? onSaveFuzz,
}) {
  return showDialog<({String kind, String? label, bool notify})>(
    context: context,
    builder: (context) {
      var kind = initialKind;
      var notify = initialNotify;
      final labelCtrl = TextEditingController(text: initialLabel ?? '');
      return StatefulBuilder(
        builder: (context, setLocal) {
          final isIgnore = kind == 'ignore';
          Widget kindChip(String k, String label, IconData icon, Color c) {
            final active = kind == k;
            return Expanded(
              child: InkWell(
                onTap: () => setLocal(() => kind = k),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: active ? c.withValues(alpha: 0.22) : const Color(0xFF2A2D35),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: active ? c : Colors.white12, width: 1),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 15, color: active ? c : Colors.white54),
                      const SizedBox(width: 6),
                      Text(label,
                          style: TextStyle(
                              color: active ? Colors.white : Colors.white54,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            );
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF23262E),
            title: Text(title,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            content: SizedBox(
              width: 340,
              child: SingleChildScrollView(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(plate.isEmpty ? '—' : plate,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                          fontFamily: 'monospace',
                          fontSize: 18)),
                  const SizedBox(height: 14),
                  Row(children: [
                    kindChip('watch', 'Watch', Icons.notifications_active,
                        const Color(0xFF57C888)),
                    const SizedBox(width: 8),
                    kindChip('ignore', 'Ignore', Icons.block,
                        const Color(0xFFE8A33D)),
                  ]),
                  const SizedBox(height: 14),
                  TextField(
                    controller: labelCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: const InputDecoration(
                      labelText: 'Label (optional)',
                      labelStyle: TextStyle(color: Colors.white38),
                      isDense: true,
                      enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24)),
                      focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.white54)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Switch(
                      value: isIgnore ? false : notify,
                      onChanged:
                          isIgnore ? null : (v) => setLocal(() => notify = v),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        isIgnore
                            ? 'Ignore — drops matching reads'
                            : 'Notify on sighting',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                    ),
                  ]),
                  // Global watchlist fuzziness, with a live preview of the
                  // misreads it would accept for THIS plate. Admin-only; hidden
                  // when the LPR config isn't available.
                  if (fuzz != null && onSaveFuzz != null) ...[
                    const Divider(height: 22, color: Colors.white12),
                    _FuzzControl(
                      fuzz: fuzz,
                      plate: plate,
                      onSave: onSaveFuzz,
                    ),
                  ],
                ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final l = labelCtrl.text.trim();
                  Navigator.pop(
                    context,
                    (kind: kind, label: l.isEmpty ? null : l, notify: notify),
                  );
                },
                child: Text(isIgnore ? 'Ignore' : 'Watch'),
              ),
            ],
          );
        },
      );
    },
  );
}

class _WatchlistTile extends StatelessWidget {
  const _WatchlistTile({
    required this.entry,
    required this.canManage,
    required this.onEdit,
    required this.onRemove,
  });

  final PlateWatchlistEntry entry;
  final bool canManage;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final swatch = _parseHexColor(entry.color);
    final isIgnore = entry.isIgnore;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: Row(
        children: [
          if (swatch != null) ...[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: swatch,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white24),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.plate.isEmpty ? '—' : entry.plate,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    if (isIgnore) ...[
                      const SizedBox(width: 6),
                      const _KindBadge(),
                    ],
                  ],
                ),
                if (entry.label != null && entry.label!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    entry.label!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          // Notify state is only meaningful for a "watch"; an "ignore" carries
          // the badge above instead.
          if (!isIgnore)
            Icon(
              entry.notify
                  ? Icons.notifications_active
                  : Icons.notifications_off_outlined,
              size: 15,
              color: entry.notify ? const Color(0xFF57C888) : Colors.white24,
            ),
          if (canManage) ...[
            IconButton(
              tooltip: 'Edit',
              onPressed: onEdit,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined,
                  size: 15, color: Colors.white38),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: onRemove,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline,
                  size: 16, color: Colors.white38),
            ),
          ],
        ],
      ),
    );
  }
}

/// Small "IGNORE" pill shown on ignore-kind watchlist rows.
class _KindBadge extends StatelessWidget {
  const _KindBadge();

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFFE8A33D);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.block, size: 10, color: color),
          SizedBox(width: 3),
          Text(
            'IGNORE',
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Parse a `"#rrggbb"` (or `"#aarrggbb"`) hex string into a [Color], or null
/// if absent/malformed — the watchlist color is an optional annotation.
Color? _parseHexColor(String? hex) {
  if (hex == null) return null;
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}

// ─── shared thumbnail plumbing ─────────────────────────────────────────────

/// Process-wide snapshot byte cache, keyed by event id. These are FULL-RES
/// JPEGs — the report path (`_fetchSnapshotBytes`) crops them to the plate
/// bbox, so the raw bytes must be kept at native resolution here (the
/// thumbnails downscale at decode time via `cacheWidth`, not by shrinking the
/// cache). A single snapshot can be hundreds of KB, so the cache is bounded by
/// BYTES rather than a fixed entry COUNT — a count budget of a few hundred
/// full-frame JPEGs could balloon to well over 100 MB.
final Map<String, Uint8List> _snapshotCache = {};
final List<String> _snapshotCacheOrder = []; // LRU-ish, oldest first
const _snapshotCacheMaxBytes = 48 * 1024 * 1024; // 48 MiB
int _snapshotCacheBytes = 0;

void _cacheSnapshot(String id, Uint8List bytes) {
  final existing = _snapshotCache[id];
  if (existing != null) {
    _snapshotCacheBytes -= existing.lengthInBytes;
    _snapshotCacheOrder.remove(id);
  }
  _snapshotCache[id] = bytes;
  _snapshotCacheOrder.add(id);
  _snapshotCacheBytes += bytes.lengthInBytes;
  // Evict oldest until under budget, but always keep the entry we just cached
  // (an outsized single frame stays rather than being evicted immediately).
  while (_snapshotCacheBytes > _snapshotCacheMaxBytes &&
      _snapshotCacheOrder.length > 1) {
    final evicted = _snapshotCacheOrder.removeAt(0);
    final removed = _snapshotCache.remove(evicted);
    if (removed != null) _snapshotCacheBytes -= removed.lengthInBytes;
  }
}

/// Fetch a detection-event snapshot JPEG (`GET /events/{event_id}/snapshot`,
/// Bearer-authed), returning cached bytes when present. Returns null on any
/// non-200 or error — callers fall back to a placeholder. Shared by the lazy
/// thumbnails and the PDF export so both hit the same bounded cache.
Future<Uint8List?> _fetchSnapshotBytes(Session s, String eventId) async {
  final cached = _snapshotCache[eventId];
  if (cached != null) return cached;
  final url = '${s.base}/events/${Uri.encodeComponent(eventId)}/snapshot';
  try {
    final resp = await sharedHttpClient.get(
      Uri.parse(url),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 200) return null;
    _cacheSnapshot(eventId, resp.bodyBytes);
    return resp.bodyBytes;
  } catch (_) {
    return null;
  }
}

/// Bounded-concurrency gate for snapshot loads (mirrors the Clips tab's cap).
/// `reset()` releases queued waiters on a fresh page load so a stale window's
/// loads don't linger.
class _ConcurrencyGate {
  _ConcurrencyGate(this.max);
  final int max;
  int _active = 0;
  // Bumped by [reset]. Each in-flight [run] captures the epoch it started in;
  // its `finally` only settles the counter/waiters when the epoch still
  // matches. Without this, a task that was already running when [reset] zeroed
  // `_active` would decrement past 0 on completion, leaving `_active` negative
  // — after which the gate admits far more than [max] at once (a snapshot-fetch
  // thundering herd on the next page load).
  int _epoch = 0;
  final List<Completer<void>> _waiters = [];

  void reset() {
    _epoch++;
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
    // Capture AFTER any wait: a waiter released by reset() belongs to the new
    // generation and is counted/settled against it.
    final epoch = _epoch;
    _active++;
    try {
      await task();
    } finally {
      // A reset() during this task already zeroed `_active` and released the
      // waiters for the old generation — don't double-count against it.
      if (epoch == _epoch) {
        _active--;
        if (_waiters.isNotEmpty) {
          final next = _waiters.removeAt(0);
          if (!next.isCompleted) next.complete();
        }
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

/// Short, human label for a plate read's `source_id` engine tag.
String _engineLabel(String source) {
  switch (source) {
    case 'crumb-alpr':
      return 'Crumb';
    case 'frigate':
      return 'Frigate';
    default:
      return source;
  }
}

/// The accent color for an engine's chip — Crumb green vs Frigate blue, distinct
/// from the amber disagreement marker.
Color _engineColor(String source) {
  switch (source) {
    case 'crumb-alpr':
      return const Color(0xFF3DA35D);
    case 'frigate':
      return const Color(0xFF4C82C3);
    default:
      return const Color(0xFF6B7280);
  }
}

/// A compact, color-coded chip naming the engine that produced a read.
Widget _engineChip(String source) {
  final c = _engineColor(source);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: c.withValues(alpha: 0.55)),
    ),
    child: Text(
      _engineLabel(source),
      style: TextStyle(
        color: c,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.3,
      ),
    ),
  );
}
