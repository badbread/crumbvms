// Per-camera Home Assistant entity linking — desktop port of the admin
// console's camera-editor flow (services/api/src/admin.html ~4810-4960:
// `loadCameraHaLinks`/`renderHaLinks`/`haOpenPicker`/`renderHaResults`/
// `haPick`/`removeHaLink`/`saveHaLinks`, issue #52). Lets an admin link this
// camera's HA motion/door sensors (role `motion`, domain `binary_sensor`)
// and lights/switches/scenes (role `actuator`, domain `controls`) without
// leaving the desktop app. The desktop's separate "Edit HA overlay…" editor
// (issue #170) then places any of these linked entities as an on-video
// badge — this dialog only manages WHICH entities are linked, not where
// they're drawn.
//
// Mirrors the admin console's picker exactly:
//   - Sensors: whitelisted device_classes (`_kSensorClasses`, mirrors
//     `HA_SENSOR_CLASSES`) grouped first (sorted), the rest bucketed under
//     "Other sensors" — hidden unless "Show all binary sensors" is checked
//     or there's a search query.
//   - Controls: grouped by entity_id domain (light/switch/scene), sorted.
//   - A search box filters both by friendly_name/entity_id substring.
//   - An already-linked-for-this-role entity is shown dimmed "(linked)" but
//     stays tappable (a no-op re-pick, matching `haPick`'s guard).
// Save sends the FULL working link set (not a diff), same as `saveHaLinks`.
//
// If Home Assistant isn't configured+enabled+token-set yet, the dialog shows
// only a "configure it first" hint — mirrors `renderHaLinks`'s `configured`
// gate (admin.html:4845-4850), which doesn't even show existing links in
// that state.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/ha_api.dart';
import 'package:crumb_desktop/api/ha_models.dart';
import 'package:crumb_desktop/api/models.dart';

/// device_classes worth linking to a camera by default; the rest hide under
/// "Other sensors" until searched or shown. Mirrors admin.html's
/// `HA_SENSOR_CLASSES` exactly.
const List<String> _kSensorClasses = [
  'motion',
  'occupancy',
  'presence',
  'moving',
  'door',
  'window',
  'opening',
  'garage_door',
];

/// Shows the "Link HA entities…" dialog for one camera. Returns when the
/// dialog is dismissed; [onSaved] fires once per successful save (not just
/// on dismiss) so the caller can refresh its own cached links right away —
/// see `wall_screen.dart`'s `_showTileMenu` for the intended wiring.
Future<void> showHaLinkDialog(
  BuildContext context, {
  required CrumbApi api,
  required Session session,
  required String cameraId,
  required String cameraName,
  VoidCallback? onSaved,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _HaLinkDialog(
      api: api,
      session: session,
      cameraId: cameraId,
      cameraName: cameraName,
      onSaved: onSaved,
    ),
  );
}

class _HaLinkDialog extends StatefulWidget {
  const _HaLinkDialog({
    required this.api,
    required this.session,
    required this.cameraId,
    required this.cameraName,
    required this.onSaved,
  });

  final CrumbApi api;
  final Session session;
  final String cameraId;
  final String cameraName;
  final VoidCallback? onSaved;

  @override
  State<_HaLinkDialog> createState() => _HaLinkDialogState();
}

class _HaLinkDialogState extends State<_HaLinkDialog> {
  bool _loading = true;
  String? _loadError;

  /// True iff HA is enabled, has a base URL, and has a stored token —
  /// mirrors admin.html's `configured` check (`renderHaLinks`).
  bool _configured = false;

  /// The working link set for this camera — mirrors admin.html's `HA_LINKS`
  /// mutable array. Edited locally; only sent to the server on Save.
  List<HaLinkInput> _links = const [];

  bool _saving = false;
  String? _saveError;

