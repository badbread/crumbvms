// Home Assistant connection settings — desktop port of the admin console's
// "Home Assistant" section (services/api/src/admin.html ~5893-5911's markup,
// `saveHa()`/`testHa()` ~6073-6095). A "PANE" section of the floating
// Settings window (see settings_window.dart's file header) — admin-only; the
// caller (SettingsWindow) hides this section's nav entry entirely for
// non-admins, and `PUT`/`POST /config/ha*` are admin-enforced server-side
// regardless (services/api/src/ha.rs).
//
// Fields: an enable toggle, Base URL, and a write-only long-lived access
// token (never pre-filled — the server never returns it, only whether one is
// stored, `HaConfig.hasToken`), a "Test connection" button that checks the
// SAVED config (mirrors the admin console's "Save first, then Test" note),
// and Save.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/ha_api.dart';
import 'package:crumb_desktop/api/ha_models.dart';
import 'package:crumb_desktop/api/models.dart';

class HaSettingsScreen extends StatelessWidget {
  const HaSettingsScreen({super.key, required this.api, required this.session});

  final CrumbApi api;
  final Session session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home Assistant')),
      body: _HaConfigLoader(api: api, session: session),
    );
  }
}

/// Loads the current config, then hands off to [_HaSettingsForm] once it's
/// available — mirrors `server_dashboard_screen.dart`'s `_AsyncSection`
/// loading/error/content split (that class is private to that file, so this
/// screen keeps its own small copy rather than importing it).
class _HaConfigLoader extends StatefulWidget {
  const _HaConfigLoader({required this.api, required this.session});

  final CrumbApi api;
  final Session session;

  @override
  State<_HaConfigLoader> createState() => _HaConfigLoaderState();
}

class _HaConfigLoaderState extends State<_HaConfigLoader> {
  late Future<HaConfig> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.getHaConfig(widget.session);
  }

  void _reload() =>
      setState(() => _future = widget.api.getHaConfig(widget.session));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<HaConfig>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${snap.error}'),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _reload, child: const Text('Retry')),
              ],
            ),
          );
        }
        return _HaSettingsForm(
          api: widget.api,
          session: widget.session,
          initial: snap.data!,
        );
      },
    );
  }
}

class _HaSettingsForm extends StatefulWidget {
  const _HaSettingsForm({
    required this.api,
    required this.session,
    required this.initial,
  });

  final CrumbApi api;
  final Session session;
  final HaConfig initial;

  @override
  State<_HaSettingsForm> createState() => _HaSettingsFormState();
}

class _HaSettingsFormState extends State<_HaSettingsForm> {
  late bool _enabled = widget.initial.enabled;
  late final TextEditingController _baseUrlCtrl = TextEditingController(
    text: widget.initial.baseUrl,
  );

  /// The token field always starts empty — the server never returns the
  /// actual token, only [_hasToken] (see [HaConfig.hasToken]).
  final TextEditingController _tokenCtrl = TextEditingController();
  late bool _hasToken = widget.initial.hasToken;

  bool _saving = false;
  String? _saveError;

  bool _testing = false;
  String? _testResult;
  bool _testOk = false;

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final baseUrl = _baseUrlCtrl.text.trim();
    if (_enabled && baseUrl.isEmpty) {
      setState(() => _saveError = 'Base URL is required when enabled.');
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      // Write-only: only sent when the operator typed something (mirrors the
      // admin console's `saveHa()` — `if (tok) body.token = tok;`).
      final tok = _tokenCtrl.text;
      final cfg = await widget.api.putHaConfig(
        widget.session,
        enabled: _enabled,
        baseUrl: baseUrl,
        token: tok.isEmpty ? null : tok,
      );
      if (!mounted) return;
      setState(() {
        _hasToken = cfg.hasToken;
        _tokenCtrl.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Home Assistant settings saved.')),
      );
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      await widget.api.testHaConfig(widget.session);
      if (!mounted) return;
      setState(() {
        _testResult = 'Connected';
        _testOk = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _testResult = '$e';
          _testOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Optional. Links your Home Assistant motion/door sensors and '
          'lights to cameras (right-click a camera on the wall, '
          '"Link HA entities…"). Use a token from a non-admin HA user: in '
          'Home Assistant add a user under Settings, People, then open that '
          "user's profile and create a Long-Lived Access Token.",
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        InkWell(
          onTap: () => setState(() => _enabled = !_enabled),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Enable Home Assistant integration',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ),
                Transform.scale(
                  scale: 0.72,
                  child: Switch(
                    value: _enabled,
                    onChanged: (v) => setState(() => _enabled = v),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _baseUrlCtrl,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'http://<home-assistant-host>:8123',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _tokenCtrl,
          obscureText: true,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Long-lived access token',
            hintText: _hasToken ? '•••••••• (unchanged)' : '(none set)',
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton(
              onPressed: _testing ? null : _test,
              child: _testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Test connection'),
            ),
            const SizedBox(width: 10),
            if (_testResult != null)
              Expanded(
                child: Text(
                  _testResult!,
                  style: TextStyle(
                    color: _testOk ? Colors.green : Colors.red,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Save first, then Test (Test checks the saved connection).',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
        if (_saveError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_saveError!, style: const TextStyle(color: Colors.red)),
          ),
      ],
    );
  }
}
