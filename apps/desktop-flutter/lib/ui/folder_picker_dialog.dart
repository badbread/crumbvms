// In-app folder picker — a pure-Flutter directory browser used INSTEAD of the
// native OS folder dialog (file_selector `getDirectoryPath`).
//
// Why not the native dialog: on Windows the Win32 folder dialog (IFileDialog)
// runs its own MODAL message loop ON the Flutter platform/UI thread. On this
// app that loop does not pump — the whole window hard-hangs ("Not Responding")
// and no dialog ever appears (issue #87). Dropping fullscreen / foregrounding
// the window did not help because the freeze is a platform-thread deadlock,
// not a z-order problem. Enumerating directories with dart:io from Dart runs on
// the Dart isolate and can never block the platform thread, so this picker
// physically cannot freeze the app.
//
// It is deliberately simple: navigate into a folder by tapping it, hop drives
// or quick-access roots from the top row, type/paste a path, and "Use this
// folder" returns whatever directory is currently open. The export screen also
// keeps its plain typeable destination field, so this is an aid, not the only
// way in.

import 'dart:io';

import 'package:flutter/material.dart';

/// Show the in-app folder picker rooted at [initialPath] (falls back to the
/// user's home / current dir). Returns the chosen absolute path, or null if
/// the user cancels.
Future<String?> pickFolderInApp(
  BuildContext context, {
  String? initialPath,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _FolderPickerDialog(initialPath: initialPath),
  );
}

class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({this.initialPath});

  final String? initialPath;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  late Directory _current;
  final _pathCtrl = TextEditingController();
  List<Directory> _subdirs = const [];
  List<Directory> _roots = const []; // drives (Windows) / '/' (posix)
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _roots = _enumerateRoots();
    _current = _resolveInitial(widget.initialPath);
    _navigateTo(_current);
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  // ── path helpers ──────────────────────────────────────────────────────────

  Directory _resolveInitial(String? p) {
    final trimmed = p?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      final d = Directory(trimmed);
      if (d.existsSync()) return d;
    }
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null && home.isNotEmpty && Directory(home).existsSync()) {
      return Directory(home);
    }
    return Directory.current;
  }

  /// Windows: existing drive roots A:\ … Z:\. POSIX: just '/'.
  List<Directory> _enumerateRoots() {
    if (!Platform.isWindows) return [Directory('/')];
    final drives = <Directory>[];
    for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
      final d = Directory('${String.fromCharCode(c)}:\\');
      try {
        if (d.existsSync()) drives.add(d);
      } catch (_) {
        /* a not-ready removable drive throws — skip it */
      }
    }
    return drives;
  }

  String _baseName(String path) {
    final norm = path.replaceAll('\\', '/');
    final parts = norm.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }

  bool get _atRoot {
    final parent = _current.parent.path;
    return parent == _current.path;
  }

  // ── navigation ────────────────────────────────────────────────────────────

  Future<void> _navigateTo(Directory dir) async {
    setState(() {
      _current = dir;
      _pathCtrl.text = dir.path;
      _loading = true;
      _error = null;
    });
    try {
      final dirs = <Directory>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is Directory) dirs.add(e);
      }
      dirs.sort(
        (a, b) =>
            _baseName(a.path).toLowerCase().compareTo(
              _baseName(b.path).toLowerCase(),
            ),
      );
      if (!mounted) return;
      setState(() {
        _subdirs = dirs;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _subdirs = const [];
        _loading = false;
        _error = "Can't open this folder (permission denied or unavailable).";
      });
    }
  }

  void _goUp() {
    if (_atRoot) return;
    _navigateTo(_current.parent);
  }

  void _goToTypedPath() {
    final p = _pathCtrl.text.trim();
    if (p.isEmpty) return;
    final d = Directory(p);
    if (d.existsSync()) {
      _navigateTo(d);
    } else {
      setState(() => _error = 'No such folder: $p');
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.folder_open, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'Choose export folder',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Up one folder',
                    onPressed: _atRoot ? null : _goUp,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Editable path — supports paste, and 'Go' navigates to it.
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pathCtrl,
                      style: theme.textTheme.bodySmall,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        hintText: r'Type or paste a path (e.g. C:\Exports)',
                      ),
                      onSubmitted: (_) => _goToTypedPath(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _goToTypedPath,
                    child: const Text('Go'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Quick-access roots: drives + Home.
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _quickChip(
                      icon: Icons.home_outlined,
                      label: 'Home',
                      onTap: () => _navigateTo(
                        _resolveInitial(null),
                      ),
                    ),
                    for (final r in _roots)
                      _quickChip(
                        icon: Icons.storage_outlined,
                        label: r.path,
                        onTap: () => _navigateTo(r),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: _buildList(theme),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Use: ${_current.path}',
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_current.path),
                    child: const Text('Use this folder'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        avatar: Icon(icon, size: 16),
        label: Text(label),
        onPressed: onTap,
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_subdirs.isEmpty) {
      return Center(
        child: Text(
          _error == null ? 'No sub-folders here.' : '—',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    return ListView.builder(
      itemCount: _subdirs.length,
      itemBuilder: (context, i) {
        final d = _subdirs[i];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.folder, size: 20),
          title: Text(_baseName(d.path)),
          onTap: () => _navigateTo(d),
          trailing: const Icon(Icons.chevron_right, size: 18),
        );
      },
    );
  }
}
