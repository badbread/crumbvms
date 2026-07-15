// Thin host adapter wiring the generic drag-to-place overlay editor
// (`overlay_editor/`) to HA badge placements (issue #170 P0): wraps a
// camera's PLACED `HaLink`s as `OverlayItem`s (video-frame anchored),
// persists via the placement PUT/clear, and exposes the camera's full
// linked-entity set for the palette.
//
// Lifecycle (host-loads-first, per `overlay_editor_controller.dart`'s
// synchronous-edit contract): call [loadLinks] BEFORE maximizing/entering
// edit mode, THEN [beginEditFromLoadedLinks]. Guard the async gap with
// [editor]'s `editToken` so a fast camera-switch mid-load can't clobber a
// newer session:
//
//   final ha = HaOverlayController(api: widget.api, session: widget.session);
//   final token = ha.editor.editToken;
//   await ha.loadLinks(cam.id);
//   if (ha.editor.editToken != token) return; // stale — user moved on
//   _maximize(cam);
//   ha.beginEditFromLoadedLinks();
//   // ... later, on Done:
//   await ha.endEditAndSave();

import '../../api/crumb_api.dart';
import '../../api/ha_api.dart';
import '../../api/ha_models.dart';
import '../../api/models.dart';
import '../overlay_editor/overlay_editor_controller.dart';
import '../overlay_editor/overlay_item.dart';

/// [OverlayItem] adapter over a placed [HaLink] — video-frame anchored,
/// always-square badge, resized via the editor bar's size stepper only (no
/// on-canvas drag-resize handle; see [resizable]).
///
/// Also carries the badge's editable per-badge style (migration 0059) —
/// [labelText], [colorHex], [iconKey], [showState], [showAge] — seeded from
/// the link and mutated in-session by the badge style editor
/// (`ha_badge_style_editor.dart`); persisted by
/// [HaOverlayController.endEditAndSave].
class HaOverlayBadgeItem implements OverlayItem {
  HaOverlayBadgeItem(this.link, {double? x, double? y})
    : _x = x ?? link.overlayX ?? 0.46,
      _y = y ?? link.overlayY ?? 0.46,
      _scale = (link.overlaySize ?? 1.0).clamp(0.1, 8.0).toDouble(),
      _opacity = (link.overlayOpacity ?? 1.0).clamp(0.05, 1.0).toDouble(),
      labelText = link.label,
      colorHex = link.overlayColor,
      iconKey = link.overlayIcon,
      showState = link.overlayShowState,
      showAge = link.overlayShowAge;

  final HaLink link;

  double _x;
  double _y;
  double _scale;
  double _opacity;

  /// Editable caption for this link (null/blank falls back to the entity id
  /// in display). Written back as the LINK's `label` on save when changed.
  String? labelText;

  /// '#RRGGBB' badge color override, or null for the state-derived default.
  String? colorHex;

  /// Curated icon-slug override (`ha_icons.dart`'s `kHaBadgeIconChoices`),
  /// or null for the class-derived default.
  String? iconKey;

  /// Pin the live state text / relative age next to the badge on the wall.
  bool showState;
  bool showAge;

  /// Display caption honoring the in-session edit (mirrors
  /// `HaLink.displayLabel`, against [labelText] instead of `link.label`).
  String get displayLabel =>
      (labelText != null && labelText!.trim().isNotEmpty)
          ? labelText!
          : link.entityId;

  /// Session-only group membership — the placement PUT has no group field
  /// (see `OverlayItem.groupId`'s doc), so HA badge groups exist only within
  /// one edit session as a layout convenience.
  String? _groupId;

  @override
  String get id => link.id;

  @override
  double get x => _x;
  @override
  set x(double v) => _x = v;
  @override
  double get y => _y;
  @override
  set y(double v) => _y = v;

  @override
  OverlayAnchor get anchor => OverlayAnchor.videoFrame;

  /// Reference badge size (logical px at pane-scale 1.0) — matches the
  /// black-scrim chip drawn by `ha_overlay_layer.dart`'s `HaBadgeChip` and
  /// the ~22px scale of the tile-badge visual language
  /// (`live_status/live_status_badges.dart`).
  static const double baseRefPx = 22;

  @override
  (double w, double h) baseSize() => (baseRefPx * _scale, baseRefPx * _scale);

  @override
  void setBaseSize(double w, double h) {
    final v = (w > h ? w : h) / baseRefPx;
    _scale = v.clamp(0.1, 8.0).toDouble();
  }

  /// The `overlay_size` multiplier to persist (mirrors the server's clamp,
  /// services/api/src/ha.rs `put_placement`).
  double get scale => _scale;

  @override
  bool get resizable => false;

  @override
  String? get groupId => _groupId;
  @override
  set groupId(String? v) => _groupId = v;

  @override
  double get opacity => _opacity;
  @override
  set opacity(double v) => _opacity = v.clamp(0.05, 1.0).toDouble();

  @override
  Object captureState() => (
        x: _x,
        y: _y,
        scale: _scale,
        opacity: _opacity,
        label: labelText,
        color: colorHex,
        icon: iconKey,
        showState: showState,
        showAge: showAge,
        group: _groupId,
      );

