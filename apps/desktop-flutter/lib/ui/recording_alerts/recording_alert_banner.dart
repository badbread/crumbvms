// Persistent recording-health alert banner. Ported from app.js's
// `renderRecordingAlert`'s top-of-page banner element
// (`#recording-alert-banner`) — a thin, always-visible-when-active strip
// showing the count/first warning, amber for warn-only, red once any
// warning is critical. Not user-dismissable (mirrors the old client): it
// clears itself only when `RecordingAlertsController` next polls clean.
//
// Usage: wrap the wall (or any always-on screen) in a `Column` with this at
// the top, e.g.:
//   Column(children: [
//     RecordingAlertBanner(controller: _recordingAlerts),
//     Expanded(child: WallScreen(...)),
//   ])
// See lib/ui/recording_alerts/recording_alerts_controller.dart for the
// polling/computation this renders.

import 'package:flutter/material.dart';

import 'recording_alerts_controller.dart';
import '../../api/recording_alerts_models.dart';

class RecordingAlertBanner extends StatelessWidget {
  const RecordingAlertBanner({super.key, required this.controller});

  final RecordingAlertsController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final warnings = controller.warnings;
        if (warnings.isEmpty) return const SizedBox.shrink();

        final crit = controller.hasCritical;
        final bg = crit ? const Color(0xFF5C1A1A) : const Color(0xFF5C4A14);
        final fg = crit ? const Color(0xFFFFD6D6) : const Color(0xFFFFE9B3);
        final iconColor = crit ? const Color(0xFFFF6B6B) : const Color(0xFFFFC94A);

        final text = warnings.length == 1
            ? warnings.first.text
            : '${warnings.length} recording-storage warnings — ${warnings.first.text}';

        return Material(
          color: bg,
          child: InkWell(
            onTap: () => _showDetail(context, warnings, crit),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    crit ? Icons.error_outline : Icons.warning_amber_rounded,
                    color: iconColor,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(color: fg, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (warnings.length > 1)
                    Text(
                      'Details',
                      style: TextStyle(
                        color: fg,
                        fontSize: 12,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _showDetail(
    BuildContext context,
    List<RecordingWarning> warnings,
    bool crit,
  ) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recording health'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: warnings
                .map(
                  (w) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: RichText(
                      text: TextSpan(
                        style: DefaultTextStyle.of(context).style,
                        children: [
                          TextSpan(
                            text: w.level == RecordingWarningLevel.crit
                                ? 'CRITICAL: '
                                : 'Warning: ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: w.level == RecordingWarningLevel.crit
                                  ? Colors.red.shade300
                                  : Colors.amber.shade300,
                            ),
                          ),
                          TextSpan(text: w.text),
                        ],
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
