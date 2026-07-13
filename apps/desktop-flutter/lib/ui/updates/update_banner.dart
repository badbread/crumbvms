// Dismissible proactive "update available" banner. Ported from app.js's
// `updRender` banner block (`#srv-update-banner` / `#srv-update-text` /
// `#srv-update-link`) and `onUpdateDismiss`. Shown only while an update is
// available and this version hasn't been dismissed yet (per-version, not
// permanent — a newer release re-shows it).
//
// Usage: place at the top of a long-lived screen (e.g. the app shell), same
// spot as RecordingAlertBanner:
//   Column(children: [
//     UpdateBanner(controller: _updateCheck),
//     RecordingAlertBanner(controller: _recordingAlerts),
//     Expanded(child: WallScreen(...)),
//   ])

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_check_controller.dart';

class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.controller});

  final UpdateCheckController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.showBanner) return const SizedBox.shrink();
        final data = controller.data!;
        final notesUrl = data.notesUrl;

        return Material(
          color: const Color(0xFF17384D),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.system_update_alt,
                  color: Color(0xFF7FD1FF),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Update available: v${data.latestVersion}',
                    style: const TextStyle(color: Color(0xFFD9EEFF), fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (notesUrl != null && notesUrl.isNotEmpty)
                  TextButton(
                    onPressed: () => unawaited(
                      launchUrl(Uri.parse(notesUrl), mode: LaunchMode.externalApplication),
                    ),
                    child: const Text('Release notes'),
                  ),
                IconButton(
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close, size: 18, color: Color(0xFFD9EEFF)),
                  onPressed: () => unawaited(controller.dismiss()),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
