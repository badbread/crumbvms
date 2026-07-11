// The saved-views quick-switch row — the horizontal strip of view chips under
// the tab bar (port of the old client's `#toolbar-layout-presets` /
// buildLayoutPresets). An "All Cameras" chip plus one chip per saved view;
// clicking a chip applies that view to the live wall. Shown on the Live tab.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/views_api.dart';
import 'package:crumb_desktop/ui/saved_views/saved_views_screen.dart'
    show AppliedView;
import 'package:crumb_desktop/ui/saved_views/view_prefs.dart';

class ViewSelectorBar extends StatefulWidget {
  const ViewSelectorBar({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    required this.activeViewId,
    required this.onApply,
    this.onSnapshot,
    this.onConfigView,
    this.showAllCameras = true,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;

  /// Right-cluster controls (old client's 2nd-toolbar right side): snapshot the
  /// active pane, and open the view/layout editor ("Config View").
  final VoidCallback? onSnapshot;
  final VoidCallback? onConfigView;

  /// The currently-applied view's id. Null or [ViewPrefs.allCamerasId] means
  /// the "All Cameras" chip is active.
  final String? activeViewId;

  /// Called when a chip is tapped. "All Cameras" passes
  /// `AppliedView.allCameras(...)` (id == [ViewPrefs.allCamerasId]).
  final void Function(AppliedView view) onApply;

  final bool showAllCameras;

  @override
  State<ViewSelectorBar> createState() => _ViewSelectorBarState();
}

class _ViewSelectorBarState extends State<ViewSelectorBar> {
  List<SavedView> _views = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final views = await widget.api.listViews(widget.session);
      if (mounted) {
        setState(() {
          _views = views;
          _loaded = true;
        });
      }
    } catch (_) {
      // Fail quiet — the wall still works, just without saved views.
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeAll = widget.activeViewId == null ||
        widget.activeViewId == ViewPrefs.allCamerasId;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Container(
        height: 34,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          children: [
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                children: [
                  if (widget.showAllCameras)
                    _chip(
                      icon: Icons.grid_view,
                      label: 'All Cameras',
                      active: activeAll,
                      onTap: () => widget
                          .onApply(AppliedView.allCameras(widget.cameras)),
                    ),
                  for (final v in _views)
                    _chip(
                      emoji: v.icon,
                      label: v.name.isEmpty ? '(unnamed)' : v.name,
                      active: widget.activeViewId == v.id,
                      onTap: () => widget.onApply(
                        AppliedView.fromSavedView(v, widget.cameras),
                      ),
                    ),
                  if (_loaded && _views.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 7,
                      ),
                      child: Text(
                        'No saved views yet',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Right controls (snapshot + Config View), matching the old client.
            if (widget.onSnapshot != null)
              IconButton(
                tooltip: 'Snapshot (S)',
                iconSize: 17,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.photo_camera_outlined),
                onPressed: widget.onSnapshot,
              ),
            if (widget.onConfigView != null)
              Padding(
                padding: const EdgeInsets.only(right: 6, left: 2),
                child: OutlinedButton.icon(
                  onPressed: widget.onConfigView,
                  icon: const Icon(Icons.dashboard_customize_outlined, size: 15),
                  label: const Text('Config View'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE8A33D),
                    side: const BorderSide(color: Color(0x66E8A33D)),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 26),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip({
    IconData? icon,
    String? emoji,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // Active chip follows the Live tab accent (amber), matching the old client
    // where the active view chip uses the current tab's --accent.
    const accent = Color(0xFFE8A33D);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Material(
        color: active ? accent.withValues(alpha: 0.16) : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: active ? accent : scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (emoji != null && emoji.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Text(emoji, style: const TextStyle(fontSize: 13)),
                  )
                else if (icon != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 5),
                    child: Icon(
                      icon,
                      size: 13,
                      color: active ? accent : scheme.onSurfaceVariant,
                    ),
                  ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: active ? scheme.onSurface : scheme.onSurfaceVariant,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
