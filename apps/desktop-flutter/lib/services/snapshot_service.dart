// Grabs a still of the active video pane to disk and toasts a
// reveal-in-folder link. Ports the old Tauri client's `snapshotActivePane`
// (apps/desktop/src/app.js:4154), which called the native `snapshot_pane`
// command (mpv `screenshot-to-file`, apps/desktop/src-tauri/src/lib.rs:1234)
// and `reveal_path` (lib.rs:1291).
//
// No server endpoint is involved — this is a purely local, already-decoded
// frame grab, same as the old client. It works identically for live,
// playback, and the clip player because all three are mpv-backed
// media_kit [Player]s here (unlike the old web client, which had a separate
// `clipsSnapshot`, apps/desktop/src/app.js:9952, that drew an HTML
// `<video>` element to a canvas — Flutter has no such split; every pane is
// the same native player).
//
// Capture itself uses media_kit's own `Player.screenshot()`, which on the
// desktop (libmpv) backend is implemented via the same underlying mpv
// screenshot machinery the old Rust command drove directly
// (`screenshot-raw`/`screenshot-to-file`) — so no new native/FRB surface is
// needed for the capture.
//
// "Reveal in folder" is the one piece that's a deliberate downgrade: the old
// client's `reveal_path` used `explorer /select,<path>` on Windows to open
// Explorer with the file highlighted. There is no cross-platform Flutter
// plugin that does a select-and-highlight reveal, and building one means a
// platform channel or a new flutter_rust_bridge command (out of scope here —
// see integrationNotes/frbNeeded). This instead opens the *containing
// folder* via url_launcher's `file://` support, which needs no new native
// code and gets the user to the right folder, just not the file
// pre-selected.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'snapshot_registry.dart';
import '../ui/snapshot/snapshot_toast.dart';

class SnapshotService {
  SnapshotService._();

  /// Old client: `snapshotActivePane` (apps/desktop/src/app.js:4154).
  /// Captures whatever [SnapshotRegistry.instance] currently reports as
  /// active, writes a timestamped JPEG under `~/Pictures/CrumbVMS/`, and
  /// shows a toast whose detail line reveals the containing folder when
  /// clicked. Safe to call with nothing active (shows a hint toast instead
  /// of throwing) — the old client silently no-op'd in that case since
  /// `state.selectedSlot` was always non-null once a wall existed, but the
  /// Flutter port has no such guarantee before the first selection.
  static Future<void> captureActivePane(BuildContext context) async {
    final target = SnapshotRegistry.instance.active;
    if (target == null) {
      SnapshotToast.show(
        context,
        icon: '⚠',
        title: 'Nothing to snapshot',
        detail: 'Select or maximize a camera pane first.',
      );
      return;
    }
    await _capture(context, target);
  }

  static Future<void> _capture(
    BuildContext context,
    SnapshotTarget target,
  ) async {
    try {
      final bytes = await target.player.screenshot(format: 'image/jpeg');
      if (bytes == null || bytes.isEmpty) {
        throw Exception('no frame available (is the pane playing?)');
      }

      final home =
          Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
      if (home == null || home.isEmpty) {
        throw Exception('neither USERPROFILE nor HOME set');
      }
      final sep = Platform.pathSeparator;
      final dir = Directory('$home${sep}Pictures${sep}CrumbVMS');
      await dir.create(recursive: true);

      final ts = DateTime.now().millisecondsSinceEpoch;
      final safeName = target.cameraName.replaceAll(
        RegExp(r'[^A-Za-z0-9]+'),
        '_',
      );
      final file = File('${dir.path}$sep' 'snap-$safeName-$ts.jpg');
      await file.writeAsBytes(bytes, flush: true);

      if (!context.mounted) return;
      final name = file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : file.path;
      SnapshotToast.show(
        context,
        icon: '📸',
        title: 'Snapshot saved',
        detail: name,
        detailTooltip: '${file.path}\nClick to show in folder',
        onDetail: () => revealPath(file.path),
      );
    } catch (e) {
      if (!context.mounted) return;
      SnapshotToast.show(
        context,
        icon: '⚠',
        title: 'Snapshot failed',
        detail: '$e',
        timeout: const Duration(seconds: 8),
      );
    }
  }

  /// Best-effort "reveal in folder" — opens the parent directory of [path]
  /// in the OS file manager. See the file header for why this doesn't
  /// select/highlight the file the way the old client's `reveal_path` did.
  static Future<void> revealPath(String path) async {
    final parent = File(path).parent.path;
    await launchUrl(Uri.file(parent));
  }
}
