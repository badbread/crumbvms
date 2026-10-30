// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The plate desk list: the "today" header (stat tiles + regulars / returning
// / first-time split, all clickable filters), the Density control, and the
// ledger rows (frame thumbnail, plate crop with a hover loupe, plate + marks,
// history cell, 30-day sparkline, time, confidence). A `part` of
// plates_screen.dart so it shares the screen's snapshot cache, concurrency
// gate and small widgets.

part of 'plates_screen.dart';

// ─── palette ───────────────────────────────────────────────────────────────

const _kPink = Color(0xFFE05A8A); // LPR accent, watchlist
const _kGreen = Color(0xFF57C888); // new / first-time
const _kAmber = Color(0xFFE8A33D); // regular
const _kRed = Color(0xFFE05A5A);
const _kSlate = Color(0xFF8A93A6); // returning
const _kSurface0 = Color(0xFF14171C);
const _kSurface1 = Color(0xFF1B1D22);
const _kSurface2 = Color(0xFF24272E);

Color? _railColor(PlateRail r) => switch (r) {
  PlateRail.watchlist => _kPink,
  PlateRail.newPlate => _kGreen,
  PlateRail.regular => _kAmber,
  PlateRail.none => null,
};

// ─── snapshot loading shared by the ledger cells ───────────────────────────

/// In-flight snapshot loads, so the frame cell and the crop cell of one row
/// (and the loupe) share a single download.
final Map<String, Future<Uint8List?>> _snapshotInflight = {};

Future<Uint8List?> _loadSnapshot(
  Session s,
  String eventId,
  _ConcurrencyGate gate,
) {
  final cached = _snapshotCache[eventId];
  if (cached != null) return Future.value(cached);
  return _snapshotInflight[eventId] ??= () async {
    Uint8List? out;
    try {
      await gate.run(() async {
        out = await _fetchSnapshotBytes(s, eventId);
      });
    } finally {
      _snapshotInflight.remove(eventId);
    }
    return out;
  }();
}

// ─── header ────────────────────────────────────────────────────────────────

/// The plate desk header: today's tiles and the split bar. Tiles and split
/// segments are filters; the active one is outlined, and clicking it again
/// clears it.
class _DeskHeader extends StatelessWidget {
  const _DeskHeader({
    required this.overview,
    required this.filter,
    required this.groupByPlate,
    required this.onFilter,
    required this.onGroupByPlate,
  });

  final LprOverview overview;
  final DeskFilter filter;
  final bool groupByPlate;
  final ValueChanged<DeskFilter> onFilter;
  final ValueChanged<bool> onGroupByPlate;

  void _toggle(DeskFilter f) => onFilter(filter == f ? DeskFilter.all : f);

