// Add/edit-clip dialog for the Export tab's batch builder. Pick a camera +
// time range, review the recording to confirm you're grabbing the right
// moment, then add/save the clip into the parent list.
//
// The preview is real playback of the recorded segments, through the same
// [GaplessSegmentPaneController] the Playback tab uses, driven here as a
// single pane: the playhead is slaved to mpv's real position (see that
// controller's file header), so the scrubber and the picture can't disagree.
// It replaced a filmstrip slideshow ported from the old Tauri client, which
// stepped ~24 still frames across the range every 700 ms (one frame every
// ~4 s of footage on a 1.5 min clip) and had no transport controls.
//
// Controls: play/pause, frame step, skip 10 s, speed, and Set start/end here
// to trim at the playhead. Below the video, a trim timeline
// ([ClipTrimTimeline]) shows the clip with some footage either side: drag the
// selection handles to adjust it, drag anywhere else to scrub, wheel to zoom.
// Keyboard: Space play/pause, Left/Right frame step, Shift+Left/Right 10 s.
//
// Scrubbing is the Playback tab's technique (playback_screen.dart _liveSeek):
// inside the loaded segment, a cheap in-file seek, so the video itself tracks
// the drag; outside it, a server-extracted filmstrip frame (throttled, 4 s
// grid) over the video. Added here for trimming: when a drag rests outside
// the loaded segment, that segment is loaded so the exact frame shows.
//
// Times are shown in local time. The draft stores absolute instants (the
// playback screen hands in UTC values); export_api serializes with toUtc().

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/export_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/playback_api.dart';
import 'package:crumb_desktop/ui/export/clip_trim_timeline.dart';
import 'package:crumb_desktop/ui/playback/gapless_segment_pane.dart';
import 'package:crumb_desktop/ui/playback/gapless_segment_pane_controller.dart';

/// One clip in the batch builder's list (local-only until submit turns it
/// into a [BatchExportItem]).
class ExportClipDraft {
  ExportClipDraft({
    required this.id,
    required this.cameraId,
    required this.start,
    required this.end,
  });

  final int id; // local sequence number, stable across edits
  String cameraId;
  DateTime start;
  DateTime end;

  Duration get duration => end.difference(start);
}

/// Shows the add/edit-clip dialog. Returns the committed [ExportClipDraft], or
/// null if the user cancelled. `editing` pre-fills an existing draft (its `id`
/// is kept so the caller can find-and-replace it in the list).
Future<ExportClipDraft?> showExportClipBuilder(
  BuildContext context, {
  required CrumbApi api,
  required Session session,
  required List<Camera> cameras,
  ExportClipDraft? editing,
  String? preselectCameraId,
  DateTime? preselectStart,
  DateTime? preselectEnd,
  required int nextId,
}) {
  return showDialog<ExportClipDraft>(
    context: context,
    builder: (_) => _ExportBuilderDialog(
      api: api,
      session: session,
      cameras: cameras,
      editing: editing,
      preselectCameraId: preselectCameraId,
      preselectStart: preselectStart,
      preselectEnd: preselectEnd,
      nextId: nextId,
    ),
  );
}

/// `h:mm:ss` style length, e.g. `1m 42s`. Public for tests.
@visibleForTesting
String fmtClipDuration(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final parts = <String>[
    if (h > 0) '${h}h',
    if (m > 0) '${m}m',
    if (h == 0 && (sec > 0 || m == 0)) '${sec}s',
  ];
  return parts.isEmpty ? '0s' : parts.join(' ');
}

String _pad2(int n) => n.toString().padLeft(2, '0');

/// `YYYY-MM-DD HH:MM:SS` in LOCAL time, whatever zone [d] carries.
@visibleForTesting
String fmtClipDateTime(DateTime d) {
  final l = d.toLocal();
  return '${l.year}-${_pad2(l.month)}-${_pad2(l.day)} '
      '${_pad2(l.hour)}:${_pad2(l.minute)}:${_pad2(l.second)}';
}

String _fmtClock(DateTime d) {
  final l = d.toLocal();
  return '${_pad2(l.hour)}:${_pad2(l.minute)}:${_pad2(l.second)}';
}

const _speeds = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0];
const _skip = Duration(seconds: 10);

