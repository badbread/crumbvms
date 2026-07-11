// Add/edit-clip dialog for the Export tab's batch builder. Pick a camera +
// time range, scrub a filmstrip preview to confirm you're grabbing the right
// moment, then add/save the clip into the parent list.
//
// Ports apps/desktop/src/app.js exportOpenBuilder/exportBuilderCommit (list
// commit) + exportPreviewSeek/exportPreviewFetch/exportPreviewPlayToggle
// (scrubber). The old client re-fetched a frame ~110ms after the last drag
// tick and auto-advanced at <=~24 frames per play cycle to cap extractor
// load server-side; both limits are kept here.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/export_api.dart';
import 'package:crumb_desktop/api/models.dart';

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

  // ── preview scrubber state (mirrors exportState.builder in app.js) ───────
  double _frac = 0.0; // 0..1 position within [_start, _end]
  Uint8List? _frameBytes;
  String? _previewMsg = 'Loading preview…';
  int _reqToken = 0;
  Timer? _debounce;
  Timer? _playTimer;
  bool _playing = false;

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
        e?.start ?? widget.preselectStart ?? _end.subtract(const Duration(minutes: 1));
    if (!_end.isAfter(_start)) _end = _start.add(const Duration(minutes: 1));
    _seekTo(0);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _playTimer?.cancel();
    super.dispose();
  }

  Duration get _span => _end.difference(_start);

  void _seekTo(double frac) {
    if (_cameraId == null || !_end.isAfter(_start)) return;
    frac = frac.clamp(0.0, 1.0);
    final posMs =
        _start.millisecondsSinceEpoch +
        (frac * _span.inMilliseconds).round();
    setState(() => _frac = frac);
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 110),
      () => _fetchFrame(DateTime.fromMillisecondsSinceEpoch(posMs)),
    );
  }

  Future<void> _fetchFrame(DateTime ts) async {
    final cam = _cameraId;
    if (cam == null) return;
    final token = ++_reqToken;
    final bytes = await widget.api.fetchFilmstripFrame(
      widget.session,
      cam,
      ts,
      width: 480,
    );
    if (!mounted || token != _reqToken) return; // superseded by a newer scrub
    setState(() {
      if (bytes == null) {
        _frameBytes = null;
        _previewMsg = 'No footage at this moment';
      } else {
        _frameBytes = bytes;
        _previewMsg = null;
      }
    });
  }

  void _togglePlay() {
    if (_playing) {
      _stopPlay();
      return;
    }
    if (_cameraId == null || !_end.isAfter(_start)) return;
    setState(() => _playing = true);
    final spanMs = _span.inMilliseconds;
    // ~24 steps across the range, at least 1s apart — caps extractor load,
    // matching exportPreviewPlayToggle's stepMs in app.js (no upper bound: a
    // clip shorter than 24s just steps straight to the end next tick).
    final stepMs = ((spanMs / 24).round()).clamp(1000, 1 << 31).toInt();
    _playTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      final curMs =
          _start.millisecondsSinceEpoch + (_frac * spanMs).round();
      final nextMs = curMs + stepMs;
      final endMs = _end.millisecondsSinceEpoch;
      if (nextMs >= endMs) {
        _seekTo(1);
        _stopPlay();
        return;
      }
      _seekTo((nextMs - _start.millisecondsSinceEpoch) / spanMs);
    });
  }

  void _stopPlay() {
    _playTimer?.cancel();
    _playTimer = null;
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _pickDateTime(bool isStart) async {
    final initial = isStart ? _start : _end;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 3650)),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
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
    _stopPlay();
    _seekTo(0);
  }

  String _fmt(DateTime d) =>
      '${d.year}-${_2(d.month)}-${_2(d.day)} ${_2(d.hour)}:${_2(d.minute)}:${_2(d.second)}';
  String _2(int n) => n.toString().padLeft(2, '0');

  String _fmtDuration(Duration d) {
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.editing != null ? 'Edit clip' : 'Add clip'),
      content: SizedBox(
        width: 560,
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
                  _stopPlay();
                  _seekTo(0);
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _DateTimeField(
                      label: 'Start',
                      text: _fmt(_start),
                      onTap: () => _pickDateTime(true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DateTimeField(
                      label: 'End',
                      text: _fmt(_end),
                      onTap: () => _pickDateTime(false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Duration: ${_fmtDuration(_span)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              // ── preview scrubber ─────────────────────────────────────────
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: _frameBytes != null
                      ? Image.memory(_frameBytes!, fit: BoxFit.contain)
                      : Text(
                          _previewMsg ?? '',
                          style: const TextStyle(color: Colors.white54),
                        ),
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                    onPressed: _togglePlay,
                  ),
                  Expanded(
                    child: Slider(
                      value: _frac,
                      onChanged: (v) {
                        _stopPlay();
                        _seekTo(v);
                      },
                    ),
                  ),
                  SizedBox(
                    width: 90,
                    child: Text(
                      _fmtDuration(
                        Duration(
                          milliseconds:
                              (_frac * _span.inMilliseconds).round(),
                        ),
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
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