  @override
  Widget build(BuildContext context) {
    final o = overview;
    return Container(
      color: _kSurface0,
      height: 98,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: LayoutBuilder(
        builder: (context, c) {
          // Tiles shrink before the split card disappears; the split card
          // needs ~240 px to be readable.
          final w = c.maxWidth;
          final showSplit = w >= 4 * (84 + 8) + 240;
          final tileW = showSplit
              ? ((w - 260) / 4 - 8).clamp(84.0, 124.0)
              : (w / 4 - 8).clamp(40.0, 124.0);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatTile(
                width: tileW,
                value: o.readsToday,
                label: 'Reads today',
                color: _kPink,
                active: filter == DeskFilter.all && !groupByPlate,
                tooltip: 'Show every read',
                onTap: () {
                  onFilter(DeskFilter.all);
                  onGroupByPlate(false);
                },
              ),
              _StatTile(
                width: tileW,
                value: o.uniqueToday,
                label: 'Unique plates',
                color: Colors.white70,
                active: groupByPlate,
                tooltip: groupByPlate
                    ? 'Stop grouping reads by plate'
                    : 'Group reads of the same plate into one row',
                onTap: () => onGroupByPlate(!groupByPlate),
              ),
              _StatTile(
                width: tileW,
                value: o.newToday,
                label: 'New plates',
                color: _kGreen,
                active: filter == DeskFilter.firstTime,
                tooltip: 'Only plates seen for the first time today',
                onTap: () => _toggle(DeskFilter.firstTime),
              ),
              _StatTile(
                width: tileW,
                value: o.watchlistHitsToday,
                label: 'Watchlist hits',
                color: _kPink,
                active: filter == DeskFilter.watchlist,
                tooltip: 'Only plates on the watchlist',
                onTap: () => _toggle(DeskFilter.watchlist),
              ),
              if (showSplit)
                Expanded(
                  child: _SplitCard(
                    split: o.split,
                    regularMin: o.regularMinReads30d,
                    filter: filter,
                    onTap: _toggle,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.width,
    required this.value,
    required this.label,
    required this.color,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  final double width;
  final int value;
  final String label;
  final Color color;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: active ? _kSurface2 : _kSurface1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: active ? color : Colors.transparent,
              width: 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: width,
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: color, width: 2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '$value',
                    maxLines: 1,
                    overflow: TextOverflow.fade,
                    softWrap: false,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single line that never overflows: children past the edge are clipped.
Widget _clipRow(List<Widget> children) => SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  physics: const NeverScrollableScrollPhysics(),
  child: Row(mainAxisSize: MainAxisSize.min, children: children),
);

class _SplitCard extends StatelessWidget {
  const _SplitCard({
    required this.split,
    required this.regularMin,
    required this.filter,
    required this.onTap,
  });

  final LprSplit split;
  final int regularMin;
  final DeskFilter filter;
  final ValueChanged<DeskFilter> onTap;

  @override
  Widget build(BuildContext context) {
    final segs = [
      (
        DeskFilter.regulars,
        split.regulars,
        _kAmber,
        'Regulars ($regularMin+ in 30 d)',
      ),
      (DeskFilter.returning, split.returning, _kSlate, 'Returning'),
      (DeskFilter.firstTime, split.firstTime, _kGreen, 'First-time'),
    ];
    final total = split.total;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: _kSurface1,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'REGULARS VS STRANGERS, TODAY',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white38,
              fontSize: 10,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 12,
              child: total == 0
                  ? Container(color: _kSurface2)
                  : Row(
                      children: [
                        for (final (f, n, c, label) in segs)
                          if (n > 0)
                            Expanded(
                              flex: n,
                              child: Tooltip(
                                message: '$n $label',
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onTap: () => onTap(f),
                                    child: Container(
                                      margin: const EdgeInsets.only(right: 2),
                                      color:
                                          filter == DeskFilter.all ||
                                              filter == f
                                          ? c
                                          : c.withValues(alpha: 0.3),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 7),
          _clipRow([
            for (final (f, n, c, label) in segs)
              Padding(
                padding: const EdgeInsets.only(right: 14),
                child: InkWell(
                  onTap: () => onTap(f),
                  borderRadius: BorderRadius.circular(4),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '■ ',
                          style: TextStyle(color: c),
                        ),
                        TextSpan(
                          text: '$n ',
                          style: const TextStyle(color: Colors.white),
                        ),
                        TextSpan(
                          text: label,
                          style: TextStyle(
                            color: filter == f ? c : Colors.white38,
                            fontWeight: filter == f
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ]),
        ],
      ),
    );
  }
}

// ─── density control ──────────────────────────────────────────────────────

/// The one display control for the list: Compact (text only), Standard,
/// Large. Replaces the old Show / Crop size / Crop corner menus.
class _DensityToggle extends StatelessWidget {
  const _DensityToggle({required this.value, required this.onChanged});

  final PlateDensity value;
  final ValueChanged<PlateDensity> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget seg(PlateDensity d, String label, String tip) {
      final on = value == d;
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: () => onChanged(d),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: on ? _kPink : _kSurface2,
            child: Text(
              label,
              style: TextStyle(
                color: on ? Colors.white : Colors.white70,
                fontSize: 12,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          seg(
            PlateDensity.compact,
            'Compact',
            'Text only, one line per read (1)',
          ),
          seg(PlateDensity.standard, 'Standard', 'Frame and plate crop (2)'),
          seg(PlateDensity.large, 'Large', 'Big frame and plate crop (3)'),
        ],
      ),
    );
  }
}

// ─── small painters ────────────────────────────────────────────────────────

/// A 30-day activity line; today is the last point and gets a dot.
class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color);

  final List<int> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxV = values.fold<int>(1, (a, b) => b > a ? b : a);
    final dx = values.length > 1 ? size.width / (values.length - 1) : 0.0;
    double y(int v) => size.height - 2 - (v / maxV) * (size.height - 4);
    final path = Path()..moveTo(0, y(values.first));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(i * dx, y(values[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
    if (values.last > 0) {
      canvas.drawCircle(
        Offset((values.length - 1) * dx, y(values.last)),
        2.2,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.color != color || !listEquals(old.values, values);
}

// ─── column header ─────────────────────────────────────────────────────────

class _LedgerColumns extends StatelessWidget {
  const _LedgerColumns({required this.m, required this.cols});

  final DensityMetrics m;
  final LedgerColumns cols;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.white38,
      fontSize: 10,
      letterSpacing: 0.6,
    );
    return Container(
      height: 26,
      padding: const EdgeInsets.only(left: 13, right: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _kSurface2)),
      ),
      child: Row(
        children: [
          if (cols.frame) ...[
            SizedBox(
              width: m.frameWidth,
              child: const Text('FRAME', style: style),
            ),
            const SizedBox(width: 10),
          ],
          if (cols.crop) ...[
            SizedBox(
              width: m.cropWidth,
              child: const Text('PLATE', style: style),
            ),
            const SizedBox(width: 12),
          ],
          const Expanded(child: Text('PLATE / CAMERA', style: style)),
          const SizedBox(
            width: kLedgerHistoryW,
            child: Text('HISTORY', style: style),
          ),
          if (cols.spark)
            SizedBox(
              width: m.sparkWidth + 12,
              child: const Text('30 DAYS', style: style),
            ),
          const SizedBox(
            width: kLedgerWhenW,
            child: Text('WHEN', style: style),
          ),
          const SizedBox(
            width: kLedgerConfW,
            child: Text('CONF', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(width: kLedgerActionsW),
        ],
      ),
    );
  }
}

// ─── ledger row ────────────────────────────────────────────────────────────

String _fmtClock(DateTime t) {
  final l = t.toLocal();
  final h12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '$h12:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
}

String _dayLabel(DateTime t, DateTime now) {
  final l = t.toLocal();
  final n = now.toLocal();
  final d0 = DateTime(n.year, n.month, n.day);
  final d1 = DateTime(l.year, l.month, l.day);
  final diff = d0.difference(d1).inDays;
  if (diff == 0) return 'today';
  if (diff == 1) return 'yesterday';
  return fmtShortDate(t, now);
}

/// A small coloured tag: NEW, WATCHLIST, UNUSUAL HOUR, 4x TODAY.
Widget _tag(String text, Color c, {double size = 9.5}) => Container(
  margin: const EdgeInsets.only(left: 6),
  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
  decoration: BoxDecoration(
    color: c.withValues(alpha: 0.2),
    borderRadius: BorderRadius.circular(3),
  ),
  child: Text(
    text,
    style: TextStyle(
      color: c,
      fontSize: size,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    ),
  ),
);

class _LedgerRow extends StatefulWidget {
  const _LedgerRow({
    super.key,
    required this.entry,
    required this.m,
    required this.cols,
    required this.stats,
    required this.statsUnsupported,
    required this.watched,
    required this.cameraName,
    required this.selected,
    required this.expanded,
    required this.api,
    required this.session,
    required this.gate,
    required this.canManage,
    required this.canName,
    required this.onTap,
    required this.onToggleExpand,
    required this.onAddToWatchlist,
    required this.onNamePlate,
    required this.onReport,
    required this.onLoupe,
  });

  final LedgerEntry entry;
  final DensityMetrics m;
  final LedgerColumns cols;
  final PlateStats? stats;
  final bool statsUnsupported;
  final bool watched;
  final String cameraName;
  final bool selected;
  final bool expanded;
  final CrumbApi api;
  final Session session;
  final _ConcurrencyGate gate;
  final bool canManage;
  final bool canName;
  final VoidCallback onTap;
  final VoidCallback onToggleExpand;
  final VoidCallback onAddToWatchlist;
  final VoidCallback onNamePlate;
  final VoidCallback onReport;

  /// Show (non-null rect, global coordinates of the crop cell) or hide the
  /// single shared loupe.
  final void Function(PlateRead read, Rect? anchor) onLoupe;

  @override
  State<_LedgerRow> createState() => _LedgerRowState();
}

class _LedgerRowState extends State<_LedgerRow> {
  bool _hover = false;

  PlateRead get _read => widget.entry.group.representative;

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final read = _read;
    final s = widget.stats;
    final rail = widget.entry.isChild
        ? null
        : _railColor(plateRail(watched: widget.watched, stats: s));
    final bg = widget.selected
        ? _kSurface2
        : _hover
        ? _kSurface1
        : widget.entry.isChild
        ? const Color(0xFF181B20)
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              left: BorderSide(color: rail ?? Colors.transparent, width: 3),
              bottom: const BorderSide(color: _kSurface1),
            ),
          ),
          foregroundDecoration: widget.selected
              ? BoxDecoration(border: Border.all(color: _kPink, width: 1))
              : null,
          padding: EdgeInsets.only(
            left: widget.entry.isChild ? 34 : 10,
            right: 10,
          ),
          child: Row(
            children: [
              if (widget.cols.frame) ...[
                _FrameCell(
                  read: read,
                  width: widget.entry.isChild
                      ? m.frameWidth - 24
                      : m.frameWidth,
                  height: m.frameHeight,
                  session: widget.session,
                  gate: widget.gate,
                ),
                const SizedBox(width: 10),
              ],
              if (widget.cols.crop) ...[
                _CropCell(
                  read: read,
                  width: m.cropWidth,
                  height: m.cropHeight,
                  session: widget.session,
                  gate: widget.gate,
                  onLoupe: widget.onLoupe,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(child: _plateColumn(read, s)),
              SizedBox(width: kLedgerHistoryW, child: _historyCell(s)),
              if (widget.cols.spark)
                SizedBox(
                  width: m.sparkWidth + 12,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: s == null
                        ? Text(
                            widget.statsUnsupported ? '-' : '',
                            style: const TextStyle(color: Colors.white24),
                          )
                        : CustomPaint(
                            size: Size(m.sparkWidth, m.sparkHeight),
                            painter: _SparklinePainter(
                              s.days30,
                              s.isRegular || widget.watched
                                  ? _kPink
                                  : _kPink.withValues(alpha: 0.7),
                            ),
                          ),
                  ),
                ),
              SizedBox(width: kLedgerWhenW, child: _whenCell(read)),
              SizedBox(
                width: kLedgerConfW,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _confText(read.confidence),
                ),
              ),
              SizedBox(
                width: kLedgerActionsW,
                child: _actions(read, visible: _hover || widget.selected),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _plateColumn(PlateRead read, PlateStats? s) {
    final m = widget.m;
    final hints = plateHints(s, read.ts);
    final name = read.displayName?.trim() ?? '';
    final group = widget.entry.group;
    final bundle = widget.entry.isChild ? null : widget.entry.bundle;
    final plateText = Text(
      read.plate.isEmpty ? '-' : read.plate,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Colors.white,
        fontSize: m.plateFont,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        fontFamily: 'monospace',
      ),
    );
    // Marks after the plate, clipped (never overflowing) when the column is
    // narrow.
    final marks = <Widget>[
      if (!widget.entry.isChild) ...[
        if (hints.isNew) _tag('NEW', _kGreen),
        if (widget.watched) _tag('WATCHLIST', _kPink),
        if (hints.showToday) _tag('${hints.todayCount}x TODAY', _kPink),
      ],
      if (hints.unusualHour) _tag('UNUSUAL HOUR', _kAmber),
      if (name.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(
            widget.watched ? '★ $name' : name,
            maxLines: 1,
            style: TextStyle(
              color: widget.watched ? _kPink : Colors.white70,
              fontSize: m.subFont,
            ),
          ),
        ),
    ];
    final headline = LayoutBuilder(
      builder: (context, c) => Row(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: c.maxWidth),
            child: plateText,
          ),
          if (marks.isNotEmpty) Expanded(child: _clipRow(marks)),
        ],
      ),
    );
    final subParts = <InlineSpan>[
      TextSpan(text: widget.cameraName),
      if (read.region != null && read.region!.isNotEmpty)
        TextSpan(text: '  ·  ${read.region}'),
      if (group.sources.isNotEmpty)
        TextSpan(text: '  ·  ${group.sources.map(_engineLabel).join(' + ')}'),
      if (group.count > 1) TextSpan(text: '  ×${group.count}'),
    ];
    final disagree = group.disagreements;
    final sub = _clipRow([
      if (bundle != null && bundle.passCount > 1)
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: InkWell(
            onTap: widget.onToggleExpand,
            child: Text(
              '${widget.expanded ? '▾' : '▸'} '
              '${bundle.readCount} reads',
              style: TextStyle(
                color: _kGreen,
                fontSize: m.subFont,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      Text.rich(
        TextSpan(children: subParts),
        maxLines: 1,
        style: TextStyle(color: Colors.white38, fontSize: m.subFont),
      ),
      if (disagree.isNotEmpty)
        Tooltip(
          message: disagree.entries
              .map((e) => '${_engineLabel(e.key)} read ${e.value}')
              .join('\n'),
          child: const Padding(
            padding: EdgeInsets.only(left: 6),
            child: Icon(Icons.compare_arrows, size: 13, color: _kAmber),
          ),
        ),
    ]);
    if (!m.showImages) {
      // Compact: one line, plate then camera.
      return Row(
        children: [
          Expanded(flex: 3, child: headline),
          const SizedBox(width: 10),
          Expanded(flex: 2, child: sub),
        ],
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [headline, const SizedBox(height: 2), sub],
    );
  }

  Widget _historyCell(PlateStats? s) {
    final m = widget.m;
    final now = DateTime.now();
    final (a, b) = s == null
        ? (widget.statsUnsupported ? '-' : '', '')
        : historyCellText(s, now);
    final strong = s != null && (s.isRegular || s.total >= 3);
    final first = Text(
      a,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: strong ? _kPink : Colors.white,
        fontSize: m.subFont + 2,
        fontWeight: FontWeight.w700,
      ),
    );
    if (!m.showImages || b.isEmpty) {
      return Row(
        children: [
          first,
          if (b.isNotEmpty && !m.showImages)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  b,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white38, fontSize: m.subFont),
                ),
              ),
            ),
        ],
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        first,
        const SizedBox(height: 2),
        Text(
          b,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Colors.white38, fontSize: m.subFont),
        ),
      ],
    );
  }

  Widget _whenCell(PlateRead read) {
    final m = widget.m;
    final clock = Text(
      _fmtClock(read.ts),
      style: TextStyle(
        color: Colors.white,
        fontSize: m.subFont + 1,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final day = Text(
      _dayLabel(read.ts, DateTime.now()),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: Colors.white38, fontSize: m.subFont),
    );
    if (!m.showImages) {
      return _clipRow([clock, const SizedBox(width: 4), day]);
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [clock, day],
    );
  }

  Widget _confText(double? c) {
    if (c == null) {
      return const Text('-', style: TextStyle(color: Colors.white24));
    }
    final color = c >= 0.85
        ? _kGreen
        : c >= 0.6
        ? _kAmber
        : _kRed;
    return Text(
      '${(c * 100).round()}%',
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w600,
        fontSize: widget.m.subFont + 1,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  /// One "more" menu per row (Copy plate / Name / Watchlist / Report), so
  /// the actions cost a 32 px column instead of four buttons.
  Widget _actions(PlateRead read, {required bool visible}) {
    final copy = plateCopyText(read);
    final canName = canOfferPlateName(
      isAdmin: widget.canName,
      plate: read.plate,
    );
    final canWatch = widget.canManage && read.plate.isNotEmpty;
    return PopupMenuButton<String>(
      tooltip: 'Actions',
      padding: EdgeInsets.zero,
      iconSize: 18,
      color: const Color(0xFF23262E),
      icon: Icon(
        Icons.more_vert,
        size: 18,
        color: visible ? Colors.white70 : Colors.white24,
      ),
      onSelected: (v) {
        switch (v) {
          case 'copy':
            copyPlateToClipboard(context, copy);
          case 'name':
            widget.onNamePlate();
          case 'correct':
            showPlateCorrectionDialog(
              context,
              api: widget.api,
              session: widget.session,
              plate: read.plate,
            );
          case 'watch':
            widget.onAddToWatchlist();
          case 'report':
            widget.onReport();
        }
      },
      itemBuilder: (context) => [
        // Copies the PLATE, never the display name.
        if (copy.isNotEmpty)
          const PopupMenuItem(
            value: 'copy',
            child: Text('Copy plate', style: TextStyle(fontSize: 13)),
          ),
        if (canName)
          PopupMenuItem(
            value: 'name',
            child: Text(
              plateNameActionLabel(read.displayName),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        if (canOfferPlateCorrection(isAdmin: widget.canName, plate: read.plate))
          const PopupMenuItem(
            value: 'correct',
            child: Text('Correct plate...', style: TextStyle(fontSize: 13)),
          ),
        if (canWatch)
          PopupMenuItem(
            value: 'watch',
            enabled: !widget.watched,
            child: Text(
              widget.watched ? 'On watchlist' : 'Add to watchlist',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        const PopupMenuItem(
          value: 'report',
          child: Text('Report (PDF)', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}

/// The frame thumbnail, decoded at display size.
class _FrameCell extends StatefulWidget {
  const _FrameCell({
    required this.read,
    required this.width,
    required this.height,
    required this.session,
    required this.gate,
  });

  final PlateRead read;
  final double width;
  final double height;
  final Session session;
  final _ConcurrencyGate gate;

  @override
  State<_FrameCell> createState() => _FrameCellState();
}

class _FrameCellState extends State<_FrameCell> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_FrameCell old) {
    super.didUpdateWidget(old);
    if (old.read.eventId != widget.read.eventId) {
      _bytes = null;
      _load();
    }
  }

  void _load() {
    final eventId = widget.read.eventId;
    if (eventId == null || eventId.isEmpty) return;
    final cached = _snapshotCache[eventId];
    if (cached != null) {
      _bytes = cached;
      return;
    }
    _loadSnapshot(widget.session, eventId, widget.gate).then((b) {
      if (mounted && b != null && widget.read.eventId == eventId) {
        setState(() => _bytes = b);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final b = _bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: b == null
            ? Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: const Icon(
                  Icons.directions_car_outlined,
                  color: Colors.white12,
                  size: 18,
                ),
              )
            : Image.memory(
                b,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: (widget.width * dpr).round().clamp(1, 1024),
              ),
      ),
    );
  }
}

/// The plate crop cut from the read's own snapshot by its bounding box (the
/// shared crop cache, no extra download). A read with no box (or a failed
/// crop) shows the plate text on a plate-coloured tile instead. Hovering it
/// opens the shared loupe.
class _CropCell extends StatefulWidget {
  const _CropCell({
    required this.read,
    required this.width,
    required this.height,
    required this.session,
    required this.gate,
    required this.onLoupe,
  });

  final PlateRead read;
  final double width;
  final double height;
  final Session session;
  final _ConcurrencyGate gate;
  final void Function(PlateRead read, Rect? anchor) onLoupe;

  @override
  State<_CropCell> createState() => _CropCellState();
}

class _CropCellState extends State<_CropCell> {
  Uint8List? _crop;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_CropCell old) {
    super.didUpdateWidget(old);
    if (old.read.id != widget.read.id) {
      _crop = null;
      _failed = false;
      _load();
    }
  }

  void _load() {
    final read = widget.read;
    final bbox = read.bbox;
    final eventId = read.eventId;
    if (bbox == null || bbox.length < 4 || eventId == null || eventId.isEmpty) {
      _failed = true;
      return;
    }
    final hit = peekPlateCrop(read.id);
    if (hit != null) {
      _crop = hit;
      return;
    }
    final id = read.id;
    _loadSnapshot(widget.session, eventId, widget.gate).then((bytes) async {
      if (bytes == null) {
        if (mounted && widget.read.id == id) setState(() => _failed = true);
        return;
      }
      final crop = await cachedPlateCrop(id, bytes, bbox);
      if (!mounted || widget.read.id != id) return;
      setState(() {
        _crop = crop;
        _failed = crop == null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final crop = _crop;
    Widget child;
    if (crop != null) {
      child = Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: Image.memory(crop, fit: BoxFit.contain, gaplessPlayback: true),
      );
    } else if (_failed) {
      child = _PlateTile(plate: widget.read.plate, height: widget.height);
    } else {
      child = Container(color: Colors.black);
    }
    return MouseRegion(
      onEnter: (_) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        final topLeft = box.localToGlobal(Offset.zero);
        widget.onLoupe(widget.read, topLeft & box.size);
      },
      onExit: (_) => widget.onLoupe(widget.read, null),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: child,
        ),
      ),
    );
  }
}

/// A plate-looking tile with the plate text, for reads without a crop.
class _PlateTile extends StatelessWidget {
  const _PlateTile({required this.plate, required this.height});

  final String plate;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF6F5EF),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          plate.isEmpty ? '-' : plate,
          style: TextStyle(
            color: const Color(0xFF1D2B63),
            fontSize: (height * 0.42).clamp(9, 40).toDouble(),
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }
}

// ─── loupe ─────────────────────────────────────────────────────────────────

/// The read's full frame with its plate box outlined, sized to the frame's
/// own aspect (resolved from the image itself, so any camera resolution works).
class _FrameWithBox extends StatefulWidget {
  const _FrameWithBox({
    required this.bytes,
    required this.bbox,
    required this.width,
  });

  final Uint8List bytes;
  final List<double>? bbox;
  final double width;

  @override
  State<_FrameWithBox> createState() => _FrameWithBoxState();
}

class _FrameWithBoxState extends State<_FrameWithBox> {
  double? _aspect;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_FrameWithBox old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) _resolve();
  }

  void _resolve() {
    _detach();
    final stream = MemoryImage(widget.bytes).resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      final w = info.image.width;
      final h = info.image.height;
      if (mounted && h > 0) setState(() => _aspect = w / h);
    });
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  void _detach() {
    final l = _listener;
    if (l != null) _stream?.removeListener(l);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aspect = _aspect ?? 16 / 9;
    final b = widget.bbox;
    return SizedBox(
      width: widget.width,
      height: widget.width / aspect,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(widget.bytes, fit: BoxFit.fill, gaplessPlayback: true),
          if (b != null && b.length >= 4 && _aspect != null)
            Positioned(
              left: b[0] * widget.width,
              top: b[1] * widget.width / aspect,
              width: (b[2] * widget.width).clamp(2, widget.width),
              height: (b[3] * widget.width / aspect).clamp(2, widget.width),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: _kPink, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The hover loupe's content: the frame with the plate box, plus the crop
/// blown up beneath it.
class _LoupeCard extends StatelessWidget {
  const _LoupeCard({required this.read});

  final PlateRead read;

  @override
  Widget build(BuildContext context) {
    final eventId = read.eventId;
    final bytes = eventId == null ? null : _snapshotCache[eventId];
    final crop = peekPlateCrop(read.id);
    return Material(
      color: _kSurface1,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: _kPink),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (bytes != null)
              _FrameWithBox(bytes: bytes, bbox: read.bbox, width: 380)
            else
              Container(
                height: 120,
                color: Colors.black,
                alignment: Alignment.center,
                child: const Text(
                  'No frame for this read',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            if (crop != null)
              Container(
                color: Colors.black,
                height: 110,
                padding: const EdgeInsets.all(6),
                child: Image.memory(crop, fit: BoxFit.contain),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Text(
                read.plate.isEmpty ? '-' : read.plate,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── test hooks ────────────────────────────────────────────────────────────

/// One ledger row at [width], with no network (pass reads without an event
/// id). For layout tests: every density must lay out without overflow.
@visibleForTesting
Widget debugLedgerRow({
  required LedgerEntry entry,
  required PlateDensity density,
  required double width,
  PlateStats? stats,
  bool watched = false,
  bool selected = false,
  bool statsUnsupported = false,
}) {
  final m = densityMetrics(density);
  return SizedBox(
    width: width,
    height: m.rowExtent,
    child: _LedgerRow(
      entry: entry,
      m: m,
      cols: ledgerColumns(m, width),
      stats: stats,
      statsUnsupported: statsUnsupported,
      watched: watched,
      cameraName: 'Driveway LPR camera',
      selected: selected,
      expanded: false,
      api: CrumbApi(),
      session: Session(base: 'http://127.0.0.1:9', token: ''),
      gate: _ConcurrencyGate(1),
      canManage: true,
      canName: true,
      onTap: () {},
      onToggleExpand: () {},
      onAddToWatchlist: () {},
      onNamePlate: () {},
      onReport: () {},
      onLoupe: (_, _) {},
    ),
  );
}

/// The header and the column titles at [width], for layout tests.
@visibleForTesting
Widget debugDeskHeader(LprOverview overview, {required double width}) {
  return SizedBox(
    width: width,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DeskHeader(
          overview: overview,
          filter: DeskFilter.regulars,
          groupByPlate: false,
          onFilter: (_) {},
          onGroupByPlate: (_) {},
        ),
        for (final d in PlateDensity.values)
          _LedgerColumns(
            m: densityMetrics(d),
            cols: ledgerColumns(densityMetrics(d), width),
          ),
      ],
    ),
  );
}
