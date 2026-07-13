// Settings → About panel: client + server versions and an always-present
// Updates status field with a manual "Check now" button. Ported from
// app.js's `updRender` (the `#srv-app-version` / `#srv-update-field-row` /
// `#srv-update-check-btn` block) and `onUpdateCheckNow`.
//
// Mount this wherever the desktop client's settings/about screen lives (there
// is no such screen in this app yet — see this feature's integration notes
// for how to wire it in). Calls `controller.enterAbout()` once on first
// build, mirroring `updEnterAbout()` firing when the old client's Settings →
// This Computer panel is opened — this is how a client that first checked
// while the server had the feature OFF discovers it was later turned on.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_check_controller.dart';

class AboutPanel extends StatefulWidget {
  const AboutPanel({super.key, required this.controller});

  final UpdateCheckController controller;

  @override
  State<AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<AboutPanel> {
  @override
  void initState() {
    super.initState();
    widget.controller.enterAbout();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final ownVersion = c.ownVersion;
        final versionText = ownVersion != null ? 'v$ownVersion' : 'unknown (dev build)';

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('About', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              _row('App version', versionText),
              if (c.data?.serverVersion != null)
                _row('Server version', 'v${c.data!.serverVersion}'),
              if (c.enabled) ...[
                const SizedBox(height: 8),
                _updatesRow(context, c, ownVersion),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: const TextStyle(color: Colors.grey)),
        ),
        Text(value),
      ],
    ),
  );

  Widget _updatesRow(
    BuildContext context,
    UpdateCheckController c,
    String? ownVersion,
  ) {
    final data = c.data;
    String msg;
    String linkUrl = '';
    final ownKnown = parseVersion(ownVersion) != null;

    if (c.checking) {
      msg = 'Checking…';
    } else if (data == null) {
      msg = 'Latest version unknown';
    } else if (c.updateAvailable) {
      msg = 'Update available: v${data.latestVersion}';
      linkUrl = data.notesUrl ?? '';
    } else if (data.latestVersion != null && ownKnown) {
      msg = "You're up to date (v${data.latestVersion})";
    } else if (data.latestVersion != null) {
      // Own version unparsable (dev build): no up-to-date/behind claim, just
      // report the latest.
      msg = 'Latest release: v${data.latestVersion}';
    } else {
      // Enabled, but the server has no successful GitHub fetch yet.
      msg = 'Latest version unknown';
    }

    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text('Updates', style: TextStyle(color: Colors.grey.shade400)),
        ),
        Expanded(
          child: Row(
            children: [
              Flexible(child: Text(msg)),
              if (linkUrl.isNotEmpty) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse(linkUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('Release notes'),
                ),
              ],
            ],
          ),
        ),
        TextButton(
          onPressed: c.checking ? null : () => c.checkNow(),
          child: const Text('Check now'),
        ),
      ],
    );
  }
}
