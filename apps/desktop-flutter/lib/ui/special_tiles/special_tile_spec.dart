// Typed specs for the "special" (non-camera) view-item tile types the view
// designer can drop onto a wall slot. Port of the Tauri client's tile-spec
// shapes (apps/desktop/src/app.js: vsDefaultSpec ~1084, vsBuildConfigBody
// ~781, normalizeTileSpec, VS_PALETTE / VS_CONFIGURABLE ~1071-1082).
//
// These decode/encode the SAME jsonb shape the server stores verbatim under
// a saved view's `slots["<slotIndex>"]` (see lib/api/views_api.dart's
// `TileSpec.raw` — that's the untyped "round-trip whatever we don't
// understand" wrapper; this file is the typed layer this feature builds on
// top of it). Two tile types carry LIVE VIDEO (carousel, hotspot) — they
// resolve to a camera id that the host's existing camera-tile widget
// renders, same as a plain `{type:"camera"}` slot. The rest are pure DOM/UI
// tiles with no video pane.

import 'dart:convert';
import 'dart:typed_data';

/// The seven special (non-`camera`) view-item types this feature covers.
enum SpecialTileType {
  carousel,
  hotspot,
  clock,
  text,
  image,
  web,
  events;

  String get wireType => switch (this) {
    SpecialTileType.carousel => 'carousel',
    SpecialTileType.hotspot => 'hotspot',
    SpecialTileType.clock => 'clock',
    SpecialTileType.text => 'text',
    SpecialTileType.image => 'image',
    SpecialTileType.web => 'web',
    SpecialTileType.events => 'events',
  };

  static SpecialTileType? fromWire(String? s) => switch (s) {
    'carousel' => SpecialTileType.carousel,
    'hotspot' => SpecialTileType.hotspot,
    'clock' => SpecialTileType.clock,
    'text' => SpecialTileType.text,
    'image' => SpecialTileType.image,
    'web' => SpecialTileType.web,
    'events' => SpecialTileType.events,
    _ => null,
  };
}

/// Carousel rotate mode (vs-cfg-mode select in app.js).
enum CarouselMode {
  time, // rotate every intervalMs
  motion, // jump to whichever selected camera has motion; hold when quiet
  both; // motion first, else rotate on the timer

  String get wire => name;
  static CarouselMode fromWire(String? s) => switch (s) {
    'motion' => CarouselMode.motion,
    'both' => CarouselMode.both,
    _ => CarouselMode.time,
  };
}

/// Base type for all seven special tile specs. Immutable; config UIs build a
/// new instance and hand it back via `TileSpec._other(type, spec.toJson())`
/// (see lib/api/views_api.dart) to store in the slot map.
sealed class SpecialTileSpec {
  const SpecialTileSpec();

  SpecialTileType get kind;

  Map<String, dynamic> toJson();

  /// `true` for the two types that resolve to a live camera pane (carousel,
  /// hotspot) — mirrors app.js's `VIDEO_TILE_TYPES`. The host only needs to
  /// ask [SpecialTileController] for the resolved camera id for these; the
  /// rest render via [specialTileWidget] with no camera pane underneath.
  bool get isVideoTile => this is CarouselSpec || this is HotspotSpec;

  /// Decode a raw spec object as stored in `slots["<idx>"]` (a `{type:...}`
  /// map — see `TileSpec.raw` / `TileSpec.fromSlotValue` in views_api.dart).
  /// Returns null for `camera`/`ptz` (not covered by this feature) or an
  /// unrecognized type.
  static SpecialTileSpec? fromRaw(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    switch (SpecialTileType.fromWire(raw['type'] as String?)) {
      case SpecialTileType.carousel:
        return CarouselSpec.fromJson(raw);
      case SpecialTileType.hotspot:
        return HotspotSpec.fromJson(raw);
      case SpecialTileType.clock:
        return const ClockSpec();
      case SpecialTileType.text:
        return TextSpec.fromJson(raw);
      case SpecialTileType.image:
        return ImageSpec.fromJson(raw);
      case SpecialTileType.web:
        return WebSpec.fromJson(raw);
      case SpecialTileType.events:
        return const EventsSpec();
      case null:
        return null;
    }
  }

