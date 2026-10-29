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
// folder" returns whatever directory is currently open. The header also offers
// New folder (create one here and step into it), Refresh (re-list after
// changes made outside the app) and Open in Explorer (the OS file manager,
// via url_launcher's file:// support as the export screen already does). The
// export screen also keeps its plain typeable destination field, so this is
// an aid, not the only way in.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

final _windowsReservedNames = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  for (var i = 1; i <= 9; i++) ...['COM$i', 'LPT$i'],
};

/// Why [name] can't be used as a new folder name, or null if it can. Applies
/// the Windows rules on every platform: they are a superset of the POSIX ones,
/// and exports are often copied to Windows machines anyway.
@visibleForTesting
String? folderNameError(String name) {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a folder name.';
  if (n == '.' || n == '..') return 'That name is reserved.';
  if (RegExp(r'[<>:"/\\|?*\x00-\x1F]').hasMatch(n)) {
    return r'''A folder name can't contain < > : " / \ | ? *''';
  }
  if (n.endsWith('.')) return "A folder name can't end with a dot.";
  final stem = n.split('.').first.trim().toUpperCase();
  if (_windowsReservedNames.contains(stem)) {
    return 'Windows reserves that name; pick another.';
  }
  return null;
}

/// Show the in-app folder picker rooted at [initialPath] (falls back to the
/// user's home / current dir). Returns the chosen absolute path, or null if
/// the user cancels.
Future<String?> pickFolderInApp(BuildContext context, {String? initialPath}) {
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
        (a, b) => _baseName(
          a.path,
        ).toLowerCase().compareTo(_baseName(b.path).toLowerCase()),
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

  void _refresh() => _navigateTo(_current);

  /// [name] inside the current folder. Drive roots already end in a
  /// separator (`C:\`), so don't double it.
  String _childPath(String name) {
    final base = _current.path;
    final sep = Platform.pathSeparator;
    return base.endsWith(sep) || base.endsWith('/')
        ? '$base$name'
        : '$base$sep$name';
  }

  Future<void> _createFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewFolderDialog(),
    );
    if (name == null || !mounted) return;
    final dir = Directory(_childPath(name.trim()));
    try {
      if (dir.existsSync()) {
        setState(
          () => _error = 'A folder named "${name.trim()}" already exists.',
        );
        return;
      }
      await dir.create();
    } on FileSystemException catch (e) {
      if (!mounted) return;
      setState(
        () => _error =
            "Couldn't create the folder: ${e.osError?.message ?? e.message}",
      );
      return;
    }
    if (!mounted) return;
    // Step into it, so "Use this folder" picks the folder just made.
    await _navigateTo(dir);
  }

  Future<void> _openInFileManager() async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.file(_current.path));
    } catch (_) {
      /* reported below */
    }
    if (!ok && mounted) {
      setState(
        () => _error = "Couldn't open this folder in $_fileManagerName.",
      );
    }
  }

  String get _fileManagerName => Platform.isWindows
      ? 'Explorer'
      : Platform.isMacOS
      ? 'Finder'
      : 'the file manager';

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
                  // Expanded so the header's action buttons never overflow a
                  // narrow dialog; the title truncates instead.
                  Expanded(
                    child: Text(
                      'Choose export folder',
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _loading ? null : _createFolder,
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 18,
                    ),
                    label: const Text('New folder'),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _loading ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: 'Open in $_fileManagerName',
                    onPressed: _openInFileManager,
                    icon: const Icon(Icons.open_in_new),
                  ),
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
                      onTap: () => _navigateTo(_resolveInitial(null)),
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
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  ),
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

/// Asks for the new folder's name, validating as the user types. Pops the
/// trimmed name, or null on cancel.
class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog();

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _ctrl = TextEditingController(text: 'New folder');
  String? _error;

  @override
  void initState() {
    super.initState();
    // Pre-select the default so typing replaces it, as Explorer does.
    _ctrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _ctrl.text.length,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final err = folderNameError(_ctrl.text);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.of(context).pop(_ctrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New folder'),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _ctrl,
          autofocus: true,
          decoration: InputDecoration(
            isDense: true,
            border: const OutlineInputBorder(),
            labelText: 'Folder name',
            errorText: _error,
          ),
          onChanged: (_) {
            if (_error != null) {
              setState(() => _error = folderNameError(_ctrl.text));
            }
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
