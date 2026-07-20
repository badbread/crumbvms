// SPDX-License-Identifier: AGPL-3.0-or-later

// Settings → Diagnostics (issue #180): the verbose-logging toggle and the
// scrubbed log export. The capture itself lives in
// `services/diagnostics_service.dart`; this pane is just its controls.

import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/diagnostics_service.dart';
import '../fullscreen/native_picker_guard.dart';

class DiagnosticsPane extends StatefulWidget {
  const DiagnosticsPane({super.key});

  @override
  State<DiagnosticsPane> createState() => _DiagnosticsPaneState();
}

class _DiagnosticsPaneState extends State<DiagnosticsPane> {
  String? _status; // transient "Saved to…" / "Copied" feedback

  Future<void> _export() async {
    final diag = DiagnosticsService.instance;
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .split('.')
        .first;
    final loc = await runNativePicker(
      () => getSaveLocation(suggestedName: 'crumb-diagnostics-$stamp.txt'),
    );
    if (loc == null) return; // cancelled
    try {
      final bytes = utf8.encode(diag.buildExport());
      final file = XFile.fromData(
        bytes,
        mimeType: 'text/plain',
        name: 'crumb-diagnostics.txt',
      );
      await file.saveTo(loc.path);
      setState(() => _status = 'Saved to ${loc.path}');
    } catch (e) {
      setState(() => _status = 'Export failed: $e');
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: DiagnosticsService.instance.buildExport()),
    );
    setState(() => _status = 'Copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    final diag = DiagnosticsService.instance;
    return AnimatedBuilder(
      animation: diag,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Diagnostics',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            'The client always keeps a small rolling log of warnings and '
            'errors. Turn on verbose logging while reproducing a problem, '
            'then export the log and attach it to your bug report. Exports '
            'are scrubbed — tokens, passwords, and credentials are never '
            'included.',
            style: TextStyle(color: Colors.white70, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Verbose logging'),
            subtitle: const Text(
              'Also capture HTTP request traces and video-player (mpv) logs. '
              'Bounded — safe to leave on while reproducing an issue.',
              style: TextStyle(fontSize: 11.5),
            ),
            value: diag.verbose,
            onChanged: (v) => diag.verbose = v,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _export,
                icon: const Icon(Icons.save_alt, size: 18),
                label: const Text('Export logs…'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _copy,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy to clipboard'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${diag.length} lines captured',
            style: const TextStyle(color: Colors.white54, fontSize: 11.5),
          ),
          if (_status != null) ...[
            const SizedBox(height: 6),
            Text(
              _status!,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
