// The HA badge editor's sticky TOP bar — one row, always in the same place,
// for everything that is about the SESSION rather than about one badge.
//
// This replaces two pieces of chrome the editor used to carry: the generic
// bottom `OverlayEditorBar` (whose geometry tooling now lives in the badge
// popover's multi-select body, `ha_badge_popover.dart`) and the floating,
// drag-to-move `HaOverlayEditPanel` (deleted — a movable window that covered
// the video it was editing, and that the operator had to move to see their own
// work). Per-badge styling is now anchored to the badge itself; this bar keeps
// only what is session-wide:
//
//   [Editing HA overlay — Front Door] [+ Add entity ▾] [Live|On|Off]
//   [Snap] [Undo] [Redo] [⋮] … [Done] [✕]
//
// The Live|On|Off segmented control is the state PREVIEW
// (`HaOverlayController.previewState`): an edit-session-only override that
// makes every badge render as if its entity read on/off. It is what makes the
// paired Off/On background swatches editable at all — otherwise the operator
// is picking an "on" color they cannot see until the real device happens to
// change state. See `HaOverlayController.previewState` for why this is not a
// state-honesty violation.
//
// Nothing here persists. Done routes to the host's `endEditAndSave`; ✕ / Esc
// route to [confirmHaEditExit] and then to save-or-discard, per the editor's
// deferred-save contract (`ha_overlay_controller.dart`).

import 'package:flutter/material.dart';

import 'ha_entity_palette.dart';
import 'ha_overlay_controller.dart' show HaOverlayController;

/// Height the bar occupies — the host reserves this much top inset on the
/// editor (`OverlayEditorController.setEditTopInset`) so a badge can never be
/// dragged underneath it.
const double kHaEditTopBarHeight = 48;

/// What the operator chose at the "you have unsaved overlay changes" prompt.
enum HaEditExitChoice { keepEditing, discard, saveAndClose }

/// The Esc / ✕ guard. Callers show this ONLY when the session actually has
/// changes to lose (`OverlayEditorController.canUndo`) — an untouched session
/// exits immediately, with no dialog to dismiss.
///
/// Deliberately three-way rather than a yes/no: the editor's whole model is
/// deferred save, so "I hit Esc" is ambiguous between "throw this away" and
/// "I'm done, close it" — a two-button dialog would make one of those a trap.
Future<HaEditExitChoice> confirmHaEditExit(BuildContext context) async {
  final choice = await showDialog<HaEditExitChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Discard overlay changes?'),
      content: const Text(
        'This overlay has unsaved changes. Nothing has been written to the '
        'server yet.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, HaEditExitChoice.keepEditing),
          child: const Text('Keep editing'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, HaEditExitChoice.discard),
          child: const Text('Discard'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, HaEditExitChoice.saveAndClose),
          child: const Text('Save and close'),
        ),
      ],
    ),
  );
  // A dismissed barrier is "I didn't mean to leave", not "throw my work away".
  return choice ?? HaEditExitChoice.keepEditing;
}

class HaOverlayEditTopBar extends StatelessWidget {
  const HaOverlayEditTopBar({
    super.key,
    required this.host,
    required this.cameraName,
    required this.onDone,
    required this.onCancel,
  });

  final HaOverlayController host;

  /// Shown in the title chip so the operator always knows which camera's
  /// overlay they are editing (the pane's own name label is pushed below this
  /// bar while editing).
  final String cameraName;

  /// Save + exit. The host owns persistence (`endEditAndSave`).
  final VoidCallback onDone;

