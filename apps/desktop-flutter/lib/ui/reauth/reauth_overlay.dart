// Modal re-auth overlay, ported from the old client's reauth-dialog markup
// + reauthOpen/reauthSubmit (apps/desktop/src/app.js). Wrap the app shell
// (wall/playback/clips screens) in this widget; it renders `child`
// unconditionally underneath — so live playback, MSE, native panes etc. keep
// running — and pops a blocking sign-in card on top whenever
// [SessionController.needsReauth] is true.
//
// Usage (see integration notes): wrap the signed-in shell once, after login:
//
//   ReauthOverlay(controller: sessionController, child: WallShell(...))

import 'package:flutter/material.dart';

import '../../session/session_controller.dart';

class ReauthOverlay extends StatefulWidget {
  const ReauthOverlay({super.key, required this.controller, required this.child});

  final SessionController controller;
  final Widget child;

  @override
  State<ReauthOverlay> createState() => _ReauthOverlayState();
}

class _ReauthOverlayState extends State<ReauthOverlay> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _remember = true;
  bool _prefilled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant ReauthOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (widget.controller.needsReauth && !_prefilled) {
      _usernameCtrl.text = widget.controller.username ?? '';
      _prefilled = true;
    }
    if (!widget.controller.needsReauth) {
      _prefilled = false;
      _passwordCtrl.clear();
    }
    setState(() {});
  }

  Future<void> _submit() async {
    if (widget.controller.reauthing) return;
    await widget.controller.reauth(
      _usernameCtrl.text,
      _passwordCtrl.text,
      remember: _remember,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Stack(
      children: [
        // The signed-in shell keeps running (streams, native video panes,
        // playback) exactly as before — a 401 must never tear it down.
        widget.child,
        if (c.needsReauth)
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.6),
              alignment: Alignment.center,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Card(
                  elevation: 8,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Session expired',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Sign back in to keep watching — the wall stays connected.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _usernameCtrl,
                            enabled: !c.reauthing,
                            decoration: const InputDecoration(
                              labelText: 'Username',
                            ),
                            textInputAction: TextInputAction.next,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _passwordCtrl,
                            enabled: !c.reauthing,
                            decoration: const InputDecoration(
                              labelText: 'Password',
                            ),
                            obscureText: true,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _submit(),
                          ),
                          Row(
                            children: [
                              Checkbox(
                                value: _remember,
                                onChanged: c.reauthing
                                    ? null
                                    : (v) =>
                                          setState(() => _remember = v ?? true),
                              ),
                              const Text('Keep me signed in'),
                            ],
                          ),
                          if (c.reauthError != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              c.reauthError!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: c.reauthing ? null : _submit,
                            child: Text(
                              c.reauthing ? 'Signing in…' : 'Sign in',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