class _ExportBuilderDialog extends StatefulWidget {
  const _ExportBuilderDialog({
    required this.api,
    required this.session,
    required this.cameras,
    required this.editing,
    required this.preselectCameraId,
    required this.preselectStart,
    required this.preselectEnd,
    required this.nextId,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;
  final ExportClipDraft? editing;
  final String? preselectCameraId;
  final DateTime? preselectStart;
  final DateTime? preselectEnd;
  final int nextId;

  @override
  State<_ExportBuilderDialog> createState() => _ExportBuilderDialogState();
}

class _ExportBuilderDialogState extends State<_ExportBuilderDialog> {
  late String? _cameraId;
  late DateTime _start;
  late DateTime _end;
  String? _error;

  // ── preview playback ────────────────────────────────────────────────────
  GaplessSegmentPaneController? _pane;
  late DateTime _playhead;
  bool _playing = false;
  bool _scrubbing = false;
  bool _tickBusy = false;
  Timer? _tick;
  DateTime _lastTickWall = DateTime.now();
  int _speedIdx = _speeds.indexOf(1.0);
  final _focus = FocusNode(debugLabel: 'clip preview');

  // ── trim timeline ───────────────────────────────────────────────────────
  late DateTime _winStart;
  late DateTime _winEnd;
  List<(DateTime, DateTime)> _coverage = const [];
  Timer? _coverageDebounce;
  int _coverageToken = 0;

  // Scrub state (see the file header).
  Uint8List? _scrubFrame;
  int _scrubToken = 0;
  DateTime _lastScrubFetch = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _settle;
  DateTime? _scrubAt;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _cameraId =
        e?.cameraId ??
        widget.preselectCameraId ??
        (widget.cameras.isNotEmpty ? widget.cameras.first.id : null);
    _end = e?.end ?? widget.preselectEnd ?? DateTime.now();
    _start =
        e?.start ??
        widget.preselectStart ??
        _end.subtract(const Duration(minutes: 1));
    if (!_end.isAfter(_start)) _end = _start.add(const Duration(minutes: 1));
    _playhead = _start;
    _repad();
    _attachPane();
    _jumpTo(_start);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _settle?.cancel();
    _coverageDebounce?.cancel();
    _pane?.dispose();
    _focus.dispose();
    super.dispose();
  }

  Duration get _span => _end.difference(_start);

  /// The playhead may sit anywhere in the timeline window, including just
  /// outside the selection (to look for the right trim point).
  DateTime _clamp(DateTime t) =>
      t.isBefore(_winStart) ? _winStart : (t.isAfter(_winEnd) ? _winEnd : t);

  bool _inSelection(DateTime t) => !t.isBefore(_start) && t.isBefore(_end);

  /// Re-frame the timeline window around the selection: half the clip's
  /// length either side, at least 15 s and at most 30 min.
  void _repad() {
    final spanMs = _span.inMilliseconds;
    final padMs = (spanMs ~/ 2).clamp(15000, 30 * 60 * 1000);
    _winStart = _start.subtract(Duration(milliseconds: padMs));
    _winEnd = _end.add(Duration(milliseconds: padMs));
    _loadCoverageSoon();
  }

  void _loadCoverageSoon() {
    _coverageDebounce?.cancel();
    _coverageDebounce = Timer(const Duration(milliseconds: 250), _loadCoverage);
  }

  Future<void> _loadCoverage() async {
    final cam = _cameraId;
    if (cam == null) return;
    final token = ++_coverageToken;
    final spans = await widget.api.fetchTimeline(
      widget.session,
      [cam],
      _winStart,
      _winEnd,
    );
    if (!mounted || token != _coverageToken) return;
    setState(() {
      _coverage = [
        for (final sp in spans)
          if (sp.cameraId == cam) (sp.start, sp.end),
      ];
    });
  }

  // ── pane lifecycle ──────────────────────────────────────────────────────

  void _attachPane() {
    _pane?.dispose();
    final cam = _cameraId;
    _pane = cam == null
        ? null
        : (GaplessSegmentPaneController(
            api: widget.api,
            session: widget.session,
            cameraId: cam,
          )..rate = _speeds[_speedIdx]);
    final p = _pane?.player;
    if (p != null) unawaited(p.setRate(_speeds[_speedIdx]));
  }

  /// Explicit jump: move the playhead and (re)load the covering segment,
  /// keeping the current play/pause state.
  void _jumpTo(DateTime t) {
    if (!_end.isAfter(_start)) return;
    setState(() => _playhead = _clamp(t));
    unawaited(
      _pane?.resolveAt(_playhead, forceReload: true, playing: _playing),
    );
  }

  /// The clip's camera or range changed: stop and reload from its start.
  void _rangeChanged({bool cameraChanged = false}) {
    _pause();
    if (cameraChanged) _attachPane();
    _repad();
    _jumpTo(_start);
  }

  // ── transport ───────────────────────────────────────────────────────────

  void _togglePlay() => _playing ? _pause() : _play();

  void _play() {
    final pane = _pane;
    if (pane == null || !_end.isAfter(_start)) return;
    // Play covers the selection: from outside it, or at (or within a frame
    // of) its end, start over from the selection start.
    if (!_inSelection(_playhead) ||
        !_playhead.isBefore(_end.subtract(const Duration(milliseconds: 50)))) {
      _jumpTo(_start);
    }
    setState(() => _playing = true);
    unawaited(pane.player.play());
    _lastTickWall = DateTime.now();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 100), _onTick);
  }

  void _pause() {
    _tick?.cancel();
    _tick = null;
    unawaited(_pane?.player.pause());
    if (mounted && _playing) setState(() => _playing = false);
  }

  /// Same clock model as the Playback tab's single-pane mode: follow mpv's
  /// real position when it can be trusted, else advance by wall time × speed
  /// (a gap with no footage, or the moment a new file is opening).
  void _onTick(Timer _) {
    final pane = _pane;
    if (!_playing || pane == null) return;
    final wallNow = DateTime.now();
    final elapsedMs = wallNow.difference(_lastTickWall).inMilliseconds;
    _lastTickWall = wallNow;

    final mpv = _scrubbing ? null : pane.mpvPlayhead;
    var next =
        mpv ??
        _playhead.add(
          Duration(milliseconds: (elapsedMs * _speeds[_speedIdx]).round()),
        );
    if (!next.isBefore(_end)) {
      next = _end;
      setState(() => _playhead = next);
      _pause();
      return;
    }
    setState(() => _playhead = next);
    if (!_tickBusy) {
      _tickBusy = true;
      pane
          .onTick(next, playing: true, mpvDriven: true)
          .whenComplete(() => _tickBusy = false);
    }
  }

  Future<void> _frameStep(bool forward) async {
    final pane = _pane;
    if (pane == null) return;
    _pause();
    final t = await pane.frameStep(forward);
    if (t != null && mounted) setState(() => _playhead = _clamp(t));
  }

  void _skipBy(Duration d) => _jumpTo(_playhead.add(d));

  void _setSpeed(int idx) {
    setState(() => _speedIdx = idx);
    final pane = _pane;
    if (pane == null) return;
    pane.rate = _speeds[idx];
    unawaited(pane.player.setRate(_speeds[idx]));
  }

  // ── scrubbing (trim timeline drags) ─────────────────────────────────────

  void _onTrimDragStart(TrimTarget target) {
    _pause();
    _scrubbing = true;
    setState(() => _error = null);
  }

  void _onTrimDrag(TrimTarget target, DateTime t) {
    setState(() {
      switch (target) {
        case TrimTarget.start:
          _start = t;
        case TrimTarget.end:
          _end = t;
        case TrimTarget.playhead:
          break;
      }
      // Whatever is being dragged is what the preview shows.
      _playhead = t;
    });
    _liveSeek(t);
  }

  void _onTrimDragEnd(TrimTarget target, DateTime t) {
    _scrubbing = false;
    _settle?.cancel();
    _scrubToken++; // an in-flight frame fetch must not repaint the overlay
    setState(() => _scrubFrame = null);
    // A handle dragged near the window's edge: re-frame so it can go further.
    if (target != TrimTarget.playhead) {
      final edgeMs = _winEnd.difference(_winStart).inMilliseconds ~/ 20;
      if (_start.difference(_winStart).inMilliseconds < edgeMs ||
          _winEnd.difference(_end).inMilliseconds < edgeMs) {
        _repad();
      }
    }
    _jumpTo(t);
  }

  /// Show the frame at [t] during a drag, as fast as possible.
  void _liveSeek(DateTime t) {
    _scrubAt = t;
    final pane = _pane;
    if (pane == null) return;
    if (pane.currentSegment?.covers(t) ?? false) {
      // The loaded file has it: exact in-file seek, real video shows.
      unawaited(pane.seekWithinSegment(t));
      if (_scrubFrame != null) {
        _scrubToken++;
        setState(() => _scrubFrame = null);
      }
      return;
    }
    // Outside the loaded segment: a filmstrip frame now (throttled to about
    // 8 a second), and the real segment once the drag rests for a moment.
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 180), () async {
      final at = _scrubAt;
      if (!_scrubbing || at == null) return;
      await pane.resolveAt(at, forceReload: true, playing: false);
      // Re-evaluate against the newest drag position: clears the overlay if
      // the loaded segment now covers it.
      final now = _scrubAt;
      if (mounted && _scrubbing && now != null) _liveSeek(now);
    });
    final now = DateTime.now();
    if (now.difference(_lastScrubFetch) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastScrubFetch = now;
    unawaited(_fetchScrubFrame(t, ++_scrubToken));
  }

  Future<void> _fetchScrubFrame(DateTime t, int token) async {
    final cam = _cameraId;
    if (cam == null) return;
    final bytes = await widget.api.fetchFilmstripFrame(
      widget.session,
      cam,
      t,
      width: 640,
    );
    if (!mounted || token != _scrubToken || !_scrubbing || bytes == null) {
      return;
    }
    setState(() => _scrubFrame = bytes);
  }

  void _onZoom(DateTime start, DateTime end) {
    setState(() {
      _winStart = start;
      _winEnd = end;
    });
    _loadCoverageSoon();
  }

  // ── trim at the playhead ────────────────────────────────────────────────

  void _setStartHere() {
    if (!_playhead.isBefore(_end)) {
      setState(() => _error = 'Start must be before the end of the clip.');
      return;
    }
    setState(() {
      _start = _playhead;
      _error = null;
    });
  }

  void _setEndHere() {
    if (!_playhead.isAfter(_start)) {
      setState(() => _error = 'End must be after the start of the clip.');
      return;
    }
    setState(() {
      _end = _playhead;
      _error = null;
    });
  }

  // ── range editing ───────────────────────────────────────────────────────

  Future<void> _pickDateTime(bool isStart) async {
    final initial = (isStart ? _start : _end).toLocal();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 3650)),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      // Compact text-entry rather than the oversized full calendar.
      initialEntryMode: DatePickerEntryMode.input,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      initialEntryMode: TimePickerEntryMode.input,
    );
    if (time == null || !mounted) return;
    final combined = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
      initial.second,
    );
    setState(() {
      if (isStart) {
        _start = combined;
      } else {
        _end = combined;
      }
    });
    _rangeChanged();
  }

  void _commit() {
    setState(() => _error = null);
    final cam = _cameraId;
    if (cam == null) {
      setState(() => _error = 'Pick a camera for this clip.');
      return;
    }
    if (!_end.isAfter(_start)) {
      setState(() => _error = 'End must be after start.');
      return;
    }
    Navigator.of(context).pop(
      ExportClipDraft(
        id: widget.editing?.id ?? widget.nextId,
        cameraId: cam,
        start: _start,
        end: _end,
      ),
    );
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pane = _pane;
    return AlertDialog(
      title: Text(widget.editing != null ? 'Edit clip' : 'Add clip'),
      content: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): _togglePlay,
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _frameStep(false),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _frameStep(true),
          const SingleActivator(
            LogicalKeyboardKey.arrowLeft,
            shift: true,
          ): () =>
              _skipBy(-_skip),
          const SingleActivator(
            LogicalKeyboardKey.arrowRight,
            shift: true,
          ): () =>
              _skipBy(_skip),
        },
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          child: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _cameraId,
                    decoration: const InputDecoration(labelText: 'Camera'),
                    items: [
                      for (final c in widget.cameras)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) {
                      setState(() => _cameraId = v);
                      _rangeChanged(cameraChanged: true);
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _DateTimeField(
                          label: 'Start',
                          text: fmtClipDateTime(_start),
                          onTap: () => _pickDateTime(true),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _DateTimeField(
                          label: 'End',
                          text: fmtClipDateTime(_end),
                          onTap: () => _pickDateTime(false),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Duration: ${fmtClipDuration(_span)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  // Quick ranges ending "now" (old client's Last 1m/5m/10m/15m).
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final n in const [1, 5, 10, 15])
                        ActionChip(
                          label: Text('Last ${n}m'),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            final now = DateTime.now();
                            setState(() {
                              _end = now;
                              _start = now.subtract(Duration(minutes: n));
                            });
                            _rangeChanged();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // ── preview ────────────────────────────────────────────
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: pane == null
                        ? const ColoredBox(color: Colors.black)
                        : GestureDetector(
                            onTap: _togglePlay,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                GaplessSegmentPane(controller: pane),
                                // Scrub frame over the video while a drag is
                                // outside the loaded segment.
                                if (_scrubFrame != null)
                                  ColoredBox(
                                    color: Colors.black,
                                    child: Image.memory(
                                      _scrubFrame!,
                                      fit: BoxFit.contain,
                                      gaplessPlayback: true,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
                  const SizedBox(height: 8),
                  ClipTrimTimeline(
                    windowStart: _winStart,
                    windowEnd: _winEnd,
                    selectionStart: _start,
                    selectionEnd: _end,
                    playhead: _playhead,
                    coverage: _coverage,
                    onDragStart: _onTrimDragStart,
                    onDrag: _onTrimDrag,
                    onDragEnd: _onTrimDragEnd,
                    onZoom: _onZoom,
                  ),
                  Row(
                    children: [
                      Text(
                        _fmtClock(_winStart),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Drag the ends to trim · wheel to zoom',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _fmtClock(_winEnd),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                  _transportRow(theme),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: _setStartHere,
                        icon: const Icon(Icons.first_page, size: 18),
                        label: const Text('Set start here'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _setEndHere,
                        icon: const Icon(Icons.last_page, size: 18),
                        label: const Text('Set end here'),
                      ),
                      const Spacer(),
                      Flexible(
                        child: Text(
                          'Space play · ←/→ frame · Shift+←/→ 10 s',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.hintColor,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _commit,
          child: Text(widget.editing != null ? 'Save changes' : 'Add to list'),
        ),
      ],
    );
  }

  Widget _transportRow(ThemeData theme) {
    final offset = _playhead.difference(_start);
    return Row(
      children: [
        IconButton(
          tooltip: 'Back 10 s (Shift+←)',
          onPressed: () => _skipBy(-_skip),
          icon: const Icon(Icons.replay_10),
        ),
        IconButton(
          tooltip: 'Previous frame (←)',
          onPressed: () => _frameStep(false),
          icon: const Icon(Icons.skip_previous),
        ),
        IconButton.filled(
          tooltip: _playing ? 'Pause (Space)' : 'Play (Space)',
          onPressed: _togglePlay,
          icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
        ),
        IconButton(
          tooltip: 'Next frame (→)',
          onPressed: () => _frameStep(true),
          icon: const Icon(Icons.skip_next),
        ),
        IconButton(
          tooltip: 'Forward 10 s (Shift+→)',
          onPressed: () => _skipBy(_skip),
          icon: const Icon(Icons.forward_10),
        ),
        const SizedBox(width: 4),
        PopupMenuButton<int>(
          tooltip: 'Playback speed',
          initialValue: _speedIdx,
          onSelected: _setSpeed,
          itemBuilder: (_) => [
            for (var i = 0; i < _speeds.length; i++)
              PopupMenuItem(value: i, child: Text(_speedLabel(_speeds[i]))),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
              _speedLabel(_speeds[_speedIdx]),
              style: theme.textTheme.labelLarge,
            ),
          ),
        ),
        const Spacer(),
        Text(
          _fmtClock(_playhead),
          style: theme.textTheme.titleSmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          // Before the selection (looking for a trim point) reads negative.
          '${offset.isNegative ? '-' : ''}${fmtClipDuration(offset.abs())} / ${fmtClipDuration(_span)}',
          style: theme.textTheme.bodySmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  static String _speedLabel(double s) =>
      s == s.roundToDouble() ? '${s.toInt()}×' : '$s×';
}

class _DateTimeField extends StatelessWidget {
  const _DateTimeField({
    required this.label,
    required this.text,
    required this.onTap,
  });

  final String label;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text(text),
      ),
    );
  }
}
