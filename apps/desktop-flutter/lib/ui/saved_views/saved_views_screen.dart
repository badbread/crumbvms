// Saved Views manager: list, create/edit (via LayoutEditorScreen), delete,
// re-icon, drag-reorder, and star a launch ("default") view. Ported from the
// Tauri client's toolbar quick-switch row + Config View dialog
// (buildLayoutPresets/renderSavedViews/applyView/deleteView/pushViewIcon,
// LS_VIEW_ORDER/LS_DEFAULT_VIEW) but as a standalone full-screen manager
// since the new desktop app has no toolbar yet to dock a quick-switch row
// into (see integration notes).

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/views_api.dart';

import 'layout_editor_screen.dart';
import 'view_prefs.dart';

/// A fully-resolved view ready to hand to a wall/grid screen: geometry +
/// slot -> camera-id assignments. `slots` omits DOM-only/unsupported tile
/// types (carousel/hotspot/ptz) the desktop wall doesn't render yet — callers
/// that want those should inspect [rawSlots] instead.
class AppliedView {
  const AppliedView({
    required this.id,
    required this.name,
    required this.layout,
    required this.slots,
    required this.rawSlots,
  });

  /// The saved view's id, or [ViewPrefs.allCamerasId] for the synthetic
  /// "All Cameras" auto-grid (not a real server-side view).
  final String id;
  final String name;
  final CustomLayout layout;
  final Map<int, String> slots; // slot index -> camera id (camera tiles only)
  final Map<String, dynamic> rawSlots; // full slots jsonb, for richer tiles

  /// Build the "All Cameras" auto-grid view (applyAllCamerasView in app.js):
  /// every visible camera, auto-sized to as-square-as-possible.
  factory AppliedView.allCameras(List<Camera> cameras) {
    final n = cameras.isEmpty ? 1 : cameras.length;
    final cols = _ceilSqrt(n);
    final rows = (n + cols - 1) ~/ cols;
    final layout = CustomLayout.unitGrid(cols, rows);
    final slots = <int, String>{};
    for (var i = 0; i < cameras.length && i < layout.cells.length; i++) {
      slots[i] = cameras[i].id;
    }
    return AppliedView(
      id: ViewPrefs.allCamerasId,
      name: 'All Cameras',
      layout: layout,
      slots: slots,
      rawSlots: const {},
    );
  }

  static int _ceilSqrt(int n) {
    var c = 1;
    while (c * c < n) {
      c++;
    }
    return c;
  }

  static CustomLayout _autoGrid(int slotCount) {
    final n = slotCount.clamp(1, 64);
    final cols = _ceilSqrt(n);
    final rows = (n + cols - 1) ~/ cols;
    return CustomLayout.unitGrid(cols, rows);
  }

  factory AppliedView.fromSavedView(SavedView v, List<Camera> cameras) {
    // Unrecognized legacy preset ids decode to null — fall back to a generic
    // auto-grid sized by slot count so the view still opens with something.
    final cl = v.customLayout ?? _autoGrid(v.slots.length);
    final knownCameraIds = cameras.map((c) => c.id).toSet();
    final slots = <int, String>{};
    v.slots.forEach((idxStr, raw) {
      final idx = int.tryParse(idxStr);
      if (idx == null) return;
      final spec = TileSpec.fromSlotValue(raw);
      if (spec != null &&
          spec.isCamera &&
          knownCameraIds.contains(spec.cameraId)) {
        slots[idx] = spec.cameraId!;
      }
    });
    return AppliedView(
      id: v.id,
      name: v.name,
      layout: cl,
      slots: slots,
      rawSlots: v.slots,
    );
  }
}

/// Route target: `SavedViewsScreen(api: api, session: session, cameras: cameras,
/// onApplyView: (view) => ...)`. `onApplyView` is called when the operator
/// hits Apply on a view (or the "All Cameras" quick entry); wire it to switch
/// whatever wall/grid screen owns the live layout to `view.layout`/`view.slots`.
class SavedViewsScreen extends StatefulWidget {
  const SavedViewsScreen({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    this.onApplyView,
    this.showAllCamerasEntry = true,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;

  /// Invoked when the operator applies a view. If null, Apply still returns
  /// the [AppliedView] via `Navigator.pop`.
  final void Function(AppliedView view)? onApplyView;

  /// Whether to show the built-in "All Cameras" quick entry (matches
  /// options.showAllCamerasView in app.js — always on here; callers with a
  /// persisted app-options screen can gate this later).
  final bool showAllCamerasEntry;

  @override
  State<SavedViewsScreen> createState() => _SavedViewsScreenState();
}

class _SavedViewsScreenState extends State<SavedViewsScreen> {
  final _prefs = ViewPrefs();
  List<SavedView> _views = [];
  List<String> _order = [];
  String? _defaultId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  List<String> get _allIds => [
    if (widget.showAllCamerasEntry) ViewPrefs.allCamerasId,
    ..._views.map((v) => v.id),
  ];

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final views = await widget.api.listViews(widget.session);
      final defaultId = await _prefs.getDefaultViewId();
      // A default view that no longer exists (deleted elsewhere) clears
      // itself out, matching getDefaultView's stale-id handling in app.js.
      if (defaultId != null &&
          defaultId != ViewPrefs.allCamerasId &&
          !views.any((v) => v.id == defaultId)) {
        await _prefs.clearDefaultIfStale(defaultId);
      }
      final ids = [
        if (widget.showAllCamerasEntry) ViewPrefs.allCamerasId,
        ...views.map((v) => v.id),
      ];
      final order = await _prefs.reconciledOrder(ids);
      if (!mounted) return;
      final resolvedDefault = _resolveDefaultId(defaultId, views);
      setState(() {
        _views = views;
        _order = order;
        _defaultId = resolvedDefault;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load saved views: $e';
        _loading = false;
      });
    }
  }

