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

import 'package:flutter/painting.dart';

import '../../api/crumb_api.dart';
import '../../api/ha_api.dart';
import '../../api/ha_models.dart';
import '../../api/models.dart';
import '../overlay_editor/overlay_editor_controller.dart';
import '../overlay_editor/overlay_item.dart';
import 'ha_overlay_layer.dart' show HaPillMetrics, haPillWidthFactor;

/// [OverlayItem] adapter over a placed [HaLink] — video-frame anchored,
/// always-square badge, resized via the editor bar's size stepper only (no
/// on-canvas drag-resize handle; see [resizable]).
///
/// Also carries the badge's editable per-badge style (migration 0059) —
/// [labelText], [colorHex], [iconKey], [showState], [showAge] — seeded from
/// the link and mutated in-session by the badge popover
/// (`ha_badge_popover.dart`); persisted by
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
      showAge = link.overlayShowAge,
      shape = link.overlayShape,
      bgColorHex = link.overlayBgColor,
      bgColorOnHex = link.overlayBgColorOn,
      pillWidthMode = link.overlayPillWidth,
      textAlign = link.overlayTextAlign,
      outline = link.overlayOutline;

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

  /// Badge shape (migration 0062): `'dot'` (compact icon) or `'pill'`
  /// (labelled); null = the default dot.
  String? shape;

  /// Solid background '#RRGGBB' override, or null for the default dark
  /// background (migration 0062).
  String? bgColorHex;

  /// Per-state background override (wave A): the badge background while the
  /// entity reads ON, or null to follow [bgColorHex] in every state. Edited
  /// by the badge popover's paired Off/On background swatches
  /// (`ha_badge_popover.dart`); see `ha_overlay_layer.dart`'s
  /// `resolveBadgeBg` for the exact resolution order.
  String? bgColorOnHex;

  /// Pill WIDTH mode (migration 0078, issue #497): `'auto'`, `'narrow'`,
  /// `'medium'` or `'wide'`; null = `'auto'`, the hug-the-content width. Only
  /// a pill uses it — see [baseSize] and `ha_overlay_layer.dart`'s
  /// `haPillWidthFactor`.
  String? pillWidthMode;

  /// Where the pill's icon + label group sits (migration 0078, issue #497):
  /// `'start'` (or null), `'center'`, `'end'`. Rendered by
  /// `ha_overlay_layer.dart`'s `haPillAlignment`.
  String? textAlign;

  /// White outline + drop shadow so the badge pops on a busy scene.
  bool outline;

  /// True when this badge renders as a labelled pill (vs the compact dot).
  bool get isPill => shape == 'pill';

  /// Display caption honoring the in-session edit (mirrors
  /// `HaLink.displayLabel`, against [labelText] instead of `link.label`).
  String get displayLabel =>
      (labelText != null && labelText!.trim().isNotEmpty)
          ? labelText!
          : link.entityId;

  /// The text shown INSIDE a pill: the operator caption if set, else the
  /// entity id minus its domain prefix (`binary_sensor.front_door` ->
  /// `front_door`) — tidier than the raw id in a small chip. State is carried
  /// by the icon color, not this text, so the pill width stays stable as the
  /// entity changes.
  String get pillLabel {
    final t = labelText?.trim();
    if (t != null && t.isNotEmpty) return t;
    final id = link.entityId;
    final dot = id.indexOf('.');
    return dot < 0 ? id : id.substring(dot + 1);
  }

  /// Reset every STYLE field to its default in one shot (the badge popover's
  /// "Reset style" footer): icon, accent color, BOTH backgrounds, shape,
  /// opacity, outline and the two pinned captions. Deliberately KEEPS the
  /// badge's position, size and operator label — a style reset is not a
  /// "start over", and re-placing/re-labelling a badge by hand is exactly the
  /// work an operator would not want undone. Pure mutation: the caller pushes
  /// the single undo entry (`OverlayEditorController.pushUndo`) and notifies,
  /// per the editor's host-side style-edit contract.
  void resetStyle() {
    iconKey = null;
    colorHex = null;
    bgColorHex = null;
    bgColorOnHex = null;
    pillWidthMode = null;
    textAlign = null;
    shape = null;
    _opacity = 1.0;
    outline = false;
    showState = false;
    showAge = false;
  }

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

  /// Size in ITEM space (pane-scale 1.0), per [OverlayItem.baseSize].
  ///
  /// INVARIANT (the reason [renderedSize] exists): `baseSize()` is exactly
  /// `renderedSize(1.0)`, and for an `auto` pill that is the ONLY pane scale at
  /// which the two agree — the chip's metrics clamp, so its content width is
  /// not linear in its height and `baseSize().w * paneScale` is not the width
  /// the pill needs on screen. Anything that positions or hit-tests a badge
  /// must go through `OverlayGeometry.rectFor`, which asks [renderedSize].
  /// Item-space consumers (the editor bar's width readout, `setBaseSize`'s
  /// scale round-trip, group/align math) keep working against this one
  /// unchanged: the HEIGHT, which is what a badge's size actually means, is
  /// still `baseRefPx * scale` in both shapes.
  @override
  (double w, double h) baseSize() => _sizeForHeight(baseRefPx * _scale);

  /// Size in RENDERED px at [paneScale] — the pill's width measured at the
  /// height it will actually be drawn at, so the box hugs the content the chip
  /// draws into it at EVERY size (see [HaPillMetrics] for the clamps that make
  /// this non-linear, and the truncation/dead-space bug it fixes).
  @override
  (double w, double h) renderedSize(double paneScale) =>
      _sizeForHeight(baseRefPx * _scale * paneScale);

  (double w, double h) _sizeForHeight(double h) {
    if (!isPill) return (h, h);
    return (pillWidthAtHeight(pillLabel, h, widthMode: pillWidthMode), h);
  }

  /// The pill's width at a pill HEIGHT of [height] px: exactly what its content
  /// occupies at that height — the icon, both horizontal paddings, the
  /// icon/label gap, and the MEASURED width of the label at the font size the
  /// chip actually uses. Every part comes from [HaPillMetrics], the same object
  /// `HaBadgeChip._pill` lays itself out from, so the measurement and the
  /// render cannot drift.
  ///
  /// Two bugs live in getting this wrong. It used to be a character-count
  /// estimate (`chars * baseRefPx * 0.42`) that ran far wide of the real text,
  /// leaving a stretch of empty pill after a short label. Measuring fixed that
  /// but measured at the REFERENCE height and scaled the result linearly, which
  /// ignores the chip's clamps: on a small wall tile the floors (8px font, 10px
  /// icon, 5px padding, 3px gap) make the content wider than the linearly
  /// scaled box, and `TextOverflow.ellipsis` chopped "Floodlight" to
  /// "Floodli…". Passing the height the pill is really drawn at is what makes
  /// `auto` hug its content on a 2x pane and a thumbnail tile alike.
  ///
  /// Nothing here consults the PINNED CAPTIONS: `HaBadgeCaptions` centres its
  /// own chip on the badge and is free to be wider or narrower, so a long
  /// "5 h ago" line never stretches the pill.
  static double pillWidthAtHeight(
    String label,
    double height, {
    String? widthMode,
  }) {
    // A fixed width mode (migration 0078) short-circuits the measurement: the
    // pill is EXACTLY that multiple of its height, so a set of badges given the
    // same mode line up down a door frame. A label too long for it ellipsizes
    // in `HaBadgeChip._pill`, exactly as an over-long auto label already does.
    final factor = haPillWidthFactor(widthMode);
    if (factor != null) return height * factor;
    return HaPillMetrics.forHeight(height)
        .contentWidth(labelWidthPerFontPx(label));
  }

  /// Width of `label` per 1px of font size, for the chip's text style. Text
  /// advance scales linearly with font size, so measuring once at a large
  /// probe and dividing is both stable and more precise than laying out at the
  /// chip's actual ~9px — and it is exactly what lets one measurement serve
  /// every rendered height. Memoised: `baseSize()`/`renderedSize()` run for
  /// every item on every drag tick, and a `TextPainter.layout()` per call would
  /// be a real cost.
  static final Map<String, double> _labelWidthCache = {};

  static double labelWidthPerFontPx(String label) {
    final hit = _labelWidthCache[label];
    if (hit != null) return hit;
    const probe = 100.0;
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          fontSize: probe,
          fontWeight: FontWeight.w600,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final perPx = painter.width / probe;
    painter.dispose();
    // Bounded so a pathological session can't grow this without limit; badge
    // labels are few and long-lived.
    if (_labelWidthCache.length > 512) _labelWidthCache.clear();
    _labelWidthCache[label] = perPx;
    return perPx;
  }

  @override
  void setBaseSize(double w, double h) {
    // Derive scale from HEIGHT — the shape-invariant. A pill's baseSize width
    // is wider than tall, so using max(w,h) made every resize multiply the
    // scale by the pill's width factor and balloon the badge (and the dot
    // after switching back). Height is baseRefPx*scale for both shapes.
    _scale = (h / baseRefPx).clamp(0.1, 8.0).toDouble();
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
        shape: shape,
        bgColor: bgColorHex,
        bgColorOn: bgColorOnHex,
        pillWidth: pillWidthMode,
        textAlign: textAlign,
        outline: outline,
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
      String? shape,
      String? bgColor,
      String? bgColorOn,
      String? pillWidth,
      String? textAlign,
      bool outline,
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
    shape = s.shape;
    bgColorHex = s.bgColor;
    bgColorOnHex = s.bgColorOn;
    pillWidthMode = s.pillWidth;
    textAlign = s.textAlign;
    outline = s.outline;
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

  /// EDIT-SESSION-ONLY state preview (the top bar's Live | On | Off segmented
  /// control). `null` = Live: every badge renders its real state. `true`/
  /// `false` force every badge to render as if its entity read on/off, so the
  /// operator can see the colors they are editing — in particular the paired
  /// Off/On background swatches, which are otherwise invisible until the real
  /// device happens to change state.
  ///
  /// This does NOT violate the state-honesty rule (never show a possibly-false
  /// reading): it is an explicit, operator-driven preview on an EDITING
  /// surface, labelled as such by the segmented control, and it is reset on
  /// every `beginEdit`/`endEdit` so no viewing surface can ever inherit it.
  /// `ha_overlay_layer.dart`'s `haPreviewedState`/`haPreviewedStale` apply it,
  /// and only the edit-mode render path passes it in.
  bool? _previewState;

  bool? get previewState => _previewState;

  /// Set the preview and repaint the live badges. Routed through the editor's
  /// structure notification (not a listenable of its own) so the badge layer,
  /// the captions and the popover — all of which already rebuild on it —
  /// pick the change up in the same frame.
  set previewState(bool? v) {
    if (_previewState == v) return;
    _previewState = v;
    editor.notifyItemsChanged();
  }

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
    _previewState = null; // every session starts on Live
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
  /// Abandon the edit session WITHOUT persisting anything (the top bar's X /
  /// Esc → "Discard"). Safe by construction: the editor never touches storage
  /// during a session (`overlay_editor_controller.dart`'s lifecycle contract),
  /// so every drag, style tweak and placement made since `beginEdit` lives
  /// only in the in-memory items being dropped here — there is nothing to roll
  /// back server-side.
  void cancelEdit() {
    if (!editor.editMode) return;
    _previewState = null;
    editor.endEdit();
  }

  Future<void> endEditAndSave() async {
    final cameraId = _cameraId;
    _previewState = null;
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
          shape: item.shape,
          bgColor: item.bgColorHex,
          bgColorOn: item.bgColorOnHex,
          pillWidth: item.pillWidthMode,
          textAlign: item.textAlign,
          outline: item.outline,
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
