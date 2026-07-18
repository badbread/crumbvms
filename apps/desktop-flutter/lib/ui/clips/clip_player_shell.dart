// Shared lightbox scaffold for the pop-up clip players — the Clips tab's
// _ClipPlayer and the Plates tab's _PlateClipPlayer both render through this
// ONE widget so their chrome behaves identically:
//
//  * a tap on the dimmed backdrop AROUND the video closes the overlay
//    (standard lightbox behavior; Esc and the top-right X still close too —
//    Esc stays owned by each player's HardwareKeyboard handler),
//  * the primary action buttons sit in a row BENEATH the video and transport,
//    so the whole control cluster is together instead of floating top-right,
//  * the title bar keeps only the context label and the close X.
//
// Regions that must NOT dismiss when clicked — the title bar, the video pane,
// the transport, the actions row — absorb their own taps; everything else
// falls through to the backdrop's close handler. Callers should size the
// [video] widget to the video's real display rect (fitted pane / AspectRatio)
// where possible, so the visually-dark area around the picture is genuine
// tappable backdrop rather than letterbox inside an oversized video box.

import 'package:flutter/material.dart';

class ClipPlayerShell extends StatelessWidget {
  const ClipPlayerShell({
    super.key,
    required this.title,
    required this.onClose,
    required this.video,
    this.titleStyle,
    this.header,
    this.transport,
    this.actions = const [],
    this.overlays = const [],
  });

  /// Title text shown top-left (e.g. "Person — Driveway" / plate — camera).
  final String title;

  /// Style override for [title]; defaults to the players' shared white 15/600.
  final TextStyle? titleStyle;

  /// Closes the overlay — wired to the X button AND a tap on the backdrop.
  final VoidCallback onClose;

  /// The video pane (already sized/fitted by the caller). Its taps are
  /// absorbed so only the dark area around it dismisses.
  final Widget video;

  /// Optional strip between the title bar and the video (the plate crop).
  final Widget? header;

  /// Optional transport bar rendered directly under the video.
  final Widget? transport;

  /// Action buttons rendered in a centered row under the transport (quality
  /// toggle, report, snapshot, bookmark, view-on-timeline, …).
  final List<Widget> actions;

  /// Extra positioned widgets stacked over everything (e.g. a toast).
  final List<Widget> overlays;

  /// Swallow taps so a click on real content never reaches the backdrop's
  /// close handler (opaque: even the gaps between buttons stay safe).
  Widget _absorb(Widget child) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.92),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onClose,
        child: Stack(
          children: [
            Column(
              children: [
                // Title bar: label + close X only; actions live below the video.
                _absorb(
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: titleStyle ??
                                const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close (Esc)',
                          onPressed: onClose,
                          icon: const Icon(Icons.close,
                              color: Colors.white70, size: 22),
                        ),
                      ],
                    ),
                  ),
                ),
                if (header != null) _absorb(header!),
                Expanded(child: Center(child: _absorb(video))),
                if (transport != null) _absorb(transport!),
                if (actions.isNotEmpty)
                  _absorb(
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      // Full-width so the tap-absorbing strip spans the row —
                      // a near-miss beside a button must not dismiss.
                      child: SizedBox(
                        width: double.infinity,
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: actions,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
              ],
            ),
            ...overlays,
          ],
        ),
      ),
    );
  }
}
