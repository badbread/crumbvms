// Saved Views: server-side CRUD for named wall arrangements + the custom
// layout geometry model. Ported from the Tauri client's app.js
// (fetchViews/saveView/deleteView/pushViewIcon/applyView, and the "View
// Setup" custom-grid builder: normalizeCustomLayout/vsTemplate/vsUnitCells)
// and services/api/src/views.rs (routes mounted at ROOT, no /api prefix).
//
// Route facts (services/api/src/views.rs):
//   GET    /views            -> [View]           (Bearer)
//   POST   /views             -> View, 201        (Bearer; requires manage_views)
//   DELETE /views/{id}        -> 204               (Bearer; owner or admin)
//   PUT    /views/{id}/icon   -> 204               (Bearer; owner or admin)
// `layout` is an opaque string: either a legacy preset id ("2x2", "3x3", ...)
// or "custom:<json>" carrying {cols,rows,cells:[{x,y,w,h}]} geometry built by
// the layout editor. `slots` is jsonb: {"<slotIndex>": "<cameraUuid>"} for a
// plain camera tile, or {"<slotIndex>": {"type": "...", ...}} for a richer
// tile spec (carousel/hotspot/ptz) — this client only ever WRITES plain
// camera specs, but must round-trip other tile types it doesn't understand
// rather than dropping them on save.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'models.dart';

/// A saved wall arrangement (`GET /views` row / `POST /views` response).
class SavedView {
  SavedView({
    required this.id,
    required this.name,
    required this.layout,
    required this.slots,
    required this.ownerId,
    required this.icon,
    required this.createdAt,
  });

  final String id; // UUID
  final String name;
  final String layout; // preset id, or "custom:{json}"
  final Map<String, dynamic> slots; // "<slotIndex>" -> camera-id | spec
  final String? ownerId; // null for legacy global rows
  final String? icon; // quick-switch glyph, e.g. "🚗"
  final DateTime? createdAt;

  factory SavedView.fromJson(Map<String, dynamic> j) => SavedView(
    id: j['id'] as String,
    name: (j['name'] as String?) ?? '',
    layout: (j['layout'] as String?) ?? '2x2',
    slots: (j['slots'] as Map?)?.cast<String, dynamic>() ?? const {},
    ownerId: j['owner_id'] as String?,
    icon: j['icon'] as String?,
    createdAt: DateTime.tryParse((j['created_at'] as String?) ?? ''),
  );

  /// The geometry this view's `layout` field encodes, or null if it's a
  /// legacy preset id this client doesn't recognize (caller should fall back
  /// to a generic auto-grid sized by slot count).
  CustomLayout? get customLayout => CustomLayout.decodeLayoutField(layout);
}

/// A rectangular tile in the custom-grid coordinate system (unit cells).
class LayoutCell {
  const LayoutCell({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final int x;
  final int y;
  final int w;
  final int h;

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};

  factory LayoutCell.fromJson(Map<String, dynamic> j) => LayoutCell(
    x: (j['x'] as num).toInt(),
    y: (j['y'] as num).toInt(),
    w: (j['w'] as num).toInt(),
    h: (j['h'] as num).toInt(),
  );

  /// Cell key for stable camera-assignment lookup by top-left position
  /// (survives merge/split/resize by position, matching vsKey in app.js).
  String get key => '$x,$y';

  bool overlaps(LayoutCell other) =>
      x < other.x + other.w &&
      x + w > other.x &&
      y < other.y + other.h &&
      y + h > other.y;
}

/// A custom grid layout: `cols` x `rows` unit cells, tiled with no overlap by
/// `cells` (each cell becomes one wall slot, in reading order).
///
/// Mirrors app.js's `state.customLayout` shape exactly so `layout` strings
/// stay interoperable with the web/Android clients and the Tauri client.
class CustomLayout {
  const CustomLayout({
    required this.cols,
    required this.rows,
    required this.cells,
  });

  static const int maxDim = 8; // VS_MAX in app.js

  final int cols;
  final int rows;
  final List<LayoutCell> cells;

