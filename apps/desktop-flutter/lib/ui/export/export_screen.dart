// Export tab: batch clip export builder. A list of {camera, start, end}
// clips (add/edit/remove, each with a scrubbable filmstrip preview via the
// builder dialog), global output settings (burn-in timestamp, audio, video
// codec, container, optional AES-256 zip password), a destination folder,
// and submit -> progress -> download.
//
// Ports apps/desktop/src/app.js's export* functions (exportEnter,
// exportOpenBuilder/exportRenderList, exportEstSize, exportHandleSubmit,
// exportPoll, exportDownloadFiles) onto POST /export/batch + GET/DELETE
// /export/{job_id} (+GET .../files/{camera_id} | .../archive) — see
// services/api/src/export.rs and lib/api/export_api.dart.
//
// Playback hand-off: the Playback timeline's Shift+drag "Export selection"
// routes a bracketed range here via [ExportScreen.initialClip] (see
// PlaybackScreen.onExportRange + main.dart), mirroring the old client's
// exportOpenBuilder(null, cam, startMs, endMs).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/export_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/ui/folder_picker_dialog.dart';

import 'export_builder_dialog.dart';

class ExportScreen extends StatefulWidget {
  const ExportScreen({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    this.initialClips = const [],
    this.onListChanged,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;

  /// Pre-fill the batch on entry. The host (MainShell) owns this list so it
  /// ACCUMULATES across Playback "Add clip to export list" actions and survives
  /// leaving/returning to the Export tab (the tab body is rebuilt on switch).
  final List<ExportClipDraft> initialClips;

  /// Called whenever the batch changes (add/edit/remove) so the host can keep
  /// its persistent copy in sync — without this, edits made here would be lost
  /// the next time a clip is added from Playback and the tab is rebuilt.
  final ValueChanged<List<ExportClipDraft>>? onListChanged;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  final List<ExportClipDraft> _list = [];
  final Map<int, Widget> _thumbCache = {};
  int _seq = 0;

  // ── output settings (apply to the whole batch) ────────────────────────────
  bool _burnTimestamp = true;
  bool _includeAudio = true;
  String _videoCodec = 'copy'; // copy | h264 | h265
  String _container = 'mp4'; // mp4 | mkv
  final _passwordCtrl = TextEditingController();
  bool _obscurePassword = true;

  // ── destination folder (persisted across launches via [_kExportDirKey]) ──
  String? _destDir;
  final _destDirCtrl = TextEditingController();
  bool _pickingFolder = false; // never stack two native modal pickers

  // ── run state ──────────────────────────────────────────────────────────
  bool _submitting = false;
  bool _running = false;
  bool _completed = false;
  String? _jobId;
  int _progressPct = 0;
  ExportJobStatus? _status;
  String? _error;
  Timer? _pollTimer;
  DateTime? _earliestStart;

  static const _kExportDirKey = 'crumb.export.dir';

  @override
  void initState() {
    super.initState();
    if (widget.initialClips.isNotEmpty) {
      _list.addAll(widget.initialClips);
      // Keep new ids above every seeded one so add/edit never collide.
      _seq = widget.initialClips.map((c) => c.id).reduce((a, b) => a > b ? a : b);
    }
    _restoreDestDir();
  }

  /// Push the current batch up to the host so it survives a tab rebuild.
  void _notifyChanged() => widget.onListChanged?.call(List.of(_list));

  Future<void> _restoreDestDir() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dir = prefs.getString(_kExportDirKey);
      if (dir != null && dir.isNotEmpty && mounted) {
        setState(() {
          _destDir = dir;
          _destDirCtrl.text = dir;
        });
      }
    } catch (_) {
      /* prefs unavailable */
    }
  }