  /// The default-view id to keep, after dropping one that no longer exists
  /// (matches getDefaultView's stale-id handling in app.js).
  String? _resolveDefaultId(String? defaultId, List<SavedView> views) {
    if (defaultId == null) return null;
    if (defaultId == ViewPrefs.allCamerasId) return defaultId;
    return views.any((v) => v.id == defaultId) ? defaultId : null;
  }

  SavedView? _viewById(String id) {
    for (final v in _views) {
      if (v.id == id) return v;
    }
    return null;
  }

  Future<void> _createOrEdit({SavedView? existing}) async {
    final result = await Navigator.of(context).push<SavedView>(
      MaterialPageRoute(
        builder: (_) => LayoutEditorScreen(
          api: widget.api,
          session: widget.session,
          existingView: existing,
        ),
      ),
    );
    if (result != null) await _refresh();
  }

  Future<void> _delete(SavedView v) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete saved view'),
        content: Text('Delete saved view "${v.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.deleteView(widget.session, v.id);
      await _prefs.clearDefaultIfStale(v.id);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _setIcon(SavedView v) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Icon for "${v.name}"'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final ic in kViewIconChoices)
                  InkWell(
                    onTap: () => Navigator.of(ctx).pop(ic),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(ic, style: const TextStyle(fontSize: 24)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    try {
      await widget.api.setViewIcon(widget.session, v.id, chosen);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Set icon failed: $e')));
      }
    }
  }

  Future<void> _toggleDefault(String id) async {
    final isNowDefault = await _prefs.toggleDefault(id);
    if (!mounted) return;
    setState(() => _defaultId = isNowDefault ? id : null);
  }

  void _apply(AppliedView view) {
    if (widget.onApplyView != null) {
      widget.onApplyView!(view);
    } else {
      Navigator.of(context).pop(view);
    }
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    final ids = List<String>.from(_order);
    if (newIndex > oldIndex) newIndex -= 1;
    final id = ids.removeAt(oldIndex);
    ids.insert(newIndex, id);
    setState(() => _order = ids);
    await _prefs.setExplicitOrder(ids);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved views'),
        actions: [
          IconButton(
            tooltip: 'New view',
            icon: const Icon(Icons.add),
            onPressed: () => _createOrEdit(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : RefreshIndicator(onRefresh: _refresh, child: _buildList()),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createOrEdit(),
        tooltip: 'New view',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildList() {
    final ids = _order.isEmpty ? _allIds : _order;
    if (ids.isEmpty) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text('No saved views yet — tap + to build one.'),
            ),
          ),
        ],
      );
    }
    return ReorderableListView.builder(
      itemCount: ids.length,
      onReorder: _onReorder,
      itemBuilder: (context, i) {
        final id = ids[i];
        if (id == ViewPrefs.allCamerasId) {
          return _allCamerasTile(key: ValueKey(id));
        }
        final v = _viewById(id);
        if (v == null) return SizedBox.shrink(key: ValueKey(id));
        return _viewTile(v, key: ValueKey(id));
      },
    );
  }

  Widget _allCamerasTile({required Key key}) {
    final isDefault = _defaultId == ViewPrefs.allCamerasId;
    return ListTile(
      key: key,
      leading: const Text('▦', style: TextStyle(fontSize: 22)),
      title: const Text('All Cameras'),
      subtitle: const Text('Every visible camera, auto-arranged'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: isDefault ? 'Unset launch view' : 'Set as launch view',
            icon: Icon(isDefault ? Icons.star : Icons.star_border),
            color: isDefault ? Colors.amber : null,
            onPressed: () => _toggleDefault(ViewPrefs.allCamerasId),
          ),
          FilledButton(
            onPressed: () => _apply(AppliedView.allCameras(widget.cameras)),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  Widget _viewTile(SavedView v, {required Key key}) {
    final isDefault = _defaultId == v.id;
    return ListTile(
      key: key,
      leading: Text(v.icon ?? '🎥', style: const TextStyle(fontSize: 22)),
      title: Text(v.name),
      subtitle: Text('${v.slots.length} tile${v.slots.length == 1 ? '' : 's'}'),
      onTap: () => _apply(AppliedView.fromSavedView(v, widget.cameras)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: isDefault ? 'Unset launch view' : 'Set as launch view',
            icon: Icon(isDefault ? Icons.star : Icons.star_border),
            color: isDefault ? Colors.amber : null,
            onPressed: () => _toggleDefault(v.id),
          ),
          IconButton(
            tooltip: 'Icon',
            icon: const Icon(Icons.emoji_emotions_outlined),
            onPressed: () => _setIcon(v),
          ),
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _createOrEdit(existing: v),
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(v),
          ),
          FilledButton(
            onPressed: () =>
                _apply(AppliedView.fromSavedView(v, widget.cameras)),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}