  /// A fresh grid of 1x1 cells covering cols x rows (vsUnitCells).
  factory CustomLayout.unitGrid(int cols, int rows) {
    final cells = <LayoutCell>[];
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        cells.add(LayoutCell(x: x, y: y, w: 1, h: 1));
      }
    }
    return CustomLayout(cols: cols, rows: rows, cells: cells);
  }

  /// Built-in quick templates for the layout editor (vsTemplate).
  static CustomLayout? template(String name) {
    switch (name) {
      case '2x2':
        return CustomLayout.unitGrid(2, 2);
      case '3x3':
        return CustomLayout.unitGrid(3, 3);
      case '1plus5':
        return const CustomLayout(
          cols: 3,
          rows: 3,
          cells: [
            LayoutCell(x: 0, y: 0, w: 2, h: 2),
            LayoutCell(x: 2, y: 0, w: 1, h: 1),
            LayoutCell(x: 2, y: 1, w: 1, h: 1),
            LayoutCell(x: 0, y: 2, w: 1, h: 1),
            LayoutCell(x: 1, y: 2, w: 1, h: 1),
            LayoutCell(x: 2, y: 2, w: 1, h: 1),
          ],
        );
      case '1plus7':
        return const CustomLayout(
          cols: 4,
          rows: 4,
          cells: [
            LayoutCell(x: 0, y: 0, w: 3, h: 3),
            LayoutCell(x: 3, y: 0, w: 1, h: 1),
            LayoutCell(x: 3, y: 1, w: 1, h: 1),
            LayoutCell(x: 3, y: 2, w: 1, h: 1),
            LayoutCell(x: 0, y: 3, w: 1, h: 1),
            LayoutCell(x: 1, y: 3, w: 1, h: 1),
            LayoutCell(x: 2, y: 3, w: 1, h: 1),
            LayoutCell(x: 3, y: 3, w: 1, h: 1),
          ],
        );
      case 'hero-bottom':
        return const CustomLayout(
          cols: 4,
          rows: 3,
          cells: [
            LayoutCell(x: 0, y: 0, w: 4, h: 2),
            LayoutCell(x: 0, y: 2, w: 1, h: 1),
            LayoutCell(x: 1, y: 2, w: 1, h: 1),
            LayoutCell(x: 2, y: 2, w: 1, h: 1),
            LayoutCell(x: 3, y: 2, w: 1, h: 1),
          ],
        );
      default:
        return null;
    }
  }

  static List<LayoutCell> _sorted(List<LayoutCell> cells) {
    final out = List<LayoutCell>.from(cells);
    out.sort((a, b) => a.y != b.y ? a.y - b.y : a.x - b.x);
    return out;
  }

  CustomLayout sortedByReadingOrder() =>
      CustomLayout(cols: cols, rows: rows, cells: _sorted(cells));

  Map<String, dynamic> toJson() => {
    'cols': cols,
    'rows': rows,
    'cells': cells.map((c) => c.toJson()).toList(),
  };

  /// Validate + sanitize (normalizeCustomLayout). Returns null if unusable.
  static CustomLayout? normalize(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    final cols = ((raw['cols'] as num?)?.toInt() ?? 0).clamp(1, maxDim);
    final rows = ((raw['rows'] as num?)?.toInt() ?? 0).clamp(1, maxDim);
    final rawCells = raw['cells'];
    if (rawCells is! List || rawCells.isEmpty) return null;
    final cells = <LayoutCell>[];
    for (final c in rawCells) {
      if (c is! Map) continue;
      final m = c.cast<String, dynamic>();
      final x = (m['x'] as num?)?.toInt();
      final y = (m['y'] as num?)?.toInt();
      final w = (m['w'] as num?)?.toInt();
      final h = (m['h'] as num?)?.toInt();
      if (x == null || y == null || w == null || h == null) continue;
      if (x < 0 || y < 0 || w < 1 || h < 1) continue;
      if (x + w > cols || y + h > rows) continue;
      cells.add(LayoutCell(x: x, y: y, w: w, h: h));
    }
    if (cells.isEmpty) return null;
    return CustomLayout(cols: cols, rows: rows, cells: _sorted(cells));
  }

  /// Encode as the `layout` field value the server stores verbatim:
  /// `"custom:{...json...}"` (saveView in app.js).
  String encodeLayoutField() => 'custom:${jsonEncode(toJson())}';

  /// Decode a `layout` field value: `"custom:{json}"` -> geometry, a known
  /// legacy preset id -> its template, else null (unrecognized preset id).
  static CustomLayout? decodeLayoutField(String layout) {
    if (layout.startsWith('custom:')) {
      try {
        final j = jsonDecode(layout.substring(7)) as Map<String, dynamic>;
        return normalize(j);
      } catch (_) {
        return null;
      }
    }
    return template(layout);
  }
}

