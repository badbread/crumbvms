// Shown at launch while a stored session exists but the server is not
// reachable yet (typically after a power cut). The client keeps retrying the
// stored session in the background and resumes the wall by itself; the button
// is the escape hatch for signing in as a different user or server.

import 'package:flutter/material.dart';

class WaitingForServerScreen extends StatelessWidget {
  const WaitingForServerScreen({
    super.key,
    required this.hostLabel,
    required this.onSignInAsSomeoneElse,
  });

  /// `host:port` of the stored session's server (no scheme, no credentials).
  final String hostLabel;
  final VoidCallback onSignInAsSomeoneElse;

  /// `host:port` of a session base URL, or the raw string if unparseable.
  static String hostLabelFor(String base) {
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty) return base;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Crumb',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 24),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 20),
              Text(
                'Waiting for server at $hostLabel...',
                key: const Key('waiting-for-server-text'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 6),
              const Text(
                'Your saved sign-in will resume automatically when the '
                'server is back.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 24),
              OutlinedButton(
                key: const Key('sign-in-as-someone-else'),
                onPressed: onSignInAsSomeoneElse,
                child: const Text('Sign in as someone else'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
