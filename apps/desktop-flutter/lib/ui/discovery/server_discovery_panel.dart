// "Find my server" panel for the login screen: scans the LAN for Crumb
// servers and lets the user pick or paste a custom range. Ported from the
// old client's `loginDiscover` (apps/desktop/src/app.js:3795) — one hit
// autofills the server field, multiple hits show a pick list, none reveals a
// subnet field (prefilled with this machine's /24) for rescanning a
// neighbouring VLAN.
//
// Self-contained: this widget does not read or write [TextEditingController]s
// belonging to the login form directly — it reports the chosen URL via
// [onServerSelected] so the host screen decides what to do with it (fill a
// field, auto-focus the username field, etc). See lib/api/discovery_api.dart
// for the underlying scan.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/discovery_api.dart';

class ServerDiscoveryPanel extends StatefulWidget {
  const ServerDiscoveryPanel({
    super.key,
    required this.api,
    required this.onServerSelected,
  });

  final CrumbApi api;

  /// Called when the user picks a discovered server (single-hit autofill or
  /// a pick-list tap). The host screen should put this into its server field.
  final void Function(String url) onServerSelected;

  @override
  State<ServerDiscoveryPanel> createState() => _ServerDiscoveryPanelState();
}

class _ServerDiscoveryPanelState extends State<ServerDiscoveryPanel> {
  final _subnet = TextEditingController();

  bool _discovering = false;
  String? _message;
  List<DiscoveredServer> _found = const [];
  bool _showSubnetField = false;

  @override
  void dispose() {
    _subnet.dispose();
    super.dispose();
  }

  Future<void> _discover(String? range) async {
    if (_discovering) return;
    setState(() {
      _discovering = true;
      _message = 'Scanning…';
      _found = const [];
    });
    try {
      // port: null → the default candidate set (http:8080 + https:8443), so
      // a TLS-only or dual-exposed server is found, not just plain :8080.
      final found = await widget.api.discoverServers(range: range);
      if (!mounted) return;
      if (found.isEmpty) {
        setState(() {
          _message = (range != null && range.isNotEmpty)
              ? 'No server on $range.'
              : 'No server on this network — try another subnet:';
          _showSubnetField = true;
        });
        if (_subnet.text.isEmpty) {
          final cidr = await widget.api.localSubnetCidr();
          if (mounted && cidr != null) setState(() => _subnet.text = cidr);
        }
      } else if (found.length == 1) {
        widget.onServerSelected(found[0].url);
        setState(() {
          _message = 'Found ${found[0].url}';
          _found = const [];
        });
      } else {
        setState(() {
          _message = 'Found ${found.length} servers — pick one:';
          _found = found;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = 'Scan failed: ${e is CrumbApiException ? e.message : e}';
        });
      }
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  void _pick(DiscoveredServer s) {
    widget.onServerSelected(s.url);
    setState(() {
      _found = const [];
      _message = 'Using ${s.url}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _discovering ? null : () => _discover(null),
          icon: _discovering
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_find, size: 18),
          label: const Text('Find my server'),
        ),
        if (_message != null) ...[
          const SizedBox(height: 8),
          Text(
            _message!,
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
        if (_found.length > 1) ...[
          const SizedBox(height: 4),
          ..._found.map(
            (s) => Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton(
                onPressed: () => _pick(s),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                ),
                child: Text(
                  s.version != null ? '${s.url}  ·  v${s.version}' : s.url,
                ),
              ),
            ),
          ),
        ],
        if (_showSubnetField) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _subnet,
                  enabled: !_discovering,
                  decoration: const InputDecoration(
                    // Placeholder uses the RFC 5737 TEST-NET-1 documentation
                    // range, not a real LAN address.
                    labelText: 'Subnet',
                    hintText: 'e.g. 198.51.100.0/24 or 198.51.100.1-50',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (v) => _discover(v),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _discovering ? null : () => _discover(_subnet.text),
                child: const Text('Scan'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