/// A slot's tile spec, decoded from the raw jsonb value stored under
/// `slots["<slotIndex>"]` (normalizeTileSpec in app.js). Plain camera slots
/// are stored as a bare camera-id string; richer tiles are a `{type: ...}`
/// object. This client only ever *creates* `camera` specs, but preserves
/// whatever it reads back (`raw`) so editing a view built by another client
/// doesn't silently drop carousel/hotspot/ptz tiles.
class TileSpec {
  const TileSpec.camera(this.cameraId) : type = 'camera', raw = null;

  const TileSpec._other(this.type, this.raw) : cameraId = null;

  final String type; // "camera" | "carousel" | "hotspot" | "ptz" | ...
  final String? cameraId; // populated only when type == "camera"
  final Map<String, dynamic>? raw; // the original spec object, for non-camera

  bool get isCamera => type == 'camera';

  /// The JSON value to store back under `slots["<slotIndex>"]`: a bare
  /// camera-id string for plain cameras (matches the {idx:cam} contract used
  /// by web/Android), or the original spec object otherwise.
  dynamic toSlotValue() => isCamera ? cameraId : raw;

  static TileSpec? fromSlotValue(dynamic v) {
    if (v == null) return null;
    if (v is String) return TileSpec.camera(v);
    if (v is Map) {
      final m = v.cast<String, dynamic>();
      final type = m['type'] as String?;
      if (type == null) return null;
      if (type == 'camera') {
        final id = m['cameraId'] as String?;
        return id == null ? null : TileSpec.camera(id);
      }
      return TileSpec._other(type, m);
    }
    return null;
  }
}

/// `POST /views` request body (CreateViewRequest in views.rs).
extension SavedViewsApi on CrumbApi {
  /// GET /views -> views visible to the caller (own + legacy global + shared).
  Future<List<SavedView>> listViews(Session s) async {
    final resp = await _get(s, '/views');
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load saved views (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    final list = jsonDecode(resp.body) as List<dynamic>;
    return list
        .map((e) => SavedView.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// POST /views -> the created view (201). `slots` maps slot index -> spec.
  Future<SavedView> createView(
    Session s, {
    required String name,
    required String layout,
    Map<int, TileSpec> slots = const {},
    String? icon,
  }) async {
    final slotsJson = <String, dynamic>{};
    for (final e in slots.entries) {
      slotsJson[e.key.toString()] = e.value.toSlotValue();
    }
    final resp = await _post(s, '/views', {
      'name': name,
      'layout': layout,
      'slots': slotsJson,
      if (icon != null) 'icon': icon,
    });
    if (resp.statusCode != 201) {
      throw CrumbApiException(
        'Failed to save view (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return SavedView.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// DELETE /views/{id} -> 204.
  Future<void> deleteView(Session s, String id) async {
    final resp = await _delete(s, '/views/$id');
    if (resp.statusCode != 204 && resp.statusCode != 404) {
      throw CrumbApiException(
        'Failed to delete view (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
  }

  /// PUT /views/{id}/icon -> 204. Pass `icon: null` to clear it back to unset.
  Future<void> setViewIcon(Session s, String id, String? icon) async {
    final resp = await _put(s, '/views/$id/icon', {'icon': icon});
    if (resp.statusCode != 204) {
      throw CrumbApiException(
        'Failed to set view icon (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
  }

  Future<http.Response> _get(Session s, String path) => http.get(
    Uri.parse('${s.base}$path'),
    headers: {'authorization': 'Bearer ${s.token}'},
  );

  Future<http.Response> _post(
    Session s,
    String path,
    Map<String, dynamic> body,
  ) => http.post(
    Uri.parse('${s.base}$path'),
    headers: {
      'authorization': 'Bearer ${s.token}',
      'content-type': 'application/json',
    },
    body: jsonEncode(body),
  );

  Future<http.Response> _put(
    Session s,
    String path,
    Map<String, dynamic> body,
  ) => http.put(
    Uri.parse('${s.base}$path'),
    headers: {
      'authorization': 'Bearer ${s.token}',
      'content-type': 'application/json',
    },
    body: jsonEncode(body),
  );

  Future<http.Response> _delete(Session s, String path) => http.delete(
    Uri.parse('${s.base}$path'),
    headers: {'authorization': 'Bearer ${s.token}'},
  );
}
