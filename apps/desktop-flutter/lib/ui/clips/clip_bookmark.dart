// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Bookmarking a moment of a plate clip: the same add-bookmark dialog Playback
// uses (note + "Protect from auto-delete"), pre-filled for the clip's camera,
// followed by a snackbar with Undo (DELETE /bookmarks/:id).

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/bookmarks_api.dart';
import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/ui/bookmarks/add_bookmark_dialog.dart';

/// Default bookmark note for a plate read: `ABC123 (Mom's car) · Driveway`.
/// The known name is omitted when there is none.
String clipBookmarkDescription({
  required String plate,
  String? displayName,
  required String cameraName,
}) {
  final p = plate.isEmpty ? 'Plate' : plate;
  final n = displayName?.trim() ?? '';
  final who = n.isEmpty ? p : '$p ($n)';
  return cameraName.isEmpty ? who : '$who · $cameraName';
}

/// Whether the platform-wide bookmarks switch (GET /status) is on. Any failure
/// (offline, older server) counts as enabled: the create call itself reports a
/// 403 for a role without bookmark access.
Future<bool> clipBookmarksAvailable(CrumbApi api, Session session) async {
  try {
    return await api.bookmarksEnabled(session);
  } catch (_) {
    return true;
  }
}

/// Opens the add-bookmark dialog at wall-clock [at] on the clip's camera and,
/// once saved, shows a snackbar with Undo.
Future<void> bookmarkClipMoment(
  BuildContext context, {
  required CrumbApi api,
  required Session session,
  required String cameraId,
  required String cameraName,
  required DateTime at,
  required String description,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final added = await showAddBookmarkDialog(
    context,
    api: api,
    session: session,
    camera: Camera(
      id: cameraId,
      name: cameraName,
      enabled: true,
      hasSub: false,
      ptz: false,
      servedBy: 'crumb',
    ),
    at: at,
    defaultDescription: description,
  );
  if (added == null || messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          added.isProtected ? 'Bookmark saved (protected)' : 'Bookmark saved',
        ),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            try {
              await api.deleteBookmark(session, added.id);
              messenger.showSnackBar(
                const SnackBar(content: Text('Bookmark removed')),
              );
            } catch (_) {
              messenger.showSnackBar(
                const SnackBar(content: Text('Could not remove the bookmark')),
              );
            }
          },
        ),
      ),
    );
}
