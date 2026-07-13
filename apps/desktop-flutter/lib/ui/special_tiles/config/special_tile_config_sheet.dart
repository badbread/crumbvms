// Configure-panel for the five configurable special tile types (carousel,
// hotspot, image, text, web — `kSpecialTileConfigurable`; clock/events have
// no config). Port of vsOpenItemConfig / vsBuildConfigBody
// (apps/desktop/src/app.js ~760-847): a modal with type-specific fields that
// edits a draft copy and returns it only on "Done".
//
// The host (view-designer screen) is responsible for showing this after a
// palette drop / tile click and writing the result back into its own
// slot->spec map — this file does not touch any existing screen.
//
// Usage:
// ```dart
// final edited = await showSpecialTileConfigSheet(
//   context,
//   spec: draftSpec,
//   cameras: widget.cameras,
// );
// if (edited != null) { /* store `edited` in the slot */ }
// ```

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/models.dart';

import '../special_tile_spec.dart';
import '../tiles/image_tile_picker.dart';

/// Show the config sheet for `spec`. Returns the edited spec on "Done", or
/// null if cancelled/dismissed (caller should discard the draft).
Future<SpecialTileSpec?> showSpecialTileConfigSheet(
  BuildContext context, {
  required SpecialTileSpec spec,
  required List<Camera> cameras,
}) {
  return showDialog<SpecialTileSpec>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _SpecialTileConfigDialog(initial: spec, cameras: cameras),
  );
}

class _SpecialTileConfigDialog extends StatefulWidget {
  const _SpecialTileConfigDialog({required this.initial, required this.cameras});

  final SpecialTileSpec initial;
  final List<Camera> cameras;

  @override
  State<_SpecialTileConfigDialog> createState() => _SpecialTileConfigDialogState();
}

class _SpecialTileConfigDialogState extends State<_SpecialTileConfigDialog> {
  late SpecialTileSpec _draft = widget.initial;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Configure — ${_draft.kind.wireType}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(child: _buildBody()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_draft),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _buildBody() => switch (_draft) {
    CarouselSpec s => _CarouselConfig(
      spec: s,
      cameras: widget.cameras,
      onChanged: (v) => setState(() => _draft = v),
    ),
    HotspotSpec s => _HotspotConfig(
      spec: s,
      cameras: widget.cameras,
      onChanged: (v) => setState(() => _draft = v),
    ),
    ImageSpec s => _ImageConfig(spec: s, onChanged: (v) => setState(() => _draft = v)),
    TextSpec s => _TextConfig(spec: s, onChanged: (v) => setState(() => _draft = v)),
    WebSpec s => _WebConfig(spec: s, onChanged: (v) => setState(() => _draft = v)),
    ClockSpec() || EventsSpec() => const SizedBox.shrink(), // not configurable
  };
}

// ── Carousel ─────────────────────────────────────────────────────────────────

class _CarouselConfig extends StatelessWidget {
  const _CarouselConfig({required this.spec, required this.cameras, required this.onChanged});
  final CarouselSpec spec;
  final List<Camera> cameras;
  final ValueChanged<CarouselSpec> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Mode'),
        DropdownButton<CarouselMode>(
          value: spec.mode,
          isExpanded: true,
          items: const [
            DropdownMenuItem(value: CarouselMode.time, child: Text('Time — rotate every N seconds')),
            DropdownMenuItem(value: CarouselMode.motion, child: Text('Motion — jump to the camera with motion')),
            DropdownMenuItem(value: CarouselMode.both, child: Text('Both — motion first, else rotate')),
          ],
          onChanged: (m) {
            if (m != null) onChanged(spec.copyWith(mode: m));
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('Interval (seconds)'),
            const SizedBox(width: 12),
            SizedBox(
              width: 80,
              child: TextFormField(
                key: ValueKey(spec.intervalMs),
                initialValue: (spec.intervalMs ~/ 1000).toString(),
                keyboardType: TextInputType.number,
                onFieldSubmitted: (v) {
                  final secs = int.tryParse(v) ?? 8;
                  onChanged(spec.copyWith(intervalMs: secs.clamp(2, 120) * 1000));
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('Cameras to cycle'),
        _CameraCheckboxList(
          cameras: cameras,
          selected: spec.cameras.toSet(),
          onToggle: (id, checked) {
            final next = List<String>.of(spec.cameras);
            if (checked) {
              if (!next.contains(id)) next.add(id);
            } else {
              next.remove(id);
            }
            onChanged(spec.copyWith(cameras: next));
          },
        ),
      ],
    );
  }
}

// ── Hotspot ──────────────────────────────────────────────────────────────────

class _HotspotConfig extends StatelessWidget {
  const _HotspotConfig({required this.spec, required this.cameras, required this.onChanged});
  final HotspotSpec spec;
  final List<Camera> cameras;
  final ValueChanged<HotspotSpec> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Leave all cameras unchecked for the classic hotspot: click any camera on the '
          'wall to show it here.\nOr pick a set below and this tile auto-follows the '
          'camera with the most recent motion, even if those cameras aren\'t on the wall.',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        const Text('Auto-follow motion across these cameras'),
        _CameraCheckboxList(
          cameras: cameras,
          selected: spec.cameras.toSet(),
          onToggle: (id, checked) {
            final next = List<String>.of(spec.cameras);
            if (checked) {
              if (!next.contains(id)) next.add(id);
            } else {
              next.remove(id);
            }
            onChanged(spec.copyWith(cameras: next));
          },
        ),
      ],
    );
  }
}