  /// A fresh default spec for a freshly-dropped palette item (vsDefaultSpec).
  /// `allCameraIds` seeds the carousel's camera set (defaults to "all").
  static SpecialTileSpec defaultFor(
    SpecialTileType type, {
    required List<String> allCameraIds,
  }) => switch (type) {
    SpecialTileType.carousel => CarouselSpec(
      cameras: List.of(allCameraIds),
      intervalMs: 8000,
      mode: CarouselMode.time,
    ),
    SpecialTileType.hotspot => const HotspotSpec(cameras: []),
    SpecialTileType.clock => const ClockSpec(),
    SpecialTileType.text => const TextSpec(text: '', size: 28),
    SpecialTileType.image => const ImageSpec(dataUrl: ''),
    SpecialTileType.web => const WebSpec(url: ''),
    SpecialTileType.events => const EventsSpec(),
  };
}

/// Camera carousel: cycles a chosen set of cameras into this slot on a timer,
/// on motion, or both (carouselStartFromSpec in app.js).
class CarouselSpec extends SpecialTileSpec {
  const CarouselSpec({
    required this.cameras,
    required this.intervalMs,
    required this.mode,
  });

  /// Camera ids to cycle. Empty ⇒ falls back to ALL cameras at apply-time
  /// (matches app.js: `let cams = spec.cameras?.length ? spec.cameras : all`).
  final List<String> cameras;

  /// Rotation interval in ms while in `time`/`both` mode. Clamped 2000..120000
  /// (vs-cfg-interval min=2 max=120 seconds).
  final int intervalMs;

  final CarouselMode mode;

