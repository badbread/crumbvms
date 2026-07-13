// Dispatcher: renders the right widget for a DOM-only special tile spec
// (clock/text/image/web/events). Carousel/hotspot are NOT handled here —
// they resolve to a camera id via `SpecialTileController` and render through
// the host's existing camera-tile widget, same as a plain `{type:"camera"}`
// slot (see special_tile_controller.dart's doc comment).

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';

import 'special_tile_spec.dart';
import 'tiles/clock_tile.dart';
import 'tiles/events_feed_tile.dart' show EventsFeedTile, EventTileTapCallback;
import 'tiles/image_tile.dart';
import 'tiles/text_tile.dart';
import 'tiles/web_tile.dart';

/// Build the widget for one DOM-only special tile. `spec.isVideoTile` must be
/// false — callers should check that first and route video tiles (carousel/
/// hotspot) through the normal camera-pane path instead.
Widget specialTileWidget(
  SpecialTileSpec spec, {
  required CrumbApi api,
  required Session session,
  required List<Camera> cameras,
  EventTileTapCallback? onTapEvent,
}) {
  assert(!spec.isVideoTile, 'carousel/hotspot render via the camera pane, not specialTileWidget');
  return switch (spec) {
    ClockSpec() => const ClockTile(),
    TextSpec s => TextTile(spec: s),
    ImageSpec s => ImageTile(spec: s),
    WebSpec s => WebTile(spec: s),
    EventsSpec() => EventsFeedTile(
      api: api,
      session: session,
      cameras: cameras,
      onTapEvent: onTapEvent,
    ),
    CarouselSpec() || HotspotSpec() =>
      const ColoredBox(color: Colors.black), // unreachable per the assert above
  };
}
