// PTZ preset list/recall — ported from app.js's `wirePtzPanel` preset
// `<select>` (apps/desktop/src/app.js ~5346-5373) and the on-video "Presets ▾"
// pill (ptzPresetsToggle/ptzPresetsRowGeom, ~5330-5373). Flutter gets a real
// dropdown menu instead of a hand-drawn ASS list — media_kit's Video widget
// is a normal Flutter widget, so a DOM-style menu no longer needs to be
// avoided the way it was in the old client (there, a DOM menu over the
// native mpv pane went black; see the comment at app.js ~5337).

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/ptz_extras_api.dart';

/// Small "Presets ▾" pill that fetches the camera's ONVIF presets on mount
/// and recalls one on selection. Best-effort: an empty/failed fetch just
/// yields no menu items (matches `ptzFetchPresetsFor`'s silent-fail policy).
class PtzPresetsPanel extends StatefulWidget {
  const PtzPresetsPanel({
    super.key,
    required this.api,
    required this.session,
    required this.cameraId,
  });

  final CrumbApi api;
  final Session session;
  final String cameraId;

  @override
  State<PtzPresetsPanel> createState() => _PtzPresetsPanelState();
}

class _PtzPresetsPanelState extends State<PtzPresetsPanel> {
  List<PtzPreset> _presets = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PtzPresetsPanel old) {
    super.didUpdateWidget(old);
    if (old.cameraId != widget.cameraId) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final presets = await widget.api.ptzPresets(widget.session, widget.cameraId);
    if (!mounted) return;
    setState(() {
      _presets = presets;
      _loading = false;
    });
  }

  Future<void> _recall(PtzPreset p) async {
    try {
      await widget.api.ptzRecallPreset(widget.session, widget.cameraId, p.token);
      if (mounted && _error != null) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = 'Preset unavailable');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 96,
        height: 28,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
          ),
        ),
      );
    }
    if (_presets.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _error!,
              style: TextStyle(color: Colors.red.shade300, fontSize: 11),
            ),
          ),
        Material(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          child: PopupMenuButton<PtzPreset>(
            tooltip: 'Go to a saved preset',
            onSelected: _recall,
            itemBuilder: (context) => _presets
                .map(
                  (p) => PopupMenuItem<PtzPreset>(
                    value: p,
                    child: Text(p.label),
                  ),
                )
                .toList(growable: false),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bookmark, color: Colors.white, size: 14),
                  SizedBox(width: 4),
                  Text(
                    'Presets',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  Icon(Icons.arrow_drop_down, color: Colors.white, size: 16),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