  @override
  SpecialTileType get kind => SpecialTileType.carousel;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'carousel',
    'cameras': cameras,
    'intervalMs': intervalMs,
    'mode': mode.wire,
  };

  factory CarouselSpec.fromJson(Map<String, dynamic> j) => CarouselSpec(
    cameras: ((j['cameras'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(growable: false),
    intervalMs: ((j['intervalMs'] as num?)?.toInt() ?? 8000).clamp(
      2000,
      120000,
    ),
    mode: CarouselMode.fromWire(j['mode'] as String?),
  );

  CarouselSpec copyWith({
    List<String>? cameras,
    int? intervalMs,
    CarouselMode? mode,
  }) => CarouselSpec(
    cameras: cameras ?? this.cameras,
    intervalMs: intervalMs ?? this.intervalMs,
    mode: mode ?? this.mode,
  );
}

/// Hotspot: shows either whatever camera was last clicked on the wall
/// ("classic", `cameras` empty) or auto-follows the busiest camera in a
/// configured set ("auto-follow", `cameras` non-empty). See
/// pickHotspotCam / hotspotMotionTick / routeHotspotClick in app.js.
class HotspotSpec extends SpecialTileSpec {
  const HotspotSpec({required this.cameras});

  /// Empty ⇒ classic click-hotspot (shares one global target across all
  /// classic hotspot slots). Non-empty ⇒ auto-follows the camera in this set
  /// with the most recent motion.
  final List<String> cameras;

  bool get isAutoFollow => cameras.isNotEmpty;

  @override
  SpecialTileType get kind => SpecialTileType.hotspot;

  @override
  Map<String, dynamic> toJson() => {'type': 'hotspot', 'cameras': cameras};

  factory HotspotSpec.fromJson(Map<String, dynamic> j) => HotspotSpec(
    cameras: ((j['cameras'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(growable: false),
  );

  HotspotSpec copyWith({List<String>? cameras}) =>
      HotspotSpec(cameras: cameras ?? this.cameras);
}

/// Auto-sizing wall clock (fitClock / startClockTicker in app.js). No config.
class ClockSpec extends SpecialTileSpec {
  const ClockSpec();

  @override
  SpecialTileType get kind => SpecialTileType.clock;

  @override
  Map<String, dynamic> toJson() => {'type': 'clock'};
}

/// Static caption text tile.
class TextSpec extends SpecialTileSpec {
  const TextSpec({required this.text, required this.size});

  final String text;

  /// Font size in px, clamped 10..72 (vs-cfg-size in app.js).
  final double size;

  @override
  SpecialTileType get kind => SpecialTileType.text;

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text, 'size': size};

  factory TextSpec.fromJson(Map<String, dynamic> j) => TextSpec(
    text: (j['text'] as String?) ?? '',
    size: (((j['size'] as num?)?.toDouble()) ?? 28).clamp(10, 72),
  );

  TextSpec copyWith({String? text, double? size}) =>
      TextSpec(text: text ?? this.text, size: size ?? this.size);
}

/// Static image tile. `dataUrl` is a downscaled `data:image/...;base64,...`
/// URI stored inline in the view's jsonb (vsDownscaleImage in app.js — keeps
/// saved views small; this feature's Flutter port downscales via
/// `dart:ui` — see image_tile.dart / image_tile_picker.dart).
class ImageSpec extends SpecialTileSpec {
  const ImageSpec({required this.dataUrl});

  final String dataUrl;

  @override
  SpecialTileType get kind => SpecialTileType.image;

  @override
  Map<String, dynamic> toJson() => {'type': 'image', 'dataUrl': dataUrl};

  factory ImageSpec.fromJson(Map<String, dynamic> j) =>
      ImageSpec(dataUrl: (j['dataUrl'] as String?) ?? '');

  ImageSpec copyWith({String? dataUrl}) =>
      ImageSpec(dataUrl: dataUrl ?? this.dataUrl);

  /// Decoded bytes, or null if `dataUrl` is empty/malformed.
  Uint8List? get bytes {
    if (!dataUrl.startsWith('data:')) return null;
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return null;
    try {
      return base64Decode(dataUrl.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }
}

/// Embedded web page (iframe in app.js; a native webview here — see
/// web_tile.dart's doc comment on the platform dependency this needs).
class WebSpec extends SpecialTileSpec {
  const WebSpec({required this.url});

  final String url;

  @override
  SpecialTileType get kind => SpecialTileType.web;

  @override
  Map<String, dynamic> toJson() => {'type': 'web', 'url': url};

  factory WebSpec.fromJson(Map<String, dynamic> j) =>
      WebSpec(url: ((j['url'] as String?) ?? '').trim());

  WebSpec copyWith({String? url}) => WebSpec(url: url ?? this.url);
}

/// Live detections feed: recent `/events` rows, click-to-jump-to-playback
/// (updateEventTiles / wireEventTile / goToPlaybackEvent in app.js). No
/// config beyond existing.
class EventsSpec extends SpecialTileSpec {
  const EventsSpec();

  @override
  SpecialTileType get kind => SpecialTileType.events;

  @override
  Map<String, dynamic> toJson() => {'type': 'events'};
}

/// Palette metadata for the view-designer's drag source (VS_PALETTE in
/// app.js). Rendering (icon/label) only — the drag/drop mechanics are native
/// Flutter `Draggable`/`DragTarget` on the host screen, unlike app.js's
/// manual pointer-drag workaround for Tauri/WebView2 swallowing HTML5 DnD.
class SpecialTilePaletteItem {
  const SpecialTilePaletteItem(this.type, this.icon, this.label);

  final SpecialTileType type;
  final String icon;
  final String label;

  static const List<SpecialTilePaletteItem> all = [
    SpecialTilePaletteItem(SpecialTileType.carousel, '🔁', 'Carousel'),
    SpecialTilePaletteItem(SpecialTileType.hotspot, '🎯', 'Hotspot'),
    SpecialTilePaletteItem(SpecialTileType.image, '🖼', 'Image'),
    SpecialTilePaletteItem(SpecialTileType.clock, '🕐', 'Clock'),
    SpecialTilePaletteItem(SpecialTileType.text, '🅰', 'Text'),
    SpecialTilePaletteItem(SpecialTileType.events, '🔔', 'Detections'),
    SpecialTilePaletteItem(SpecialTileType.web, '🌐', 'Web'),
  ];
}

/// Types that pop a config panel when dropped/clicked (VS_CONFIGURABLE in
/// app.js — `clock` and `events` have no config, so they're excluded).
const Set<SpecialTileType> kSpecialTileConfigurable = {
  SpecialTileType.carousel,
  SpecialTileType.hotspot,
  SpecialTileType.image,
  SpecialTileType.text,
  SpecialTileType.web,
};
