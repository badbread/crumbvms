// The custom layout designer ("View Setup" in the Tauri client): pick a base
// cols x rows grid (or a quick preset), merge cells into bigger boxes / split
// them back apart, assign a camera to each box, choose a quick-switch icon,
// then save as a named server-side view.
//
// Interaction is a deliberate simplification of app.js's pointer-drag merge
// (vsCellPointerDown/vsMergeRegion): tap cells to multi-select them in "Edit
// layout" mode, then press Merge. The merge algorithm itself (fixpoint
// rectangle expansion so the result always tiles cleanly) is ported exactly
// from vsMergeRegion so saved geometry round-trips identically either way.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/views_api.dart';
import 'package:crumb_desktop/ui/saved_views/saved_views_screen.dart'
    show AppliedView;
import 'package:crumb_desktop/ui/special_tiles/config/special_tile_config_sheet.dart';
import 'package:crumb_desktop/ui/special_tiles/config/special_tile_palette.dart';
import 'package:crumb_desktop/ui/special_tiles/special_tile_spec.dart';

/// Curated quick-switch glyphs (VIEW_ICON_CHOICES in app.js).
const kViewIconChoices = [
  '🎥',
  '📹',
  '🚗',
  '🚙',
  '🌳',
  '🏠',
  '🚪',
  '🅿️',
  '⛰️',
  '🌙',
  '☀️',
  '👁️',
  '🐕',
  '🔑',
  '🚧',
  '🏢',
  '📦',
  '🛣️',
];

/// Opens the layout editor. Pass [existingView] to edit (its geometry +
/// assignments + name + icon are preloaded); the server has no update
/// endpoint for name/layout/slots, so saving an edit creates a new view and
/// deletes the old one (matching vsSaveAsView's "replace by name" behavior).
/// Returns the saved [SavedView] on success, or null if the editor was
/// canceled.
class LayoutEditorScreen extends StatefulWidget {
  const LayoutEditorScreen({
    super.key,
    required this.api,
    required this.session,
    this.existingView,
    this.onApply,
  });

  final CrumbApi api;
  final Session session;
  final SavedView? existingView;

  /// Apply the current layout to the wall NOW without saving it as a named
  /// view (the old client's "Apply" button). Save still persists + returns a
  /// [SavedView] via `Navigator.pop`.
  final void Function(AppliedView view)? onApply;

  @override
  State<LayoutEditorScreen> createState() => _LayoutEditorScreenState();
}

class _LayoutEditorScreenState extends State<LayoutEditorScreen> {
  static const _maxDim = CustomLayout.maxDim;

  int _cols = 4;
  int _rows = 3;
  List<LayoutCell> _cells = CustomLayout.unitGrid(4, 3).cells;
  final Map<String, TileSpec> _assign = {}; // cell.key -> spec

  final _nameCtrl = TextEditingController();
  String _icon = '🎥';
  final Set<String> _selected = {}; // cell keys selected for merge
  bool _editLayoutMode = false;
  String? _error;
  bool _saving = false;

  List<Camera> _cameras = [];
  bool _loadingCameras = true;

  @override
  void initState() {
    super.initState();
    _loadCameras();
    final existing = widget.existingView;
    if (existing != null) {
      _nameCtrl.text = existing.name;
      _icon = existing.icon ?? '🎥';
      final cl = existing.customLayout;
      if (cl != null) {
        _cols = cl.cols;
        _rows = cl.rows;
        _cells = cl.cells;
      }
      existing.slots.forEach((idxStr, raw) {
        final idx = int.tryParse(idxStr);
        if (idx == null || idx < 0 || idx >= _cells.length) return;
        final spec = TileSpec.fromSlotValue(raw);
        if (spec != null) _assign[_cells[idx].key] = spec;
      });
    }
  }

