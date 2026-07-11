// Small auto-dismissing notification pinned to the top-right, ported from the
// old client's `showToast` (apps/desktop/src/app.js:4183). The old client
// pinned toasts there because that band (top bar + toolbar) has no native
// video panes drawn over it; a DOM toast placed anywhere over the tile grid
// would be hidden behind the panes. The same reasoning applies here: mpv
// panes render via a platform texture that can occlude ordinary widgets, so
// this stays in the chrome band, not over the wall.
//
// Usage (imperative, no wrapping required — any BuildContext under a
// MaterialApp/Navigator has an Overlay ancestor):
//
//   SnapshotToast.show(context, icon: '📸', title: 'Snapshot saved', ...);

import 'dart:async';

import 'package:flutter/material.dart';

class SnapshotToast {
  SnapshotToast._();

  /// Shows one toast. Multiple calls stack (newest on top), each with its own
  /// auto-dismiss timer — mirrors the old client's toast host, which allowed
  /// several toasts to be visible at once.
  static void show(
    BuildContext context, {
    String? icon,
    required String title,
    String? detail,
    String? detailTooltip,
    VoidCallback? onDetail,
    Duration timeout = const Duration(seconds: 6),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    late OverlayEntry entry;
    Timer? timer;
    final visible = ValueNotifier<bool>(true);

    void close() {
      timer?.cancel();
      if (!visible.value) return;
      visible.value = false;
      // Let the fade-out play before removing the entry.
      Timer(const Duration(milliseconds: 200), () {
        entry.remove();
        visible.dispose();
      });
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
              );
            },
          ),
        );
      },
    );

    overlay.insert(entry);
    timer = Timer(timeout, close);
  }
}

/// Stacks toasts in the top-right corner, below the title/menu bar.
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
                InkWell(
                  onTap: onDismiss,
                  borderRadius: BorderRadius.circular(12),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.close, size: 16),
                  ),
                ),
              ],
            ),
            if (detail != null) ...[
              const SizedBox(height: 2),
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
