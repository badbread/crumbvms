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

  Future<void> _delete(Bookmark bm) async {
    // Optimistic removal, same as the old client's row.remove() on success.
    final prev = _bookmarks;
    setState(() => _bookmarks = prev?.where((b) => b.id != bm.id).toList());
    try {
      await widget.api.deleteBookmark(widget.session, bm.id);
    } catch (e) {
      // Restore the row and surface the error.
      if (!mounted) return;
      setState(() => _bookmarks = prev);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Delete bookmark failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bookmarks'),
        actions: [
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

    return ListTile(
      onTap: onJump,
      leading: _BookmarkThumb(
        api: api,
        session: session,
        bookmark: bookmark,
      ),
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
              tooltip: 'Jump to playback',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: onJump,
            ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.close),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

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
                  Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true),
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
      local.year == now.year && local.month == now.month && local.day == now.day;
  return isToday ? '$h:$mi:$s' : '${local.year}-$mo-$d $h:$mi:$s';
}