  @override
  void restoreState(Object state) {
    final s = state as ({
      double x,
      double y,
      double scale,
      double opacity,
      String? label,
      String? color,
      String? icon,
      bool showState,
      bool showAge,
      String? group,
    });
    _x = s.x;
    _y = s.y;
    _scale = s.scale;
    _opacity = s.opacity;
    labelText = s.label;
    colorHex = s.color;
    iconKey = s.icon;
    showState = s.showState;
    showAge = s.showAge;
    _groupId = s.group;
  }
}

/// One or more of an edit session's badge placements failed to save. The
/// session's edit is still ended (items are gone from the editor either
/// way); the host should surface this so the operator knows to retry.
class HaOverlaySaveException implements Exception {
  HaOverlaySaveException(this.failures);

  /// link id -> the error that occurred saving/clearing its placement.
  final Map<String, Object> failures;

  @override
  String toString() =>
      'Failed to save ${failures.length} HA badge placement(s): '
      '${failures.keys.join(', ')}';
}

class HaOverlayController {
  HaOverlayController({required CrumbApi api, required Session session})
    : _api = api,
      _session = session,
      editor = OverlayEditorController();

  final CrumbApi _api;
  Session _session;

  /// The generic editor session this adapter drives — pass this to
  /// `OverlayEditorLayer`/`OverlayEditorBar` while editing this camera.
  final OverlayEditorController editor;

  void updateSession(Session session) => _session = session;

  String? _cameraId;

  /// The camera's full linked-entity set (for the palette), refreshed by
  /// [loadLinks]. Includes both placed and unplaced links.
  List<HaLink> links = const [];
  bool loading = false;
  Object? loadError;

  /// Fetch the camera's HA links. Call BEFORE [beginEditFromLoadedLinks] —
  /// see the class doc for the required session-token race guard.
  Future<List<HaLink>> loadLinks(String cameraId) async {
    loading = true;
    loadError = null;
    try {
      final loaded = await _api.cameraHaLinks(_session, cameraId);
      _cameraId = cameraId;
      links = loaded;
      return loaded;
    } catch (e) {
      loadError = e;
      rethrow;
    } finally {
      loading = false;
    }
  }

  /// Begin the shared editor's edit session from the already-loaded [links]
  /// (call once [loadLinks] has resolved and the caller has verified
  /// `editor.editToken` is still current). Only PLACED links become overlay
  /// items; the rest are pick-from-palette candidates.
  void beginEditFromLoadedLinks() {
    final items = [
      for (final link in links)
        if (link.hasPlacement) HaOverlayBadgeItem(link),
    ];
    editor.beginEdit(items, anchor: OverlayAnchor.videoFrame);
  }

  /// Pick a linked entity from the palette: places it (frame-center default)
  /// if it isn't already in the session, or just selects it if it is —
  /// mirrors `PtzPanelController.addButton`'s "add and select" UX.
  void pickFromPalette(HaLink link) {
    for (final item in editor.items) {
      if (item.id == link.id) {
        editor.selectItem(link.id);
        return;
      }
    }
    editor.addItem(HaOverlayBadgeItem(link, x: 0.46, y: 0.46));
  }

  /// Ids of links currently placed in this edit session — drives the
  /// palette's "placed" checkmark (`HaEntityPalette.placedIds`).
  Set<String> get placedIdsInSession => {for (final i in editor.items) i.id};

  /// End the edit session and persist: PUT a placement for every item still
  /// in the session, and CLEAR the placement for every previously-placed
  /// link no longer present (deleted on-canvas). Best-effort per item — one
  /// failed request doesn't block the others; throws
  /// [HaOverlaySaveException] afterward if any failed, so the host can
  /// surface a retry prompt.
  Future<void> endEditAndSave() async {
    final cameraId = _cameraId;
    final result = editor.endEdit();
    if (cameraId == null) return; // never loaded — nothing to persist against

    final keepIds = {for (final i in result) i.id};
    final failures = <String, Object>{};

    for (final item in result) {
      if (item is! HaOverlayBadgeItem) continue;
      try {
        // Label rides the placement PUT only when the session actually
        // changed it: null = leave the link's label untouched, '' = clear
        // (the `PUT /config/ha` token convention).
        final oldLabel = (item.link.label ?? '').trim();
        final newLabel = (item.labelText ?? '').trim();
        await _api.saveHaPlacement(
          _session,
          cameraId,
          item.id,
          x: item.x,
          y: item.y,
          size: item.scale,
          color: item.colorHex,
          icon: item.iconKey,
          showState: item.showState,
          showAge: item.showAge,
          opacity: item.opacity,
          label: newLabel == oldLabel ? null : newLabel,
        );
      } catch (e) {
        failures[item.id] = e;
      }
    }
    for (final link in links) {
      if (link.hasPlacement && !keepIds.contains(link.id)) {
        try {
          await _api.clearHaPlacement(_session, cameraId, link.id);
        } catch (e) {
          failures[link.id] = e;
        }
      }
    }
    if (failures.isNotEmpty) throw HaOverlaySaveException(failures);
  }

  void dispose() => editor.dispose();
}