  /// ✕ — identical to Esc: the host runs the [confirmHaEditExit] guard.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = host.editor;
    return Material(
      color: const Color(0xF01A1D22),
      child: SizedBox(
        height: kHaEditTopBarHeight,
        child: AnimatedBuilder(
          animation: c,
          builder: (context, _) {
            final hasItems = c.items.isNotEmpty;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  _TitleChip(cameraName: cameraName),
                  const SizedBox(width: 10),
                  _AddEntityButton(host: host),
                  const SizedBox(width: 10),
                  _StatePreviewControl(host: host),
                  const SizedBox(width: 10),
                  _BarIcon(
                    icon: c.snapEnabled ? Icons.grid_on : Icons.grid_off,
                    tooltip: c.snapEnabled
                        ? 'Alignment snapping on (hold Alt to bypass while '
                            'dragging)'
                        : 'Alignment snapping off',
                    active: c.snapEnabled,
                    onTap: c.toggleSnap,
                  ),
                  _BarIcon(
                    icon: Icons.undo,
                    tooltip: 'Undo (Ctrl+Z)',
                    onTap: c.canUndo ? c.undo : null,
                  ),
                  _BarIcon(
                    icon: Icons.redo,
                    tooltip: 'Redo (Ctrl+Y)',
                    onTap: c.canRedo ? c.redo : null,
                  ),
                  _OverflowMenu(host: host, hasItems: hasItems),
                  const Spacer(),
                  // Hint text, dropped first when the pane is narrow — the
                  // modifier gestures are discoverability, not controls.
                  const Flexible(
                    child: Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: Text(
                        'Shift/Ctrl-click to multi-select · drag empty space '
                        'to box-select · Alt bypasses snapping',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style:
                            TextStyle(color: Colors.white30, fontSize: 10.5),
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: onDone,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2CA3E8),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      minimumSize: const Size(0, 32),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                    child: const Text('Done'),
                  ),
                  const SizedBox(width: 4),
                  _BarIcon(
                    icon: Icons.close,
                    tooltip: 'Cancel (Esc)',
                    onTap: onCancel,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _TitleChip extends StatelessWidget {
  const _TitleChip({required this.cameraName});
  final String cameraName;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF232830),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tune, size: 14, color: Color(0xFF4CC9FF)),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(
                'Editing HA overlay - $cameraName',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
}

/// "+ Add entity" — an ANCHORED DROPDOWN over the camera's linked entities,
/// not a persistent palette. Picking places the badge at frame center, selects
/// it and closes the menu; the popover then opens on the new badge, so the
/// add → position → style flow runs without the operator ever hunting for a
/// panel. Already-placed entities keep their checkmark and re-select instead
/// of placing a duplicate (`HaOverlayController.pickFromPalette`).
class _AddEntityButton extends StatefulWidget {
  const _AddEntityButton({required this.host});
  final HaOverlayController host;

  @override
  State<_AddEntityButton> createState() => _AddEntityButtonState();
}

class _AddEntityButtonState extends State<_AddEntityButton> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final links = host.links;
    return MenuAnchor(
      controller: _menu,
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Color(0xF01A1D22)),
        padding: WidgetStatePropertyAll(EdgeInsets.all(10)),
      ),
      builder: (context, controller, _) => TextButton.icon(
        onPressed: links.isEmpty
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        style: TextButton.styleFrom(
          backgroundColor: const Color(0xFF2A2F36),
          disabledBackgroundColor:
              const Color(0xFF2A2F36).withValues(alpha: 0.35),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white24,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 32),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(5),
          ),
        ),
        icon: const Icon(Icons.add, size: 15),
        label: const Text('Add entity', style: TextStyle(fontSize: 12)),
      ),
      menuChildren: [
        // The palette rebuilds with the editor so its "placed" checkmarks stay
        // truthful while the menu is open (pick one, it ticks immediately).
        AnimatedBuilder(
          animation: host.editor,
          builder: (context, _) => HaEntityPalette(
            links: links,
            placedIds: host.placedIdsInSession,
            // Search earns its space only once the list stops fitting on
            // screen; below that it is a box to tab past.
            showSearch: links.length > 8,
            onPick: (link) {
              host.pickFromPalette(link);
              // Placing is a one-shot: the badge is now selected and its
              // popover is up, which is where the operator's attention goes.
              _menu.close();
            },
          ),
        ),
      ],
    );
  }
}

/// Live | On | Off. See the file doc + `HaOverlayController.previewState`.
class _StatePreviewControl extends StatelessWidget {
  const _StatePreviewControl({required this.host});
  final HaOverlayController host;

  @override
  Widget build(BuildContext context) {
    final p = host.previewState;
    return Tooltip(
      message: 'Preview how badges look in each state while you style them. '
          'Editing only — it never changes the device or what the wall shows.',
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF232830),
          borderRadius: BorderRadius.circular(5),
        ),
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _seg('Live', p == null, () => host.previewState = null),
            _seg('On', p == true, () => host.previewState = true),
            _seg('Off', p == false, () => host.previewState = false),
          ],
        ),
      ),
    );
  }

  Widget _seg(String label, bool active, VoidCallback onTap) => SizedBox(
        height: 26,
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            backgroundColor:
                active ? const Color(0xFF2CA3E8) : Colors.transparent,
            foregroundColor: active ? Colors.white : Colors.white54,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ),
      );
}

/// Rare, destructive-or-bulk session actions, kept out of the main row.
class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({required this.host, required this.hasItems});

  final HaOverlayController host;
  final bool hasItems;

  Future<void> _clearAll(BuildContext context) async {
    final n = host.editor.items.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove every badge?'),
        content: Text(
          'This removes all $n badge${n == 1 ? '' : 's'} from this camera\'s '
          'overlay. It is undoable (Ctrl+Z) and nothing is saved until you '
          'press Done.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove all'),
          ),
        ],
      ),
    );
    if (ok == true) host.editor.clearAll();
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      color: const Color(0xFF232830),
      position: PopupMenuPosition.under,
      icon: const Icon(Icons.more_vert, size: 18, color: Colors.white70),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 160),
      onSelected: (v) {
        switch (v) {
          case 'select-all':
            host.editor.setSelection({
              for (final i in host.editor.items) i.id,
            });
          case 'clear-all':
            _clearAll(context);
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'select-all',
          enabled: hasItems,
          child: const Text('Select all', style: TextStyle(fontSize: 13)),
        ),
        PopupMenuItem(
          value: 'clear-all',
          enabled: hasItems,
          child: const Text(
            'Clear all',
            style: TextStyle(fontSize: 13, color: Color(0xFFE5484D)),
          ),
        ),
      ],
    );
  }
}

class _BarIcon extends StatelessWidget {
  const _BarIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: SizedBox(
          width: 34,
          height: 32,
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              backgroundColor:
                  active ? const Color(0xFF2E4B5F) : Colors.transparent,
              foregroundColor:
                  active ? const Color(0xFF4CC9FF) : Colors.white70,
              disabledForegroundColor: Colors.white24,
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            child: Icon(icon, size: 16),
          ),
        ),
      );
}
