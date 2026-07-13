// Shared auto-dismissing top-right toast host, ported from the old client's
// `showToast`/`getToastHost` (apps/desktop/src/app.js:4177-4218). The old
// client pinned toasts to the top-right header zone because that band (top
// bar + toolbar) has no native video panes drawn over it — a toast placed
// anywhere over the tile grid would be hidden behind the panes. The same
// reasoning applies here: mpv panes render via a platform texture that can
// occlude ordinary widgets, so toasts stay in the chrome band, never over
// the wall.
//
// This is the FEATURE-AGNOSTIC toast primitive: snapshot, export, saved
// views, and generic error surfacing should all call `AppToast.show(...)`
// rather than rolling their own overlay. (The existing
// `lib/ui/snapshot/snapshot_toast.dart` predates this shared version and
// still works standalone — new call sites should prefer this one; folding
// SnapshotToast into a thin wrapper over AppToast is a good follow-up but is
// out of scope here since this task may only add new files.)
//
// Usage (imperative, no wrapping required — any BuildContext under a
// MaterialApp/Navigator has an Overlay ancestor):
//
//   AppToast.show(context, icon: '📸', title: 'Snapshot saved', detail: name,
//       detailTooltip: '$path\nClick to show in folder', onDetail: () {...});
//
//   AppToast.show(context, icon: '⚠', title: 'Snapshot failed',
//       detail: '$error', timeout: const Duration(seconds: 8));

import 'dart:async';

import 'package:flutter/material.dart';

class AppToast {
  AppToast._();

  /// Shows one toast. Multiple calls stack (newest on top, mirrors the old
  /// client's toast host which flowed new toasts in via `gap: 8px` column),
  /// each with its own independent auto-dismiss timer.
  ///
  /// [icon] is prefixed to the title (e.g. '📸', '⚠', '✅') — matches the old
  /// client's `(icon ? icon + ' ' : '') + title` convention.
  /// [detail] is an optional secondary line; if [onDetail] is provided the
  /// detail line becomes clickable (closes the toast after firing), matching
  /// app.js's `toast-link` behavior (e.g. "click to show in folder").
  /// [detailTooltip] shows on hover, e.g. a full file path.
  /// [timeout] is the auto-dismiss delay; default 6s matches app.js's
  /// `timeoutMs = 6000` default (snapshot-failed style calls pass 8s).
  static OverlayEntry? show(
    BuildContext context, {
    String? icon,
    required String title,
    String? detail,
    String? detailTooltip,
    VoidCallback? onDetail,
    Duration timeout = const Duration(seconds: 6),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return null;

    late OverlayEntry entry;
    Timer? timer;
    final visible = ValueNotifier<bool>(true);

    void close() {
      timer?.cancel();
      if (!visible.value) return;
      visible.value = false;
      // Let the fade-out play before removing the entry (app.js: 200ms
      // `toast-out` transition before `el.remove()`).
      Timer(const Duration(milliseconds: 200), () {
        entry.remove();
        visible.dispose();
      });
    }

    void arm() {
      timer?.cancel();
      timer = Timer(timeout, close);
    }

    entry = OverlayEntry(
      builder: (context) {
        return _ToastPositioner(
          child: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (context, isVisible, _) {
              return AnimatedOpacity(
                opacity: isVisible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: MouseRegion(
                  // Pause auto-dismiss while hovered so a clickable detail
                  // line stays reachable (app.js: mouseenter/mouseleave).
                  onEnter: (_) => timer?.cancel(),
                  onExit: (_) => arm(),
                  child: _ToastCard(
                    icon: icon,
                    title: title,
                    detail: detail,
                    detailTooltip: detailTooltip,
                    onDetail: onDetail == null
                        ? null
                        : () {
                            onDetail();
                            close();
                          },
                    onDismiss: close,
                  ),
                ),
              );
            },
          ),
        );
      },
    );

    overlay.insert(entry);
    arm();
    return entry;
  }

  /// Convenience wrapper for the common success case.
  static void success(
    BuildContext context, {
    required String title,
    String? detail,
    String? detailTooltip,
    VoidCallback? onDetail,
    Duration timeout = const Duration(seconds: 6),
  }) => show(
    context,
    icon: '✅',
    title: title,
    detail: detail,
    detailTooltip: detailTooltip,
    onDetail: onDetail,
    timeout: timeout,
  );

  /// Convenience wrapper for the common error case (longer default timeout,
  /// matches app.js's snapshot-failed toast using 8s instead of the 6s
  /// default).
  static void error(
    BuildContext context, {
    required String title,
    String? detail,
    Duration timeout = const Duration(seconds: 8),
  }) => show(
    context,
    icon: '⚠',
    title: title,
    detail: detail,
    timeout: timeout,
  );
}

/// Stacks toasts in the top-right corner, clear of a title/menu bar.
class _ToastPositioner extends StatelessWidget {
  const _ToastPositioner({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      right: 12,
      child: SafeArea(
        child: Align(alignment: Alignment.topRight, child: child),
      ),
    );
  }
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({
    required this.icon,
    required this.title,
    required this.detail,
    required this.detailTooltip,
    required this.onDetail,
    required this.onDismiss,
  });

  final String? icon;
  final String title;
  final String? detail;
  final String? detailTooltip;
  final VoidCallback? onDetail;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Container(
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 340),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.colorScheme.primary, width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    icon == null ? title : '$icon $title',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Dismiss',
                  waitDuration: const Duration(milliseconds: 400),
                  child: InkWell(
                    onTap: onDismiss,
                    borderRadius: BorderRadius.circular(12),
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.close, size: 16),
                    ),
                  ),
                ),
              ],
            ),
            if (detail != null) ...[
              const SizedBox(height: 3),
              Tooltip(
                message: detailTooltip ?? '',
                waitDuration: const Duration(milliseconds: 400),
                child: InkWell(
                  onTap: onDetail,
                  child: Text(
                    detail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: onDetail == null
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.primary,
                      decoration: onDetail == null
                          ? null
                          : TextDecoration.underline,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
