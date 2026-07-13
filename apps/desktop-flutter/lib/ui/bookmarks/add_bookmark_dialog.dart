// "Add bookmark" dialog — port of pbAddBookmark (apps/desktop/src/app.js:8006).
// Same fields/defaults as the old client: optional note, optional "protect
// from auto-delete" (days + pre/post clip window), defaulting to 7 days /
// 1 min before / 5 min after when the checkbox is ticked.

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/bookmarks_api.dart';
import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';

/// Shows the add-bookmark dialog and, on Save, POSTs the bookmark. Returns
/// the created [Bookmark] on success, or null if cancelled/failed (errors are
/// surfaced via a SnackBar before returning null).
///
/// Pass [camera] when the moment's camera is already known (e.g. bookmarking
/// from a live/playback tile or the clip player) to skip the picker, exactly
/// like `pbAddBookmark(camIdArg, atMsArg, defaultDesc)` in the old client. If
/// [camera] is null, [cameras] must be non-empty so the user can pick one
/// (used by the standalone Bookmarks screen's "Add" button).
Future<Bookmark?> showAddBookmarkDialog(
  BuildContext context, {
  required CrumbApi api,
  required Session session,
  Camera? camera,
  List<Camera> cameras = const [],
  DateTime? at,
  String? defaultDescription,
}) {
  return showDialog<Bookmark?>(
    context: context,
    builder: (context) => _AddBookmarkDialog(
      api: api,
      session: session,
      initialCamera: camera,
      cameras: cameras,
      at: at ?? DateTime.now(),
      defaultDescription: defaultDescription,
    ),
  );
}

class _AddBookmarkDialog extends StatefulWidget {
  const _AddBookmarkDialog({
    required this.api,
    required this.session,
    required this.initialCamera,
    required this.cameras,
    required this.at,
    required this.defaultDescription,
  });

  final CrumbApi api;
  final Session session;
  final Camera? initialCamera;
  final List<Camera> cameras;
  final DateTime at;
  final String? defaultDescription;

  @override
  State<_AddBookmarkDialog> createState() => _AddBookmarkDialogState();
}

class _AddBookmarkDialogState extends State<_AddBookmarkDialog> {
  late final TextEditingController _descCtrl = TextEditingController(
    text: widget.defaultDescription ?? '',
  );
  late final TextEditingController _daysCtrl = TextEditingController(
    text: '7',
  );
  late final TextEditingController _preCtrl = TextEditingController(text: '1');
  late final TextEditingController _postCtrl = TextEditingController(
    text: '5',
  );

  Camera? _selectedCamera;
  bool _protect = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedCamera =
        widget.initialCamera ??
        (widget.cameras.isNotEmpty ? widget.cameras.first : null);
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _daysCtrl.dispose();
    _preCtrl.dispose();
    _postCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cam = _selectedCamera;
    if (cam == null) {
      setState(() => _error = 'Select a camera first.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      BookmarkProtection? protection;
      if (_protect) {
        final days = int.tryParse(_daysCtrl.text) ?? 7;
        final preMin = int.tryParse(_preCtrl.text) ?? 1;
        final postMin = int.tryParse(_postCtrl.text) ?? 5;
        protection = BookmarkProtection(
          days: days.clamp(1, 30),
          preSeconds: preMin.clamp(0, 60) * 60,
          postSeconds: postMin.clamp(0, 60) * 60,
        );
      }
      final bm = await widget.api.createBookmark(
        widget.session,
        cameraId: cam.id,
        ts: widget.at,
        description: _descCtrl.text,
        protection: protection,
      );
      if (mounted) Navigator.of(context).pop(bm);
    } on CrumbApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Add bookmark failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cam = _selectedCamera;
    return AlertDialog(
      title: const Text('Add bookmark'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.initialCamera == null && widget.cameras.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DropdownButtonFormField<Camera>(
                  initialValue: cam,
                  decoration: const InputDecoration(labelText: 'Camera'),
                  items: widget.cameras
                      .map(
                        (c) =>
                            DropdownMenuItem(value: c, child: Text(c.name)),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _selectedCamera = v),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  cam?.name ?? 'Camera',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            Text(
              _formatDateTime(widget.at),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descCtrl,
              maxLines: 3,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _protect,
              onChanged: (v) => setState(() => _protect = v ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: const Text('Protect from auto-delete'),
            ),
            if (_protect)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Keep'),
                  _NumberField(controller: _daysCtrl, min: 1, max: 30),
                  const Text('days · clip'),
                  _NumberField(controller: _preCtrl, min: 0, max: 60),
                  const Text('min before /'),
                  _NumberField(controller: _postCtrl, min: 0, max: 60),
                  const Text('min after'),
                ],
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({required this.controller, required this.min, required this.max});

  final TextEditingController controller;
  final int min;
  final int max;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      child: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          border: OutlineInputBorder(),
        ),
      ),
    );
  }
}

String _formatDateTime(DateTime dt) {
  final local = dt.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final mo = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final h = local.hour.toString().padLeft(2, '0');
  final mi = local.minute.toString().padLeft(2, '0');
  final s = local.second.toString().padLeft(2, '0');
  return '$y-$mo-$d $h:$mi:$s';
}
