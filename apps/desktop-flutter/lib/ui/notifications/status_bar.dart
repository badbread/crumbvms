// Bottom status bar widget: message line + current-view label, driven by
// [StatusBarController]. Visual counterpart to app.js's status bar DOM
// (`els.statusText`, see app.js:1525-1610 for example call sites like
// `"${state.cameras.length} cameras • ${currentViewLabel()} • N panes live"`).
//
// Feature screens don't need to render this themselves — wrap the wall/main
// screen's Scaffold body with [StatusBar] once near the app root (see the
// integration notes returned with this feature) and every `setStatus(...)`/
// `setViewLabel(...)` call from anywhere in the tree updates it.

import 'package:flutter/material.dart';

import 'status_bar_controller.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.controller, this.leading});

  final StatusBarController controller;

  /// Optional widget that takes the left side of the bar in place of the plain
  /// [StatusBarController.message] text — e.g. the Playback tab's camera-color
  /// legend + timeline hints, so those live in this one gray bar rather than an
  /// extra strip. Null → show the message text as usual.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: theme.colorScheme.surfaceContainerHighest,
          child: Row(
            children: [
              // A screen-provided widget (e.g. the Playback legend + hints)
              // takes the left side in place of the plain message text, so it
              // lives in this one gray bar rather than an extra strip above.
              Expanded(
                child: leading ??
                    Text(
                      controller.message,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
              ),
              if (controller.viewLabel.isNotEmpty) ...[
                const SizedBox(width: 12),
                Text(
                  controller.viewLabel,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Wraps [child] in a Column with a [StatusBar] pinned to the bottom. Handy
/// as a drop-in `body:` for a Scaffold that wants the status bar without
/// hand-writing the Column each time.
class StatusBarScaffoldBody extends StatelessWidget {
  const StatusBarScaffoldBody({
    super.key,
    required this.controller,
    required this.child,
  });

  final StatusBarController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: child),
        StatusBar(controller: controller),
      ],
    );
  }
}
