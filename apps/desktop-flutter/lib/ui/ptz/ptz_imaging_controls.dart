// ONVIF imaging (focus/iris) controls — ported from app.js's
// `imagingTileCmd` (~4270) and the imaging button row in `wirePtzPanel`
// (apps/desktop/src/app.js ~5318-5329, `.tile-ptz-imaging` buttons).
//
// Focus near/far are hold-to-drive (continuous focus move; release sends
// focus_stop), AF/iris are one-shot taps — matches the old client exactly.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/ptz_extras_api.dart';

class PtzImagingControls extends StatefulWidget {
  const PtzImagingControls({
    super.key,
    required this.api,
    required this.session,
    required this.cameraId,
  });

  final CrumbApi api;
  final Session session;
  final String cameraId;

  @override
  State<PtzImagingControls> createState() => _PtzImagingControlsState();
}

class _PtzImagingControlsState extends State<PtzImagingControls> {
  String? _error;

  Future<void> _fire(ImagingAction action) async {
    try {
      await widget.api.imagingCmd(widget.session, widget.cameraId, action);
      if (mounted && _error != null) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = 'Imaging unavailable');
    }
  }

  Widget _holdBtn(String label, ImagingAction start, ImagingAction stop, {String? tooltip}) {
    return Tooltip(
      message: tooltip ?? label,
      child: Listener(
        onPointerDown: (_) => _fire(start),
        onPointerUp: (_) => _fire(stop),
        onPointerCancel: (_) => _fire(stop),
        child: _chip(label),
      ),
    );
  }

  Widget _tapBtn(String label, ImagingAction action, {String? tooltip}) {
    return Tooltip(
      message: tooltip ?? label,
      child: GestureDetector(onTap: () => _fire(action), child: _chip(label)),
    );
  }

  Widget _chip(String label) => Container(
    margin: const EdgeInsets.all(2),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Colors.white24),
    ),
    child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(_error!, style: TextStyle(color: Colors.red.shade300, fontSize: 11)),
          ),
        Wrap(
          alignment: WrapAlignment.end,
          children: [
            _holdBtn('Focus−', ImagingAction.focusNear, ImagingAction.focusStop, tooltip: 'Focus nearer (hold)'),
            _holdBtn('Focus+', ImagingAction.focusFar, ImagingAction.focusStop, tooltip: 'Focus farther (hold)'),
            _tapBtn('AF', ImagingAction.autoFocus, tooltip: 'Auto-focus'),
            _tapBtn('Iris+', ImagingAction.irisOpen, tooltip: 'Open iris (brighter)'),
            _tapBtn('Iris−', ImagingAction.irisClose, tooltip: 'Close iris (darker)'),
            _tapBtn('IrisA', ImagingAction.irisAuto, tooltip: 'Auto iris'),
          ],
        ),
      ],
    );
  }
}