  // ── picker state (mirrors HA_PICKER/HA_PICKER_SEARCH/HA_PICKER_SHOWALL) ──
  String? _pickerRole; // 'motion' | 'actuator' | null (closed)
  final TextEditingController _searchCtrl = TextEditingController();
  String _pickerSearch = '';
  bool _pickerShowAll = false;
  bool _pickerLoading = false;
  String? _pickerError;
  final Map<String, List<HaEntity>> _entityCache = {}; // domain -> entities

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait([
        widget.api.getHaConfig(widget.session),
        widget.api.cameraHaLinks(widget.session, widget.cameraId),
      ]);
      if (!mounted) return;
      final cfg = results[0] as HaConfig;
      final links = results[1] as List<HaLink>;
      setState(() {
        _configured = cfg.enabled && cfg.baseUrl.trim().isNotEmpty && cfg.hasToken;
        _links = [for (final l in links) HaLinkInput.fromLink(l)];
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _openPicker(String role) async {
    setState(() {
      _pickerRole = role;
      _pickerSearch = '';
      _pickerShowAll = false;
      _pickerError = null;
    });
    _searchCtrl.clear();
    final domain = role == 'motion' ? 'binary_sensor' : 'controls';
    if (_entityCache.containsKey(domain)) return;
    setState(() => _pickerLoading = true);
    try {
      final entities = await widget.api.haEntities(widget.session, domain: domain);
      if (!mounted) return;
      setState(() => _entityCache[domain] = entities);
    } catch (e) {
      if (mounted) setState(() => _pickerError = '$e');
    } finally {
      if (mounted) setState(() => _pickerLoading = false);
    }
  }

  void _closePicker() => setState(() => _pickerRole = null);

  void _pick(HaEntity e) {
    final role = _pickerRole;
    if (role == null) return;
    if (_links.any((l) => l.entityId == e.entityId && l.role == role)) {
      return; // already linked for this role — no-op re-pick, matches haPick
    }
    setState(() {
      _links = [
        ..._links,
        HaLinkInput(
          entityId: e.entityId,
          role: role,
          deviceClass: e.deviceClass,
          label: e.friendlyName,
          sortOrder: _links.length,
        ),
      ];
    });
  }

  void _removeAt(int index) {
    setState(() => _links = [..._links]..removeAt(index));
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final body = [
        for (var i = 0; i < _links.length; i++)
          HaLinkInput(
            entityId: _links[i].entityId,
            role: _links[i].role,
            deviceClass: _links[i].deviceClass,
            label: _links[i].label,
            sortOrder: i,
          ),
      ];
      final saved = await widget.api.saveCameraHaLinks(
        widget.session,
        widget.cameraId,
        body,
      );
      if (!mounted) return;
      setState(() {
        _links = [for (final l in saved) HaLinkInput.fromLink(l)];
        _pickerRole = null;
      });
      widget.onSaved?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Home Assistant links saved.')),
      );
    } catch (e) {
      if (mounted) setState(() => _saveError = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _rolePill(HaLinkInput l) =>
      l.role == 'actuator' ? 'control' : (l.deviceClass ?? 'sensor');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Link HA entities — ${widget.cameraName}'),
      content: SizedBox(width: 580, height: 520, child: _body()),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (_configured)
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save links'),
          ),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError!),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (!_configured) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Configure Home Assistant in Settings first, then link this '
            "camera's sensors and controls here.",
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: _pickerRole == null ? 2 : 1,
          child: _links.isEmpty
              ? const Center(
                  child: Text('No links yet.', style: TextStyle(fontSize: 12)),
                )
              : ListView.builder(
                  itemCount: _links.length,
                  itemBuilder: (context, i) => _linkRow(scheme, i),
                ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton(
              onPressed: () => _openPicker('motion'),
              child: const Text('+ Add sensor'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _openPicker('actuator'),
              child: const Text('+ Add control'),
            ),
          ],
        ),
        if (_pickerRole != null) ...[
          const SizedBox(height: 8),
          Expanded(flex: 2, child: _pickerPanel(scheme)),
        ],
        if (_saveError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_saveError!, style: const TextStyle(color: Colors.red)),
          ),
      ],
    );
  }

  Widget _linkRow(ColorScheme scheme, int index) {
    final l = _links[index];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(_rolePill(l), style: const TextStyle(fontSize: 11)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l.label ?? l.entityId,
              style: const TextStyle(fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            l.entityId,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => _removeAt(index),
          ),
        ],
      ),
    );
  }

  Widget _pickerPanel(ColorScheme scheme) {
    final role = _pickerRole!;
    final kind = role == 'motion' ? 'sensors' : 'controls';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search $kind…',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _pickerSearch = v),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: _closePicker, child: const Text('Done')),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: _pickerLoading
              ? const Center(child: CircularProgressIndicator())
              : _pickerError != null
              ? Center(
                  child: Text(
                    _pickerError!,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                )
              : _pickerResults(scheme, role),
        ),
      ],
    );
  }

  Widget _pickerResults(ColorScheme scheme, String role) {
    final domain = role == 'motion' ? 'binary_sensor' : 'controls';
    final all = _entityCache[domain] ?? const <HaEntity>[];
    final q = _pickerSearch.trim().toLowerCase();
    bool match(HaEntity e) =>
        q.isEmpty ||
        e.entityId.toLowerCase().contains(q) ||
        e.friendlyName.toLowerCase().contains(q);
    final filtered = all.where(match).toList(growable: false);
    final linked = {
      for (final l in _links.where((l) => l.role == role)) l.entityId,
    };

    final groups = <(String, List<HaEntity>)>[];
    Widget? showAllToggle;

    if (role == 'motion') {
      final relevant = <HaEntity>[];
      final other = <HaEntity>[];
      for (final e in filtered) {
        (_kSensorClasses.contains(e.deviceClass) ? relevant : other).add(e);
      }
      final byClass = <String, List<HaEntity>>{};
      for (final e in relevant) {
        (byClass[e.deviceClass ?? 'sensor'] ??= []).add(e);
      }
      for (final c in byClass.keys.toList()..sort()) {
        groups.add((c, byClass[c]!));
      }
      if (other.isNotEmpty && (_pickerShowAll || q.isNotEmpty)) {
        groups.add(('Other sensors', other));
      }
      if (other.isNotEmpty && q.isEmpty) {
        showAllToggle = CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _pickerShowAll,
          onChanged: (v) => setState(() => _pickerShowAll = v ?? false),
          title: Text(
            'Show all binary sensors (${other.length} more)',
            style: const TextStyle(fontSize: 12),
          ),
        );
      }
    } else {
      final byDom = <String, List<HaEntity>>{};
      for (final e in filtered) {
        (byDom[e.domain] ??= []).add(e);
      }
      for (final d in byDom.keys.toList()..sort()) {
        groups.add((d, byDom[d]!));
      }
    }

    if (groups.isEmpty && showAllToggle == null) {
      return const Center(
        child: Text('No matching entities.', style: TextStyle(fontSize: 12)),
      );
    }

    return ListView(
      children: [
        if (showAllToggle != null) showAllToggle,
        for (final (title, items) in groups) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final e in items) _pickerRow(scheme, e, linked.contains(e.entityId)),
        ],
      ],
    );
  }

  Widget _pickerRow(ColorScheme scheme, HaEntity e, bool alreadyLinked) {
    return InkWell(
      onTap: () => _pick(e),
      child: Opacity(
        opacity: alreadyLinked ? 0.45 : 1.0,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  alreadyLinked ? '${e.friendlyName} (linked)' : e.friendlyName,
                  style: const TextStyle(fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                e.entityId,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