// ── Image ────────────────────────────────────────────────────────────────────

class _ImageConfig extends StatefulWidget {
  const _ImageConfig({required this.spec, required this.onChanged});
  final ImageSpec spec;
  final ValueChanged<ImageSpec> onChanged;

  @override
  State<_ImageConfig> createState() => _ImageConfigState();
}

class _ImageConfigState extends State<_ImageConfig> {
  bool _picking = false;
  String? _error;

  Future<void> _pick() async {
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final dataUrl = await pickAndDownscaleImage(maxDim: 1280);
      if (dataUrl != null) widget.onChanged(widget.spec.copyWith(dataUrl: dataUrl));
    } catch (_) {
      setState(() => _error = 'Could not read that image');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.spec.bytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: _picking ? null : _pick,
          icon: const Icon(Icons.image_outlined),
          label: Text(_picking ? 'Choosing…' : 'Choose image…'),
        ),
        const SizedBox(height: 8),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        if (bytes != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: Image.memory(bytes, fit: BoxFit.contain),
          )
        else
          const Text('No image selected', style: TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}

// ── Text ─────────────────────────────────────────────────────────────────────

class _TextConfig extends StatelessWidget {
  const _TextConfig({required this.spec, required this.onChanged});
  final TextSpec spec;
  final ValueChanged<TextSpec> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Text'),
        TextFormField(
          initialValue: spec.text,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'e.g. LOADING DOCK'),
          onChanged: (v) => onChanged(spec.copyWith(text: v)),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('Size (px)'),
            const SizedBox(width: 12),
            SizedBox(
              width: 80,
              child: TextFormField(
                key: ValueKey(spec.size),
                initialValue: spec.size.round().toString(),
                keyboardType: TextInputType.number,
                onFieldSubmitted: (v) {
                  final sz = double.tryParse(v) ?? 28;
                  onChanged(spec.copyWith(size: sz.clamp(10, 72)));
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Web ──────────────────────────────────────────────────────────────────────

class _WebConfig extends StatelessWidget {
  const _WebConfig({required this.spec, required this.onChanged});
  final WebSpec spec;
  final ValueChanged<WebSpec> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('URL'),
        TextFormField(
          initialValue: spec.url,
          decoration: const InputDecoration(hintText: 'https://…'),
          onChanged: (v) => onChanged(spec.copyWith(url: v.trim())),
        ),
        const SizedBox(height: 6),
        const Text(
          'Some sites block embedding (X-Frame-Options / CSP).',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }
}

// ── Shared camera checkbox list ────────────────────────────────────────────

class _CameraCheckboxList extends StatelessWidget {
  const _CameraCheckboxList({required this.cameras, required this.selected, required this.onToggle});
  final List<Camera> cameras;
  final Set<String> selected;
  final void Function(String cameraId, bool checked) onToggle;

  @override
  Widget build(BuildContext context) {
    if (cameras.isEmpty) {
      return const Text('No cameras', style: TextStyle(fontSize: 12, color: Colors.grey));
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        children: cameras
            .map(
              (c) => CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(c.name),
                value: selected.contains(c.id),
                onChanged: (v) => onToggle(c.id, v ?? false),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}
