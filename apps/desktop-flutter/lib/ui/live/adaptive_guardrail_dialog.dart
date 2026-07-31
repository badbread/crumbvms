// Stage 1 guardrail nudge (issue #382). Shown at the point of a config change
// (wall default -> main, a per-camera -> main) that the adaptive controller
// predicts would over-subscribe this machine's decoder. Advisory only: it
// never blocks the change — the operator picks Keep sub / Proceed anyway /
// Don't warn on this machine.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/state/adaptive_wall.dart';

/// Show the guardrail nudge for [assessment]. Returns the operator's choice, or
/// null if the dialog was dismissed (barrier / Esc) — treat null as "keep sub"
/// at the call site (the safe, no-change outcome).
Future<GuardrailChoice?> showAdaptiveGuardrailDialog(
  BuildContext context, {
  required GuardrailAssessment assessment,
}) {
  final n = assessment.projectedMainCount;
  return showDialog<GuardrailChoice>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        icon: Icon(Icons.speed_outlined, color: scheme.tertiary),
        title: const Text('This wall may exceed decode headroom'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This change would run $n full-res main streams at once, which '
              'may exceed this machine\'s video-decode headroom (dropped frames '
              'or stutter).',
            ),
            const SizedBox(height: 10),
            const Text(
              'Keeping the wall on sub and using zoom-to-main (or maximizing a '
              'tile) plays full quality only on the camera you are looking at.',
            ),
          ],
        ),
        actionsOverflowButtonSpacing: 6,
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(GuardrailChoice.dontWarnOnThisMachine),
            child: const Text("Don't warn on this machine"),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(GuardrailChoice.proceed),
            child: const Text('Proceed anyway'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(GuardrailChoice.keepSub),
            child: const Text('Keep sub'),
          ),
        ],
      );
    },
  );
}