  Future<void> _loadCameras() async {
    try {
      final cams = await widget.api.listCameras(widget.session);
      if (!mounted) return;
      setState(() {
        _cameras = cams;
        _loadingCameras = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingCameras = false);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Camera? _cameraById(String id) {
    for (final c in _cameras) {
      if (c.id == id) return c;
    }
    return null;
  }

  // ── Grid geometry ops ────────────────────────────────────────────────────

  void _resetToUnitGrid(int cols, int rows) {
    setState(() {
      _cols = cols;
      _rows = rows;
      _cells = CustomLayout.unitGrid(cols, rows).cells;
      _assign.clear();
      _selected.clear();
      _error = null;
    });
  }

  void _applyTemplate(String id) {
    final t = CustomLayout.template(id);
    if (t == null) return;
    setState(() {
      _cols = t.cols;
      _rows = t.rows;
      _cells = t.cells;
      _assign.clear();
      _selected.clear();
      _error = null;
    });
  }

  void _toggleSelect(LayoutCell cell) {
    setState(() {
      if (_selected.contains(cell.key)) {
        _selected.remove(cell.key);
      } else {
        _selected.add(cell.key);
      }
    });
  }

  /// Port of vsMergeRegion: expand the selection's bounding box to a fixpoint
  /// so every cell it touches is fully absorbed, then collapse to one box.
  void _mergeSelected() {
    if (_selected.length < 2) {
      setState(() => _error = 'Select 2 or more boxes to merge.');
      return;
    }
    final sel = _cells.where((c) => _selected.contains(c.key)).toList();
    var minX = sel.map((c) => c.x).reduce((a, b) => a < b ? a : b);
    var maxX = sel.map((c) => c.x + c.w - 1).reduce((a, b) => a > b ? a : b);
    var minY = sel.map((c) => c.y).reduce((a, b) => a < b ? a : b);
    var maxY = sel.map((c) => c.y + c.h - 1).reduce((a, b) => a > b ? a : b);

    var changed = true;
    while (changed) {
      changed = false;
      for (final c in _cells) {
        final cx2 = c.x + c.w - 1, cy2 = c.y + c.h - 1;
        final intersects =
            !(c.x > maxX || cx2 < minX || c.y > maxY || cy2 < minY);
        if (!intersects) continue;
        if (c.x < minX) {
          minX = c.x;
          changed = true;
        }
        if (cx2 > maxX) {
          maxX = cx2;
          changed = true;
        }
        if (c.y < minY) {
          minY = c.y;
          changed = true;
        }
        if (cy2 > maxY) {
          maxY = cy2;
          changed = true;
        }
      }
    }

    final keepCam = _assign['$minX,$minY'];
    bool inBox(LayoutCell c) {
      final cx2 = c.x + c.w - 1, cy2 = c.y + c.h - 1;
      return c.x >= minX && cx2 <= maxX && c.y >= minY && cy2 <= maxY;
    }

    setState(() {
      for (final c in _cells) {
        if (inBox(c) && !(c.x == minX && c.y == minY)) {
          _assign.remove(c.key);
        }
      }
      final kept = _cells.where((c) => !inBox(c)).toList()
        ..add(
          LayoutCell(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1),
        );
      _cells = CustomLayout(
        cols: _cols,
        rows: _rows,
        cells: kept,
      ).sortedByReadingOrder().cells;
      if (keepCam != null) _assign['$minX,$minY'] = keepCam;
      _selected.clear();
      _error = null;
    });
  }

  void _splitCell(LayoutCell cell) {
    setState(() {
      final kept = _cells.where((c) => c != cell).toList();
      for (var y = cell.y; y < cell.y + cell.h; y++) {
        for (var x = cell.x; x < cell.x + cell.w; x++) {
          kept.add(LayoutCell(x: x, y: y, w: 1, h: 1));
        }
      }
      _assign.remove(cell.key); // position no longer hosts a single box
      _cells = CustomLayout(
        cols: _cols,
        rows: _rows,
        cells: kept,
      ).sortedByReadingOrder().cells;
      _selected.remove(cell.key);
    });
  }

  // ── Camera assignment (arrange mode) ────────────────────────────────────

  Future<void> _assignCell(LayoutCell cell) async {
    final current = _assign[cell.key];
    final chosen = await showModalBottomSheet<_AssignResult>(
      context: context,
      builder: (ctx) => _CameraPickerSheet(
        cameras: _cameras,
        loading: _loadingCameras,
        currentCameraId: current?.isCamera == true ? current!.cameraId : null,
      ),
    );
    if (chosen == null) return;
    setState(() {
      if (chosen.clear) {
        _assign.remove(cell.key);
      } else if (chosen.cameraId != null) {
        _assign[cell.key] = TileSpec.camera(chosen.cameraId!);
      }
    });
  }

  // ── Special-tile palette (arrange mode) ─────────────────────────────────
  // Port of vsDragSpec's drop handler + vsOpenItemConfig (app.js): dropping a
  // palette chip assigns a fresh default spec immediately, then — for the
  // configurable types — opens the config sheet right away. Cancelling the
  // config sheet leaves the default spec in place, matching vsCfgCancel
  // (which just closes the panel; the assignment made on drop already stuck).

  List<String> get _allCameraIds =>
      _cameras.map((c) => c.id).toList(growable: false);

  Future<void> _dropSpecialTile(LayoutCell cell, SpecialTileType type) async {
    final defaultSpec = SpecialTileSpec.defaultFor(
      type,
      allCameraIds: _allCameraIds,
    );
    setState(() {
      _assign[cell.key] = TileSpec.fromSlotValue(defaultSpec.toJson())!;
      _error = null;
    });
    if (!kSpecialTileConfigurable.contains(type)) return;
    final edited = await showSpecialTileConfigSheet(
      context,
      spec: defaultSpec,
      cameras: _cameras,
    );
    if (edited != null && mounted) {
      setState(
        () => _assign[cell.key] = TileSpec.fromSlotValue(edited.toJson())!,
      );
    }
  }

  /// Tap on a box that already holds a non-camera spec: offer Configure (if
  /// applicable) / Replace with a camera / Clear — a single-tap-friendly
  /// stand-in for app.js's ⚙ button + dblclick/right-click-to-edit + × button.
  Future<void> _handleSpecialTileTap(LayoutCell cell, TileSpec spec) async {
    final type = SpecialTileType.fromWire(spec.type);
    // Reconstruct the typed spec from the round-tripped raw JSON (fromRaw
    // returns null for `camera`/`ptz` or a type this build doesn't know —
    // e.g. a tile placed by another client — in which case we still let the
    // operator clear the box, just not configure it.
    final parsed = SpecialTileSpec.fromRaw(spec.raw);
    final configurable =
        type != null &&
        parsed != null &&
        kSpecialTileConfigurable.contains(type);

    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(parsed?.kind.wireType ?? spec.type),
              enabled: false,
            ),
            if (configurable)
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Configure'),
                onTap: () => Navigator.of(ctx).pop('configure'),
              ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Replace with a camera'),
              onTap: () => Navigator.of(ctx).pop('camera'),
            ),
            ListTile(
              leading: const Icon(Icons.clear),
              title: const Text('Clear this box'),
              onTap: () => Navigator.of(ctx).pop('clear'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'configure':
        final edited = await showSpecialTileConfigSheet(
          context,
          spec: parsed!,
          cameras: _cameras,
        );
        if (edited != null && mounted) {
          setState(
            () => _assign[cell.key] = TileSpec.fromSlotValue(edited.toJson())!,
          );
        }
        break;
      case 'camera':
        await _assignCell(cell);
        break;
      case 'clear':
        setState(() => _assign.remove(cell.key));
        break;
    }
  }

  /// Short icon + detail label for an assigned special-tile box (vsCellLabelText
  /// in app.js). Falls back to the bare wire type for a spec this build can't
  /// fully decode (still round-tripped, just not editable/labelable in detail).
  String _specialTileLabel(TileSpec spec) {
    final type = SpecialTileType.fromWire(spec.type);
    final parsed = SpecialTileSpec.fromRaw(spec.raw);
    SpecialTilePaletteItem? palette;
    if (type != null) {
      for (final p in SpecialTilePaletteItem.all) {
        if (p.type == type) {
          palette = p;
          break;
        }
      }
    }
    final icon = palette?.icon ?? '❔';
    final label = palette?.label ?? spec.type;
    final detail = switch (parsed) {
      CarouselSpec s =>
        '${s.cameras.length} cam${s.cameras.length == 1 ? '' : 's'} · ${s.mode.wire}',
      HotspotSpec s => s.isAutoFollow ? 'auto-follow' : 'classic',
      TextSpec s => s.text.isEmpty ? 'tap to edit' : s.text,
      WebSpec s => s.url.isEmpty ? 'set URL' : s.url,
      ImageSpec s => s.dataUrl.isEmpty ? 'pick a file' : 'set',
      ClockSpec() || EventsSpec() || null => null,
    };
    return detail == null ? '$icon $label' : '$icon $label · $detail';
  }

  // ── Save ─────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a name to save this view.');
      return;
    }
    final layout = CustomLayout(
      cols: _cols,
      rows: _rows,
      cells: _cells,
    ).sortedByReadingOrder();
    if (layout.cells.isEmpty) {
      setState(() => _error = 'Layout has no boxes.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final slots = <int, TileSpec>{};
    for (var i = 0; i < layout.cells.length; i++) {
      final spec = _assign[layout.cells[i].key];
      if (spec != null) slots[i] = spec;
    }

    try {
      final created = await widget.api.createView(
        widget.session,
        name: name,
        layout: layout.encodeLayoutField(),
        slots: slots,
        icon: _icon,
      );
      // The API has no update for name/layout/slots — saving an edit creates
      // the new row then deletes the old one, so "Save" on a loaded view
      // replaces it in place rather than leaving a duplicate.
      final existing = widget.existingView;
      if (existing != null && existing.id != created.id) {
        try {
          await widget.api.deleteView(widget.session, existing.id);
        } catch (_) {
          // Non-fatal: the new view was created successfully either way.
        }
      }
      if (mounted) Navigator.of(context).pop(created);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Save failed: $e';
          _saving = false;
        });
      }
    }
  }

  /// Bottom action bar matching the old client: a hint on the left, then
  /// Cancel / Apply / Save view. Apply uses the layout on the wall now; Save
  /// view also keeps it for later.
  Widget _actionBar() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Apply uses this layout on the wall now. Save view also keeps '
                'it under the view row to switch back to later.',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 4),
            if (widget.onApply != null)
              OutlinedButton(
                onPressed: _saving ? null : _apply,
                child: const Text('Apply'),
              ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save view'),
            ),
          ],
        ),
      ),
    );
  }

  /// Apply the current layout to the wall now, without saving it as a named
  /// view (the old client's "Apply" button).
  void _apply() {
    final layout = CustomLayout(
      cols: _cols,
      rows: _rows,
      cells: _cells,
    ).sortedByReadingOrder();
    if (layout.cells.isEmpty) {
      setState(() => _error = 'Layout has no boxes.');
      return;
    }
    final slots = <int, String>{};
    for (var i = 0; i < layout.cells.length; i++) {
      final spec = _assign[layout.cells[i].key];
      if (spec != null && spec.isCamera && spec.cameraId != null) {
        slots[i] = spec.cameraId!;
      }
    }
    final name = _nameCtrl.text.trim();
    widget.onApply?.call(
      AppliedView(
        id: '__preview__',
        name: name.isEmpty ? 'Custom layout' : name,
        layout: layout,
        slots: slots,
        rawSlots: const {},
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = CustomLayout(
      cols: _cols,
      rows: _rows,
      cells: _cells,
    ).sortedByReadingOrder().cells;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existingView == null
              ? 'View setup — design a custom layout'
              : 'Edit saved view',
        ),
      ),
      bottomNavigationBar: _actionBar(),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'View name',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Text(_icon, style: const TextStyle(fontSize: 26)),
                IconButton(
                  tooltip: 'Choose icon',
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  onPressed: _pickIcon,
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          _buildToolbar(),
          if (!_editLayoutMode) _buildSpecialTilePalette(),
          const Divider(height: 1),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: AspectRatio(
                  aspectRatio: _cols / _rows,
                  child: LayoutBuilder(
                    builder: (context, constraints) => Stack(
                      children: [
                        for (final cell in sorted)
                          _buildCell(
                            cell,
                            sorted.indexOf(cell),
                            constraints.maxWidth,
                            constraints.maxHeight,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final t in const [
            ['2x2', '2×2'],
            ['3x3', '3×3'],
            ['1plus5', '1+5'],
            ['1plus7', '1+7'],
            ['hero-bottom', 'Hero'],
          ])
            OutlinedButton(
              onPressed: () => _applyTemplate(t[0]),
              child: Text(t[1]),
            ),
          const SizedBox(width: 12),
          _dimStepper('Cols', _cols, (v) => _resetToUnitGrid(v, _rows)),
          _dimStepper('Rows', _rows, (v) => _resetToUnitGrid(_cols, v)),
          const SizedBox(width: 12),
          FilterChip(
            label: const Text('Edit layout'),
            selected: _editLayoutMode,
            onSelected: (v) => setState(() {
              _editLayoutMode = v;
              _selected.clear();
            }),
          ),
          if (_editLayoutMode)
            ElevatedButton(
              onPressed: _selected.length >= 2 ? _mergeSelected : null,
              child: const Text('Merge selected'),
            ),
        ],
      ),
    );
  }

  /// Draggable special-tile palette (VS_PALETTE in app.js): drag a chip onto a
  /// box below to drop a carousel/hotspot/clock/text/image/events/web tile
  /// into it (see `_dropSpecialTile`). Hidden in "Edit layout" mode, where a
  /// tap on a box selects it for merging instead.
  Widget _buildSpecialTilePalette() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Drag onto a box to add a special tile (tap a camera-less box for a plain camera):',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: 6),
          const SpecialTilePalette(),
        ],
      ),
    );
  }

  Widget _dimStepper(String label, int value, ValueChanged<int> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label '),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline),
          iconSize: 18,
          onPressed: value > 1 ? () => onChanged(value - 1) : null,
        ),
        Text('$value'),
        IconButton(
          icon: const Icon(Icons.add_circle_outline),
          iconSize: 18,
          onPressed: value < _maxDim ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }

  Widget _buildCell(LayoutCell cell, int index, double totalW, double totalH) {
    final cellW = totalW / _cols;
    final cellH = totalH / _rows;
    final merged = cell.w > 1 || cell.h > 1;
    final spec = _assign[cell.key];
    final selected = _selected.contains(cell.key);
    final scheme = Theme.of(context).colorScheme;

    return Positioned(
      left: cell.x * cellW,
      top: cell.y * cellH,
      width: cell.w * cellW,
      height: cell.h * cellH,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: DragTarget<SpecialTileType>(
          onWillAcceptWithDetails: (details) => !_editLayoutMode,
          onAcceptWithDetails: (details) =>
              _dropSpecialTile(cell, details.data),
          builder: (context, candidateData, rejectedData) {
            final hovering = candidateData.isNotEmpty;
            return GestureDetector(
              onTap: () {
                if (_editLayoutMode) {
                  _toggleSelect(cell);
                } else if (spec != null && !spec.isCamera) {
                  _handleSpecialTileTap(cell, spec);
                } else {
                  _assignCell(cell);
                }
              },
              child: Container(
                decoration: BoxDecoration(
                  color: hovering
                      ? scheme.primary.withValues(alpha: 0.35)
                      : (selected
                            ? scheme.primary.withValues(alpha: 0.25)
                            : (spec != null
                                  ? scheme.primaryContainer.withValues(
                                      alpha: 0.5,
                                    )
                                  : scheme.surfaceContainerHighest)),
                  border: Border.all(
                    color: hovering
                        ? scheme.primary
                        : (selected ? scheme.primary : scheme.outlineVariant),
                    width: hovering || selected ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      left: 4,
                      top: 2,
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(fontSize: 10, color: scheme.outline),
                      ),
                    ),
                    if (merged)
                      Positioned(
                        right: 2,
                        top: 0,
                        child: IconButton(
                          tooltip: 'Split this box',
                          icon: const Icon(Icons.call_split, size: 16),
                          onPressed: () => _splitCell(cell),
                        ),
                      ),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          spec == null
                              ? 'drop or tap to assign'
                              : (spec.isCamera
                                    ? (_cameraById(spec.cameraId!)?.name ??
                                          'camera')
                                    : _specialTileLabel(spec)),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: spec == null ? scheme.outline : null,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _pickIcon() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose an icon'),
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
    if (chosen != null) setState(() => _icon = chosen);
  }
}

class _AssignResult {
  const _AssignResult({this.cameraId, this.clear = false});
  final String? cameraId;
  final bool clear;
}

class _CameraPickerSheet extends StatelessWidget {
  const _CameraPickerSheet({
    required this.cameras,
    required this.loading,
    required this.currentCameraId,
  });

  final List<Camera> cameras;
  final bool loading;
  final String? currentCameraId;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: loading
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          : ListView(
              shrinkWrap: true,
              children: [
                if (currentCameraId != null)
                  ListTile(
                    leading: const Icon(Icons.clear),
                    title: const Text('Clear this box'),
                    onTap: () => Navigator.of(
                      context,
                    ).pop(const _AssignResult(clear: true)),
                  ),
                for (final cam in cameras)
                  ListTile(
                    leading: Icon(
                      cam.id == currentCameraId
                          ? Icons.videocam
                          : Icons.videocam_outlined,
                    ),
                    title: Text(cam.name),
                    selected: cam.id == currentCameraId,
                    onTap: () => Navigator.of(
                      context,
                    ).pop(_AssignResult(cameraId: cam.id)),
                  ),
                if (cameras.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No cameras visible to this account.'),
                  ),
              ],
            ),
    );
  }
}
