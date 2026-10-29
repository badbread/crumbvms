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
// Controls: play/pause, frame step, skip 10 s, speed, a scrubber over the
// clip's range, and Set start/end here to trim the clip at the playhead.
// Keyboard: Space play/pause, Left/Right frame step, Shift+Left/Right 10 s.
//
// Times are shown in local time. The draft stores absolute instants (the
// playback screen hands in UTC values); export_api serializes with toUtc().

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
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
    _attachPane();
    _jumpTo(_start);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pane?.dispose();
    _focus.dispose();
    super.dispose();
  }

  Duration get _span => _end.difference(_start);

  double get _frac {
    final span = _span.inMilliseconds;
    if (span <= 0) return 0;
    return (_playhead.difference(_start).inMilliseconds / span).clamp(0.0, 1.0);
  }

  DateTime _clamp(DateTime t) =>
      t.isBefore(_start) ? _start : (t.isAfter(_end) ? _end : t);

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
    _jumpTo(_start);
  }

  // ── transport ───────────────────────────────────────────────────────────

  void _togglePlay() => _playing ? _pause() : _play();

  void _play() {
    final pane = _pane;
    if (pane == null || !_end.isAfter(_start)) return;
    // At (or within a frame of) the end: replay from the start.
    if (!_playhead.isBefore(_end.subtract(const Duration(milliseconds: 50)))) {
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

  DateTime _fracToTime(double f) =>
      _start.add(Duration(milliseconds: (f * _span.inMilliseconds).round()));

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
                            child: GaplessSegmentPane(controller: pane),
                          ),
                  ),
                  SliderTheme(
                    data: SliderTheme.of(
                      context,
                    ).copyWith(overlayShape: SliderComponentShape.noOverlay),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Slider(
                        value: _frac,
                        onChangeStart: (_) {
                          _scrubbing = true;
                          _pause();
                        },
                        onChanged: (v) {
                          final t = _fracToTime(v);
                          setState(() => _playhead = t);
                          // Cheap in-file seek while dragging; the release
                          // below loads another segment if needed.
                          unawaited(pane?.seekWithinSegment(t));
                        },
                        onChangeEnd: (v) {
                          _scrubbing = false;
                          _jumpTo(_fracToTime(v));
                        },
                      ),
                    ),
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
          '${fmtClipDuration(offset)} / ${fmtClipDuration(_span)}',
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
