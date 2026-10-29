// Cross-camera bookmarks browser — port of pbOpenBookmarks
// (apps/desktop/src/app.js:8070). Lists every bookmark visible to the caller
// (server applies role scope), newest first; each row can jump to that
// camera+moment in playback and can be deleted.
//
// The old client opened this as a modal over the playback transport; the new
// app doesn't have a playback view yet (see AGENTS.md / component map), so
// this ships as its own full nav destination. [onJumpToPlayback] is the seam
// a future playback screen wires up — see integration notes.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

import 'package:crumb_desktop/api/bookmarks_api.dart';
import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/export_api.dart';
import 'package:crumb_desktop/api/models.dart';

import 'add_bookmark_dialog.dart';

class BookmarksScreen extends StatefulWidget {
  const BookmarksScreen({
    super.key,
    required this.api,
    required this.session,
    required this.cameras,
    this.onJumpToPlayback,
  });

  final CrumbApi api;
  final Session session;
  final List<Camera> cameras;

  /// Called when the user taps a bookmark row's "jump to playback" action,
  /// with the bookmark's camera id and moment. Wire this to a playback
  /// screen's navigation once one exists; if null, the jump action is hidden.
  final void Function(String cameraId, DateTime ts)? onJumpToPlayback;

  @override
  State<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends State<BookmarksScreen> {
  List<Bookmark>? _bookmarks;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.api.listBookmarks(widget.session);
      if (!mounted) return;
      setState(() {
        _bookmarks = list;
        _loading = false;
      });
    } on CrumbApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = "Couldn't load bookmarks: $e";
        _loading = false;
      });
    }
  }

  Camera? _cameraById(String id) {
    for (final c in widget.cameras) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> _addBookmark() async {
    final created = await showAddBookmarkDialog(
      context,
      api: widget.api,
      session: widget.session,
      cameras: widget.cameras,
    );
    if (created != null) {
      _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Bookmark added · ${created.cameraName ?? _cameraById(created.cameraId)?.name ?? 'camera'}',
            ),
          ),
        );
      }
    }
  }

  String _cameraLabel(Bookmark bm) =>
      bm.cameraName ?? _cameraById(bm.cameraId)?.name ?? 'Camera';

  /// Delete one bookmark. Asks first unless Shift is held at click time; every
  /// delete offers Undo.
  Future<void> _delete(Bookmark bm) async {
    final skipConfirm = HardwareKeyboard.instance.isShiftPressed;
    if (!skipConfirm) {
      final ok = await _confirmDelete(bm);
      if (ok != true || !mounted) return;
    }
    await _deleteMany([bm]);
  }

  Future<bool?> _confirmDelete(Bookmark bm) {
    final desc = (bm.description ?? '').trim();
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete bookmark?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_cameraLabel(bm)} · ${_formatDateTime(bm.ts)}'),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(desc, style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// "Remove expired (N)": confirm, then delete every bookmark whose footage
  /// retention has already deleted. Never automatic.
  Future<void> _removeExpired() async {
    final expired = expiredBookmarks(_bookmarks ?? const []);
    if (expired.isEmpty) return;
    final n = expired.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          n == 1
              ? 'Remove 1 expired bookmark?'
              : 'Remove $n expired bookmarks?',
        ),
        content: const Text(
          'Their footage has already been deleted by retention, so they can '
          'no longer be played back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _deleteMany(expired);
  }

  /// Optimistically remove [targets], delete them on the server, then show a
  /// SnackBar with Undo for the ones that were actually deleted. Rows whose
  /// delete failed come back.
  Future<void> _deleteMany(List<Bookmark> targets) async {
    final ids = {for (final b in targets) b.id};
    setState(
      () => _bookmarks = _bookmarks?.where((b) => !ids.contains(b.id)).toList(),
    );
    final deleted = <Bookmark>[];
    Object? firstError;
    for (final bm in targets) {
      try {
        await widget.api.deleteBookmark(widget.session, bm.id);
        deleted.add(bm);
      } catch (e) {
        firstError ??= e;
      }
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (firstError != null) {
      // Put back the rows that were not deleted.
      final failed = targets.where((b) => !deleted.contains(b)).toList();
      setState(() {
        _bookmarks = [...?_bookmarks, ...failed]
          ..sort((a, b) => b.ts.compareTo(a.ts));
      });
    }
    if (deleted.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text('Delete bookmark failed: $firstError')),
      );
      return;
    }
    final failedNote = firstError == null
        ? ''
        : ' (${targets.length - deleted.length} failed: $firstError)';
    messenger.showSnackBar(
      SnackBar(
        content: Text('${bookmarksDeletedMessage(deleted.length)}$failedNote'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => _undoDelete(deleted),
        ),
      ),
    );
  }

  /// Re-create deleted bookmarks with the same camera, moment, note and
  /// (unless it has lapsed) protection. They come back with new ids.
  Future<void> _undoDelete(List<Bookmark> deleted) async {
    var restored = 0;
    Object? firstError;
    for (final bm in deleted) {
      try {
        await widget.api.recreateBookmark(widget.session, bm);
        restored++;
      } catch (e) {
        firstError ??= e;
      }
    }
    if (!mounted) return;
    await _load();
    if (!mounted || firstError == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Restored $restored of ${deleted.length} bookmarks: $firstError',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bookmarks'),
        actions: [
          if (expiredBookmarks(_bookmarks ?? const []).isNotEmpty)
            TextButton.icon(
              onPressed: _loading ? null : _removeExpired,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: Text(
                'Remove expired (${expiredBookmarks(_bookmarks!).length})',
              ),
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addBookmark,
        icon: const Icon(Icons.bookmark_add_outlined),
        label: const Text('Add bookmark'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading && _bookmarks == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final rows = _bookmarks ?? const [];
    if (rows.isEmpty) {
      return const Center(
        child: Text(
          'No bookmarks yet. Use "Add bookmark" while reviewing a camera.',
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: rows.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) => _BookmarkRow(
          api: widget.api,
          session: widget.session,
          bookmark: rows[i],
          cameraFallbackName: _cameraById(rows[i].cameraId)?.name,
          onJump: widget.onJumpToPlayback == null
              ? null
              : () => widget.onJumpToPlayback!(rows[i].cameraId, rows[i].ts),
          onDelete: () => _delete(rows[i]),
        ),
      ),
    );
  }
}

class _BookmarkRow extends StatelessWidget {
  const _BookmarkRow({
    required this.api,
    required this.session,
    required this.bookmark,
    required this.cameraFallbackName,
    required this.onJump,
    required this.onDelete,
  });

  final CrumbApi api;
  final Session session;
  final Bookmark bookmark;
  final String? cameraFallbackName;
  final VoidCallback? onJump;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final name = bookmark.cameraName ?? cameraFallbackName ?? 'Camera';
    final when = _formatDateTime(bookmark.ts);
    final desc = (bookmark.description ?? '').trim();
    final theme = Theme.of(context);
    final expired = bookmark.footageExpired;

    return ListTile(
      onTap: onJump,
      leading: _BookmarkThumb(api: api, session: session, bookmark: bookmark),
      title: Row(
        children: [
          Text(
            name,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 6),
          Text('· $when', style: theme.textTheme.bodySmall),
          if (expired) ...[const SizedBox(width: 8), const _ExpiredBadge()],
        ],
      ),
      subtitle: Text(
        desc.isEmpty ? 'No description' : desc,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: desc.isEmpty
              ? theme.disabledColor
              : theme.textTheme.bodyMedium?.color,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onJump != null)
            IconButton(
              tooltip: expired
                  ? 'Footage for this bookmark was deleted by retention'
                  : 'Jump to playback',
              icon: Icon(
                Icons.play_circle_outline,
                color: expired ? theme.disabledColor : null,
              ),
              onPressed: onJump,
            ),
          IconButton(
            tooltip: 'Delete (Shift+click to skip confirmation)',
            icon: const Icon(Icons.close),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// Small "Footage deleted" chip on a bookmark whose footage retention has
/// already removed.
class _ExpiredBadge extends StatelessWidget {
  const _ExpiredBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Footage for this bookmark was deleted by retention',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'Footage deleted',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Bookmarks whose footage retention has already deleted (server-computed
/// `footage_expired`; always empty against a server that predates it).
List<Bookmark> expiredBookmarks(Iterable<Bookmark> all) =>
    all.where((b) => b.footageExpired).toList(growable: false);

/// SnackBar text after deleting [n] bookmarks.
String bookmarksDeletedMessage(int n) =>
    n == 1 ? 'Bookmark deleted' : '$n bookmarks deleted';

/// A small preview snapshot of the moment a bookmark marks — one filmstrip
/// JPEG frame at the bookmark's timestamp — falling back to a bookmark icon
/// while loading or if no frame is available.
class _BookmarkThumb extends StatefulWidget {
  const _BookmarkThumb({
    required this.api,
    required this.session,
    required this.bookmark,
  });

  final CrumbApi api;
  final Session session;
  final Bookmark bookmark;

  @override
  State<_BookmarkThumb> createState() => _BookmarkThumbState();
}

class _BookmarkThumbState extends State<_BookmarkThumb> {
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Uint8List? bytes;
    try {
      bytes = await widget.api.fetchFilmstripFrame(
        widget.session,
        widget.bookmark.cameraId,
        widget.bookmark.ts,
        width: 160,
      );
    } catch (_) {
      bytes = null;
    }
    if (mounted) {
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: 64,
        height: 40,
        child: _bytes != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    _bytes!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                  if (widget.bookmark.isProtected)
                    const Positioned(
                      right: 2,
                      top: 2,
                      child: Icon(Icons.lock, size: 12, color: Colors.white),
                    ),
                ],
              )
            : Container(
                color: scheme.surfaceContainerHighest,
                child: Center(
                  child: _loading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          widget.bookmark.isProtected
                              ? Icons.lock_outline
                              : Icons.bookmark_border,
                          size: 18,
                          color: widget.bookmark.isProtected
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                ),
              ),
      ),
    );
  }
}

String _formatDateTime(DateTime dt) {
  final local = dt.toLocal();
  final mo = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final h = local.hour.toString().padLeft(2, '0');
  final mi = local.minute.toString().padLeft(2, '0');
  final s = local.second.toString().padLeft(2, '0');
  final now = DateTime.now();
  final isToday =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  return isToday ? '$h:$mi:$s' : '${local.year}-$mo-$d $h:$mi:$s';
}
