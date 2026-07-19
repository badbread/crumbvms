// Login screen: server URL + credentials → an authenticated [Session] and the
// visible camera list. The password is entered by the user into this native
// field and sent straight to the server over the API; it is never persisted
// here (token persistence is a later refinement).

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/ui/discovery/server_discovery_panel.dart';

/// Optional prefill for the server field, e.g.
/// `--dart-define=SERVER_URL=http://host:port`. Never committed with a real
/// address — just a convenience for dev runs.
const String _prefillServer = String.fromEnvironment('SERVER_URL');

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api, required this.onLoggedIn});

  final CrumbApi api;
  final void Function(Session session, List<Camera> cameras) onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController(text: _prefillServer);
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _userFocus = FocusNode();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await widget.api.login(
        _server.text,
        _user.text,
        _pass.text,
      );
      final cameras = await widget.api.listCameras(session);
      if (!mounted) return;
      widget.onLoggedIn(session, cameras);
    } on CrumbApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not reach the server. Check the URL.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    _userFocus.dispose();
    super.dispose();
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
              const SizedBox(height: 4),
              const Text(
                'Desktop client',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _server,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'http://host:8080',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                enabled: !_busy,
              ),
              const SizedBox(height: 8),
              // "Find my server": scans the LAN and fills the field above. The
              // panel is self-contained and reports the chosen URL back here.
              ServerDiscoveryPanel(
                api: widget.api,
                onServerSelected: (url) {
                  setState(() => _server.text = url);
                  _userFocus.requestFocus();
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _user,
                focusNode: _userFocus,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
                enabled: !_busy,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pass,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
                enabled: !_busy,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: Colors.red.shade300),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
              ],
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Connect'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