  Future<void> _persistDestDir(String dir) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kExportDirKey, dir);
    } catch (_) {
      /* best-effort */
    }
  }

  Future<void> _openDestFolder() async {
    final dir = _destDir;
    if (dir == null) return;
    try {
      await launchUrl(Uri.file(dir));
    } catch (_) {
      /* best-effort */
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _passwordCtrl.dispose();
    _destDirCtrl.dispose();
    super.dispose();
  }

  String _cameraName(String id) {
    for (final c in widget.cameras) {
      if (c.id == id) return c.name;
    }
    return id;
  }

  // ── list management ───────────────────────────────────────────────────────

  Future<void> _addClip() async {
    final result = await showExportClipBuilder(
      context,
      api: widget.api,
      session: widget.session,
      cameras: widget.cameras,
      nextId: ++_seq,
    );
    if (result == null) {
      _seq--; // unused id, keep the sequence tight
      return;
    }
    setState(() {
      _list.add(result);
      _thumbCache.remove(result.id);
      _clearCompletedState();
    });
    _notifyChanged();
  }

  Future<void> _editClip(ExportClipDraft draft) async {
    final result = await showExportClipBuilder(
      context,
      api: widget.api,
      session: widget.session,
      cameras: widget.cameras,
      editing: draft,
      nextId: _seq + 1,
    );
    if (result == null) return;
    setState(() {
      final i = _list.indexWhere((d) => d.id == draft.id);
      if (i >= 0) _list[i] = result;
      _thumbCache.remove(draft.id);
      _clearCompletedState();
    });
    _notifyChanged();
  }

  void _removeClip(ExportClipDraft draft) {
    setState(() {
      _list.removeWhere((d) => d.id == draft.id);
      _thumbCache.remove(draft.id);
      _clearCompletedState();
    });
    _notifyChanged();
  }

  /// Any list/settings edit after a completed export reverts the button back
  /// to a normal "Export N clips" (mirrors exportUpdateSummary's stuck-Done
  /// fix in app.js).
  void _clearCompletedState() {
    if (_completed) {
      _completed = false;
      _error = null;
    }
  }

  // ── summary line ───────────────────────────────────────────────────────────

  Duration get _totalDuration =>
      _list.fold(Duration.zero, (sum, it) => sum + it.duration);

  int get _distinctCameras => _list.map((it) => it.cameraId).toSet().length;

  /// Relative output size per codec: copy passes the source bitrate through;
  /// H.264/H.265 re-encode to a lower target, H.265 the smallest.
  double get _codecSizeFactor => switch (_videoCodec) {
    'h265' => 0.4,
    'h264' => 0.6,
    _ => 1.0, // copy
  };

  /// Rough processing-time multiplier per codec, relative to footage length:
  /// copy just remuxes (near-instant, IO-bound); H.264 re-encodes; H.265 is the
  /// slowest. Very approximate — hardware-dependent — hence the "~".
  double get _codecTimeFactor => switch (_videoCodec) {
    'h265' => 0.9,
    'h264' => 0.4,
    _ => 0.05, // copy / remux
  };

  /// Rough size estimate (heuristic ~4 Mbps main stream), scaled by codec.
  /// Always prefixed with "~".
  String _estSize() {
    final ms = _totalDuration.inMilliseconds;
    final bytes = (ms / 1000) * 500000 * _codecSizeFactor; // 4 Mbps ~= 500 KB/s
    if (bytes >= 1e9) return '~${(bytes / 1e9).toStringAsFixed(1)} GB';
    if (bytes >= 1e6) return '~${(bytes / 1e6).round()} MB';
    return '~${(bytes / 1e3).clamp(1, double.infinity).round()} KB';
  }

  /// Rough processing-time estimate, scaled by codec (copy is fastest). "~".
  String _estTime() {
    final secs = (_totalDuration.inSeconds * _codecTimeFactor).round();
    return '~${_fmtDuration(Duration(seconds: secs.clamp(1, 1 << 30)))}';
  }

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

  String _fmtClock(DateTime d) {
    final l = d.toLocal();
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${p2(l.month)}/${p2(l.day)} ${p2(l.hour)}:${p2(l.minute)}:${p2(l.second)}';
  }

  // ── destination folder ──────────────────────────────────────────────────

  Future<void> _pickFolder() async {
    // Re-entry guard: don't stack two pickers from a double-click.
    if (_pickingFolder) return;
    _pickingFolder = true;

    // Use the IN-APP folder picker, not the native OS dialog. On Windows the
    // Win32 folder dialog (file_selector getDirectoryPath) runs its modal
    // message loop on the Flutter platform thread and hard-hangs the whole app
    // ("Not Responding") with no dialog ever shown — a platform-thread
    // deadlock, not a z-order/fullscreen issue, so dropping fullscreen +
    // foregrounding didn't help (#87). The in-app picker browses directories
    // with dart:io from the Dart isolate and cannot block the platform thread.
    try {
      final dir = await pickFolderInApp(context, initialPath: _destDir);
      if (dir != null && mounted) {
        setState(() {
          _destDir = dir;
          _destDirCtrl.text = dir;
        });
        await _persistDestDir(dir);
      }
    } finally {
      _pickingFolder = false;
    }
  }

  /// Manual fallback for the native picker: a typed/pasted path in the
  /// Destination field always works, even if the OS dialog misbehaves.
  /// Persisted on submit (once validated), not per keystroke.
  void _setDestDirFromText(String value) {
    final dir = value.trim();
    setState(() => _destDir = dir.isEmpty ? null : dir);
  }

  // ── submit / poll / download ──────────────────────────────────────────────

  Future<void> _submit() async {
    if (_completed) {
      // "Done" state -> treat the button as a reset instead of a re-submit.
      setState(() {
        _completed = false;
        _error = null;
        _status = null;
        _progressPct = 0;
      });
      return;
    }

    final items = _list
        .where((it) => it.end.isAfter(it.start))
        .toList(growable: false);
    if (items.isEmpty) {
      setState(
        () => _error = 'Add at least one clip to the list before exporting.',
      );
      return;
    }

    if (_destDir == null) {
      await _pickFolder();
      if (_destDir == null) return; // user cancelled the folder picker
    }

    // A typed/pasted destination may not exist — fail here with a clear
    // message instead of at download time.
    final destDir = _destDir!;
    if (!Directory(destDir).existsSync()) {
      setState(() => _error = 'Destination folder does not exist: $destDir');
      return;
    }
    unawaited(_persistDestDir(destDir)); // typed paths persist once used

    setState(() {
      _error = null;
      _submitting = true;
      _progressPct = 0;
      _status = null;
    });

    _earliestStart = items
        .map((it) => it.start)
        .reduce((a, b) => a.isBefore(b) ? a : b);

    try {
      final result = await widget.api.submitBatchExport(
        widget.session,
        items: [
          for (final it in items)
            BatchExportItem(
              cameraId: it.cameraId,
              start: it.start,
              end: it.end,
            ),
        ],
        burnTimestamp: _burnTimestamp,
        includeAudio: _includeAudio,
        videoCodec: _videoCodec,
        container: _container,
        password: _passwordCtrl.text,
      );
      if (!mounted) return;
      setState(() {
        _jobId = result.jobId;
        _submitting = false;
        _running = true;
      });
      _poll();
    } on CrumbApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Export request failed: $e';
      });
    }
  }

  void _poll() {
    _pollTimer?.cancel();
    _pollTimer = Timer(const Duration(milliseconds: 1500), () async {
      if (!_running || _jobId == null || !mounted) return;
      ExportJob job;
      try {
        job = await widget.api.getExportStatus(widget.session, _jobId!);
      } catch (e) {
        if (!mounted || !_running) return;
        setState(() {
          _running = false;
          _error = 'Poll failed: $e';
        });
        return;
      }
      if (!mounted || !_running) return;
      setState(() {
        _progressPct = job.progressPct.clamp(0, 100).toInt();
        _status = job.status;
      });

      switch (job.status) {
        case ExportJobStatus.done:
          setState(() => _running = false);
          await _downloadAll(job.outputFiles);
          return;
        case ExportJobStatus.failed:
          setState(() {
            _running = false;
            _error = job.error ?? 'Export job failed (no details provided).';
          });
          return;
        case ExportJobStatus.cancelled:
          setState(() {
            _running = false;
            _error = 'Export cancelled.';
          });
          return;
        case ExportJobStatus.queued:
        case ExportJobStatus.running:
          _poll();
      }
    });
  }

  Future<void> _cancel() async {
    final jobId = _jobId;
    if (jobId == null) return;
    _pollTimer?.cancel();
    setState(() => _running = false);
    try {
      await widget.api.cancelExport(widget.session, jobId);
    } catch (_) {
      /* best-effort */
    }
  }

  String _friendlyFilename(ExportOutputFile file) {
    final start = _earliestStart ?? DateTime.now();
    final l = start.toLocal();
    String p2(int n) => n.toString().padLeft(2, '0');
    final stamp = '${l.year}${p2(l.month)}${p2(l.day)}-${p2(l.hour)}${p2(l.minute)}';
    if (file.isArchive) return 'crumb-export-$stamp.zip';
    final ext = RegExp(
          r'\.([a-z0-9]+)$',
          caseSensitive: false,
        ).firstMatch(file.filename)?.group(1)?.toLowerCase() ??
        'mp4';
    var name = _cameraName(file.cameraId).replaceAll(
      RegExp(r'[^a-zA-Z0-9_-]'),
      '_',
    );
    if (name.length > 40) name = name.substring(0, 40);
    return 'crumb-$name-$stamp.$ext';
  }

  Future<void> _downloadAll(List<ExportOutputFile> files) async {
    if (files.isEmpty) {
      setState(() {
        _completed = true;
        _error = null;
      });
      return;
    }
    final destDir = _destDir;
    if (destDir == null) {
      setState(() => _error = 'No destination folder selected.');
      return;
    }
    String? failure;
    for (final file in files) {
      try {
        final bytes = await widget.api.downloadExportFile(
          widget.session,
          file,
        );
        final path = '$destDir${Platform.pathSeparator}${_friendlyFilename(file)}';
        await File(path).writeAsBytes(bytes);
      } catch (e) {
        failure = 'Download failed for ${file.filename}: $e';
      }
    }
    if (!mounted) return;
    setState(() {
      _completed = true;
      _error = failure;
    });
  }

  // ── build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Export')),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── left: clip list ─────────────────────────────────────────────
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Text(
                        'Clips (${_list.length})',
                        style: theme.textTheme.titleMedium,
                      ),
                      const Spacer(),
                      FilledButton.tonalIcon(
                        onPressed: _addClip,
                        icon: const Icon(Icons.add),
                        label: const Text('Add clip'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _list.isEmpty
                      ? const Center(
                          child: Text(
                            'No clips yet.\nAdd a camera + time range to build your export.',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          itemCount: _list.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final it = _list[i];
                            return _ClipRow(
                              index: i + 1,
                              draft: it,
                              cameraName: _cameraName(it.cameraId),
                              thumbnail: _thumbFor(it),
                              rangeLabel:
                                  '${_fmtClock(it.start)} -> ${_fmtClock(it.end)}',
                              durationLabel: _fmtDuration(it.duration),
                              onEdit: () => _editClip(it),
                              onRemove: () => _removeClip(it),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          // ── right: output settings + submit + progress ─────────────────
          SizedBox(
            width: 360,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Batch summary', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  _summaryRow('Clips', '${_list.length}'),
                  _summaryRow('Cameras', '$_distinctCameras'),
                  _summaryRow(
                    'Duration',
                    _list.isEmpty ? '-' : _fmtDuration(_totalDuration),
                  ),
                  _summaryRow('Est. size', _list.isEmpty ? '-' : _estSize()),
                  _summaryRow(
                    'Est. process time',
                    _list.isEmpty ? '-' : _estTime(),
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text('Output settings', style: theme.textTheme.titleSmall),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Burn in timestamp'),
                    value: _burnTimestamp,
                    onChanged: (v) => setState(() {
                      _burnTimestamp = v;
                      _clearCompletedState();
                    }),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Include audio'),
                    value: _includeAudio,
                    onChanged: (v) => setState(() {
                      _includeAudio = v;
                      _clearCompletedState();
                    }),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _videoCodec,
                    decoration: const InputDecoration(
                      labelText: 'Video codec',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'copy',
                        child: Text('Copy (fastest, no re-encode)'),
                      ),
                      DropdownMenuItem(value: 'h264', child: Text('H.264')),
                      DropdownMenuItem(
                        value: 'h265',
                        child: Text('H.265 (smaller, slower)'),
                      ),
                    ],
                    onChanged: (v) => setState(() {
                      _videoCodec = v ?? 'copy';
                      _clearCompletedState();
                    }),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _container,
                    decoration: const InputDecoration(labelText: 'Container'),
                    items: const [
                      DropdownMenuItem(value: 'mp4', child: Text('MP4')),
                      DropdownMenuItem(value: 'mkv', child: Text('MKV')),
                    ],
                    onChanged: (v) => setState(() {
                      _container = v ?? 'mp4';
                      _clearCompletedState();
                    }),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _passwordCtrl,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Zip password (optional)',
                      helperText: 'AES-256 encrypted zip when set',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                    ),
                    onChanged: (_) => _clearCompletedState(),
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text('Destination', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        // Editable so a path can be typed/pasted directly —
                        // the reliable fallback if the native Browse… dialog
                        // ever fails to appear.
                        child: TextField(
                          controller: _destDirCtrl,
                          style: theme.textTheme.bodySmall,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '(choose a folder or type a path)',
                          ),
                          onChanged: _setDestDirFromText,
                        ),
                      ),
                      TextButton(
                        onPressed: _pickFolder,
                        child: const Text('Browse…'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_submitting || _running || _status != null) ...[
                    LinearProgressIndicator(
                      value: (_running || _submitting)
                          ? _progressPct / 100
                          : null,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _submitting
                          ? 'Submitting…'
                          : _statusLabel(_status) + ' $_progressPct%',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_completed) ...[
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check_circle,
                            color: Colors.green,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Saved to ${_destDir ?? "the export folder"}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          if (_destDir != null)
                            TextButton.icon(
                              onPressed: _openDestFolder,
                              icon: const Icon(Icons.folder_open, size: 16),
                              label: const Text('Open'),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: (_submitting || _running)
                              ? null
                              : _submit,
                          child: Text(_submitButtonLabel()),
                        ),
                      ),
                      if (_running) ...[
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: _cancel,
                          child: const Text('Cancel'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [Text(label), Text(value)],
    ),
  );

  String _statusLabel(ExportJobStatus? s) => switch (s) {
    ExportJobStatus.queued => 'Queued…',
    ExportJobStatus.running => 'Exporting…',
    ExportJobStatus.done => 'Complete',
    ExportJobStatus.failed => 'Failed',
    ExportJobStatus.cancelled => 'Cancelled',
    null => '',
  };

  String _submitButtonLabel() {
    if (_completed) return 'Done';
    if (_submitting) return 'Submitting…';
    if (_running) return 'Exporting…';
    final n = _list.length;
    return n == 0 ? 'Export' : 'Export $n clip${n == 1 ? '' : 's'}';
  }

  Widget _thumbFor(ExportClipDraft it) {
    return _thumbCache.putIfAbsent(
      it.id,
      () => _ClipThumbnail(
        api: widget.api,
        session: widget.session,
        cameraId: it.cameraId,
        ts: it.start,
      ),
    );
  }
}

class _ClipRow extends StatelessWidget {
  const _ClipRow({
    required this.index,
    required this.draft,
    required this.cameraName,
    required this.thumbnail,
    required this.rangeLabel,
    required this.durationLabel,
    required this.onEdit,
    required this.onRemove,
  });

  final int index;
  final ExportClipDraft draft;
  final String cameraName;
  final Widget thumbnail;
  final String rangeLabel;
  final String durationLabel;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onEdit,
      leading: SizedBox(
        width: 24,
        child: Text('$index', textAlign: TextAlign.center),
      ),
      title: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(width: 64, height: 36, child: thumbnail),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(cameraName, overflow: TextOverflow.ellipsis),
                Text(
                  rangeLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(durationLabel),
          IconButton(
            tooltip: 'Edit clip',
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: 'Remove clip',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Lazily fetches + caches one filmstrip preview frame for a list row.
class _ClipThumbnail extends StatefulWidget {
  const _ClipThumbnail({
    required this.api,
    required this.session,
    required this.cameraId,
    required this.ts,
  });

  final CrumbApi api;
  final Session session;
  final String cameraId;
  final DateTime ts;

  @override
  State<_ClipThumbnail> createState() => _ClipThumbnailState();
}

class _ClipThumbnailState extends State<_ClipThumbnail> {
  late final Future<Uint8List?> _future = widget.api.fetchFilmstripFrame(
    widget.session,
    widget.cameraId,
    widget.ts,
    width: 160,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black26,
      child: FutureBuilder<Uint8List?>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const SizedBox.shrink();
          }
          final bytes = snap.data;
          if (bytes == null) {
            return const Icon(
              Icons.videocam_off,
              size: 16,
              color: Colors.white38,
            );
          }
          return Image.memory(bytes, fit: BoxFit.cover);
        },
      ),
    );
  }
}
