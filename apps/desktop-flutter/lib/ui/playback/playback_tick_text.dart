// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Text that follows a fast-changing listenable (the Playback timeline's
// playhead, which moves every 100 ms while playing and at pointer rate while
// dragging) by rebuilding ONLY itself.
//
// PlaybackScreen used to setState on every timeline notification just to
// refresh the transport bar's clock label, which rebuilt the whole screen,
// including every pane's Video widget, 10 times a second. The label now
// listens to the timeline on its own; see playback_screen.dart.

import 'package:flutter/widgets.dart';

/// A [Text] whose string is recomputed from [text] whenever [listenable]
/// notifies. Nothing above it rebuilds.
class PlaybackTickText extends StatelessWidget {
  const PlaybackTickText({
    super.key,
    required this.listenable,
    required this.text,
    this.style,
    this.maxLines,
    this.overflow,
  });

  final Listenable listenable;
  final String Function() text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) =>
          Text(text(), style: style, maxLines: maxLines, overflow: overflow),
    );
  }
}
