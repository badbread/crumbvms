// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Two small operator affordances on the Plates tab, kept out of the already
// large plates_screen.dart and pure enough to unit-test:
//
//   * [copyPlateToClipboard] — put a read's PLATE on the clipboard.
//   * [showPlateNameDialog]  — set / edit / clear a plate's human-readable
//     NAME (issue #363, `PUT`/`DELETE /lpr/plate-labels`, admin-only).
//
// NAMING IS NOT WATCHLISTING. `plate_labels` is a first-class naming table,
// deliberately separate from `lpr_watchlist`: a name is display metadata that
// applies to EVERY read of that plate, watchlisted or not, and setting one
// creates no watchlist entry and raises no alert. The server resolves what
// clients render as `COALESCE(plate_labels.label, lpr_watchlist.label)` and
// ships it as `display_name`, so this client never re-implements that
// precedence — it renders `display_name` and writes only the name.
//
// Wording mirrors the web admin console's `namePlate()` (admin.html), which is
// the other surface that can write a name, so the two agree: the button reads
// "Name" / "Rename", a blank submission CLEARS, and the confirmations are
// "Plate named." / "Name cleared.". The one thing this surface adds is the
// explanatory line about alerts — a prompt() has nowhere to put it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/hotkeys/hotkey_gate.dart';

/// What "Copy plate" actually copies for [read]: the PLATE STRING, never the
/// human-readable name, even when the UI is showing the name in its place —
/// an operator copying a plate wants the thing they can paste into a search,
/// a report, or another system.
///
/// Prefers the normalized plate (what every other surface matches and displays)
/// and falls back to the provider's original text only when the normalized form
/// is empty. Returns `''` when the read carries neither, so callers can skip.
String plateCopyText(PlateRead read) {
  final normalized = read.plate.trim();
  if (normalized.isNotEmpty) return normalized;
  return read.plateRaw.trim();
}

/// True when the server has resolved a human-readable name for a plate.
/// [displayName] is the `display_name` DTO field, which the server already
/// resolves as `COALESCE(plate_labels.label, lpr_watchlist.label)` — this
/// client never re-derives that precedence, it only asks "is there a name?".
bool plateHasName(String? displayName) =>
    (displayName?.trim() ?? '').isNotEmpty;

/// Whether the Name/Rename affordance may render at all.
///
/// `PUT`/`DELETE /lpr/plate-labels` are admin-only, so a non-admin must never
/// be shown a control that would 403 ([isAdmin] is the client's `is_admin`
/// from `GET /auth/me`). A blank plate has no key to name, so it is also
/// excluded — the server would reject it with a 400.
bool canOfferPlateName({required bool isAdmin, required String plate}) =>
    isAdmin && plate.trim().isNotEmpty;

/// The Name/Rename action label, mirroring the web console's
/// `${named ? 'Rename' : 'Name'}` so the two surfaces read the same.
String plateNameActionLabel(String? displayName) =>
    plateHasName(displayName) ? 'Rename' : 'Name';

/// Tooltip for the Name/Rename affordance. Says what a name DOES (shows
/// everywhere) without implying it alerts — the dialog carries the full
/// "this is not the watchlist" wording.
String plateNameActionTooltip(String? displayName) => plateHasName(displayName)
    ? 'Rename this plate (shown wherever it appears)'
    : 'Name this plate (shown wherever it appears)';

/// Copy [plate] and confirm with the same brief SnackBar this tab uses for its
/// other transient actions. A no-op (no SnackBar) for an empty string.
Future<void> copyPlateToClipboard(BuildContext context, String plate) async {
  if (plate.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: plate));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Plate copied to clipboard'),
      duration: Duration(seconds: 2),
    ),
  );
}

/// The outcome of [showPlateNameDialog]: null when the operator cancelled,
/// otherwise the trimmed name to store — or an EMPTY string meaning "clear the
/// name", exactly like the web console's blank submission.
typedef PlateNameChoice = String;

/// Set, edit, or clear the human-readable name for [plate].
///
/// [currentName] prefills the field (pass the read's resolved `display_name`).
/// Returns null on cancel; otherwise the trimmed name, with `''` meaning clear.
/// Admin-only server-side — callers must only offer this to an admin, and still
/// handle a 403 defensively.
Future<PlateNameChoice?> showPlateNameDialog(
  BuildContext context, {
  required String plate,
  String? currentName,
}) {
  final controller = TextEditingController(text: currentName?.trim() ?? '');
  final hadName = (currentName?.trim() ?? '').isNotEmpty;
  return showDialog<String>(
    context: context,
    builder: (context) {
      void submit() => Navigator.of(context).pop(controller.text.trim());
      return AlertDialog(
        backgroundColor: const Color(0xFF23262E),
        title: Text(
          hadName ? 'Rename plate $plate' : 'Name plate $plate',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The field is wrapped so a keystroke here can never reach a
              // hardware hotkey handler (see hotkey_gate.dart). The dialog is
              // a pushed route, which `hotkeyContextBlocked` already catches,
              // but the suppressor is the guard that does not depend on how
              // this dialog happens to be routed.
              HotkeySuppressor.whileFocused(
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  onSubmitted: (_) => submit(),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: "e.g. Mom's car",
                    labelStyle: TextStyle(color: Colors.white54, fontSize: 13),
                    hintStyle: TextStyle(color: Colors.white24, fontSize: 13),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Shown wherever this plate appears, on every client. Naming a '
                'plate does not add it to the watchlist and does not raise '
                'alerts.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              if (hadName) ...[
                const SizedBox(height: 8),
                const Text(
                  'Leave the name blank to clear it.',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          if (hadName)
            TextButton(
              onPressed: () => Navigator.of(context).pop(''),
              child: const Text('Clear name',
                  style: TextStyle(color: Color(0xFFE8A33D), fontSize: 13)),
            ),
          TextButton(
            onPressed: submit,
            child: const Text('Save',
                style: TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      );
    },
  );
}
