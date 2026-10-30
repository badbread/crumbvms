// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The grid view ("contact sheet"): fixed-size cards with the camera frame as
// the hero and the plate crop as a picture-in-picture inset (size, corner and
// on/off are real controls), stats chips, a stacked look for a plate with
// several passes when grouped by plate, hover actions, and a round hover
// magnifier over the frame (2x / 3x). "Tall cards" adds the plate's 24-hour
// histogram. A `part` of plates_screen.dart.

part of 'plates_screen.dart';

/// Card geometry. Every card in a sheet has the same extent, so the grid
/// lays out without measuring.
const double _kCardMaxWidth = 260;
const double _kCardFrameHeight = 140;
const double _kCardFooter = 70;
const double _kCardHistogram = 50;

/// Includes the 10 px the stacked-card shadow needs.
double _cardExtent(bool tall) =>
    _kCardFrameHeight + _kCardFooter + (tall ? _kCardHistogram : 0) + 10;

/// Inset width as a fraction of the card width, per size: clearly different
/// steps.
double _insetFraction(PlateCropSize s) => switch (s) {
  PlateCropSize.small => 0.30,
  PlateCropSize.medium => 0.45,
  PlateCropSize.large => 0.62,
};

/// The control row above the sheet.
class _SheetControls extends StatelessWidget {
  const _SheetControls({
    required this.size,
    required this.corner,
    required this.display,
    required this.loupe,
    required this.tall,
    required this.onSize,
    required this.onCorner,
    required this.onDisplay,
    required this.onLoupe,
    required this.onTall,
  });

  final PlateCropSize size;
  final PlateCropCorner corner;
  final PlateImageDisplay display;
  final int loupe; // 0 = off, 2, 3
  final bool tall;
  final ValueChanged<PlateCropSize> onSize;
  final ValueChanged<PlateCropCorner> onCorner;
  final ValueChanged<PlateImageDisplay> onDisplay;
  final ValueChanged<int> onLoupe;
  final ValueChanged<bool> onTall;

  @override
  Widget build(BuildContext context) {
    final insetOn = display != PlateImageDisplay.fullOnly;
    Widget label(String t) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Text(
        t,
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
    );
    return Container(
      color: _kSurface0,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Wrap(
        spacing: 18,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              label('Show'),
              _Seg<PlateImageDisplay>(
                value: insetOn
                    ? PlateImageDisplay.both
                    : PlateImageDisplay.fullOnly,
                options: const [
                  (PlateImageDisplay.both, 'Inset'),
                  (PlateImageDisplay.fullOnly, 'Frame only'),
                ],
                onChanged: onDisplay,
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              label('Inset size'),
              _Seg<PlateCropSize>(
                value: size,
                enabled: insetOn,
                options: const [
                  (PlateCropSize.small, 'S'),
                  (PlateCropSize.medium, 'M'),
                  (PlateCropSize.large, 'L'),
                ],
                onChanged: onSize,
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              label('Inset corner'),
              _Seg<PlateCropCorner>(
                value: corner,
                enabled: insetOn,
                options: const [
                  (PlateCropCorner.topLeft, 'TL'),
                  (PlateCropCorner.topRight, 'TR'),
                  (PlateCropCorner.bottomLeft, 'BL'),
                  (PlateCropCorner.bottomRight, 'BR'),
                ],
                onChanged: onCorner,
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              label('Loupe'),
              _Seg<int>(
                value: loupe,
                options: const [(0, 'Off'), (2, '2x'), (3, '3x')],
                onChanged: onLoupe,
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              label('Tall cards'),
              _Seg<bool>(
                value: tall,
                options: const [(false, 'Off'), (true, 'On')],
                onChanged: onTall,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A small segmented control.
class _Seg<T> extends StatelessWidget {
  const _Seg({
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (v, text) in options)
              InkWell(
                onTap: enabled ? () => onChanged(v) : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  color: v == value ? _kPink : _kSurface2,
                  child: Text(
                    text,
                    style: TextStyle(
                      color: v == value ? Colors.white : Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SheetCard extends StatefulWidget {
  const _SheetCard({
    super.key,
    required this.entry,
    required this.stats,
    required this.watched,
    required this.cameraName,
    required this.selected,
    required this.insetSize,
    required this.insetCorner,
    required this.showInset,
    required this.loupe,
    required this.tall,
    required this.session,
    required this.gate,
    required this.canManage,
    required this.canName,
    required this.onTap,
    required this.onAddToWatchlist,
    required this.onNamePlate,
    required this.onReport,
  });

  final LedgerEntry entry;
  final PlateStats? stats;
  final bool watched;
  final String cameraName;
  final bool selected;
  final PlateCropSize insetSize;
  final PlateCropCorner insetCorner;
  final bool showInset;
  final int loupe;
  final bool tall;
  final Session session;
  final _ConcurrencyGate gate;
  final bool canManage;
  final bool canName;
  final VoidCallback onTap;
  final VoidCallback onAddToWatchlist;
  final VoidCallback onNamePlate;
  final VoidCallback onReport;

  @override
  State<_SheetCard> createState() => _SheetCardState();
}

class _SheetCardState extends State<_SheetCard> {
  Uint8List? _frame;
  Uint8List? _crop;
  bool _hover = false;
  Offset? _pointer; // over the frame, for the magnifier

  PlateRead get _read => widget.entry.group.representative;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_SheetCard old) {
    super.didUpdateWidget(old);
    if (old.entry.group.representative.id != _read.id) {
      _frame = null;
      _crop = null;
      _load();
    }
  }

  void _load() {
    final read = _read;
    final eventId = read.eventId;
    if (eventId == null || eventId.isEmpty) return;
    _crop = peekPlateCrop(read.id);
    final cached = _snapshotCache[eventId];
    if (cached != null) {
      _frame = cached;
      _cropFrom(cached);
      return;
    }
    _loadSnapshot(widget.session, eventId, widget.gate).then((b) {
      if (!mounted || b == null || _read.id != read.id) return;
      setState(() => _frame = b);
      _cropFrom(b);
    });
  }

  void _cropFrom(Uint8List bytes) {
    final read = _read;
    final bbox = read.bbox;
    if (_crop != null || bbox == null || bbox.length < 4) return;
    cachedPlateCrop(read.id, bytes, bbox).then((c) {
      if (mounted && c != null && _read.id == read.id) {
        setState(() => _crop = c);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final read = _read;
    final s = widget.stats;
    final bundle = widget.entry.bundle;
    final stacked = bundle != null && bundle.passCount > 1;
    final hints = plateHints(s, read.ts);
    final rail = _railColor(plateRail(watched: widget.watched, stats: s));
    final card = Container(
      decoration: BoxDecoration(
        color: _kSurface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: widget.selected || _hover
              ? _kPink
              : (rail ?? _kSurface2).withValues(alpha: rail == null ? 1 : 0.7),
        ),
        boxShadow: stacked
            ? const [
                BoxShadow(color: _kSurface2, offset: Offset(5, 5)),
                BoxShadow(color: _kSurface1, offset: Offset(10, 10)),
              ]
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _kCardFrameHeight,
            child: LayoutBuilder(
              builder: (context, c) => _frameArea(c.maxWidth, stacked, hints),
            ),
          ),
          Expanded(child: _footer(read, s, hints)),
        ],
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pointer = null;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          // Room for the stacked shadow.
          padding: const EdgeInsets.only(right: 10, bottom: 10),
          child: card,
        ),
      ),
    );
  }

  Widget _frameArea(double w, bool stacked, PlateHints hints) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final frame = _frame;
    final read = _read;
    final bundle = widget.entry.bundle;
    Widget frameImage(double scale) => SizedBox(
      width: w,
      height: _kCardFrameHeight,
      child: frame == null
          ? Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: const Icon(
                Icons.directions_car_outlined,
                color: Colors.white12,
                size: 34,
              ),
            )
          : Image.memory(
              frame,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              cacheWidth: (w * dpr * scale).round().clamp(1, 2560),
            ),
    );
    final insetW = w * _insetFraction(widget.insetSize);
    final insetH = (insetW / 3).clamp(18.0, _kCardFrameHeight * 0.5);
    final crop = _crop;
    final inset = Container(
      width: insetW,
      height: insetH,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _kPink, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 8)],
      ),
      clipBehavior: Clip.antiAlias,
      child: crop != null
          ? Image.memory(crop, fit: BoxFit.contain, gaplessPlayback: true)
          : _PlateTile(plate: read.plate, height: insetH),
    );
    final corner = widget.insetCorner;
    final top =
        corner == PlateCropCorner.topLeft || corner == PlateCropCorner.topRight;
    final left =
        corner == PlateCropCorner.topLeft ||
        corner == PlateCropCorner.bottomLeft;
    final p = _pointer;
    final zoom = widget.loupe;
    const loupeD = 104.0;
    return MouseRegion(
      cursor: zoom > 0 ? SystemMouseCursors.zoomIn : MouseCursor.defer,
      onHover: zoom > 0 && frame != null
          ? (e) => setState(() => _pointer = e.localPosition)
          : null,
      onExit: (_) => setState(() => _pointer = null),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(child: frameImage(1)),
          if (widget.showInset)
            Positioned(
              top: top ? 8 : null,
              bottom: top ? null : 8,
              left: left ? 8 : null,
              right: left ? null : 8,
              child: inset,
            ),
          // The camera name sits in a corner the inset is not using.
          Positioned(
            bottom: 6,
            left: (widget.showInset && !top && left) ? null : 8,
            right: (widget.showInset && !top && left) ? 8 : null,
            child: Text(
              widget.cameraName,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
                shadows: [Shadow(blurRadius: 3)],
              ),
            ),
          ),
          if (stacked)
            Positioned(
              top: 8,
              left: (widget.showInset && top && left) ? null : 8,
              right: (widget.showInset && top && left) ? 8 : null,
              child: _badge('${bundle!.readCount} reads'),
            )
          else if (hints.showToday)
            Positioned(
              top: 8,
              left: (widget.showInset && top && left) ? null : 8,
              right: (widget.showInset && top && left) ? 8 : null,
              child: _badge('x${hints.todayCount} today'),
            ),
          if (_hover && p == null)
            Positioned(
              top: 6,
              left: 0,
              right: 0,
              child: Center(child: _hoverActions(read)),
            ),
          if (p != null && frame != null)
            Positioned(
              left: (p.dx - loupeD / 2).clamp(0.0, w - loupeD),
              top: (p.dy - loupeD - 8).clamp(0.0, _kCardFrameHeight - loupeD),
              child: IgnorePointer(
                child: Container(
                  width: loupeD,
                  height: loupeD,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: _kPink, width: 2),
                    boxShadow: const [
                      BoxShadow(color: Colors.black, blurRadius: 12),
                    ],
                  ),
                  child: ClipOval(
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: 0,
                      minHeight: 0,
                      maxWidth: double.infinity,
                      maxHeight: double.infinity,
                      child: Transform(
                        transform: Matrix4.identity()
                          ..translateByDouble(
                            loupeD / 2 - p.dx * zoom,
                            loupeD / 2 - p.dy * zoom,
                            0,
                            1,
                          )
                          ..scaleByDouble(
                            zoom.toDouble(),
                            zoom.toDouble(),
                            1,
                            1,
                          ),
                        child: frameImage(zoom.toDouble()),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: _kPink,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _hoverActions(PlateRead read) {
    Widget btn(String tip, IconData icon, VoidCallback? onTap, {Color? c}) =>
        Tooltip(
          message: tip,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              child: Icon(icon, size: 16, color: c ?? Colors.white),
            ),
          ),
        );
    final copy = plateCopyText(read);
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (copy.isNotEmpty)
            btn(
              'Copy plate',
              Icons.content_copy_outlined,
              () => copyPlateToClipboard(context, copy),
            ),
          if (canOfferPlateName(isAdmin: widget.canName, plate: read.plate))
            btn(
              plateNameActionTooltip(read.displayName),
              Icons.label_outline,
              widget.onNamePlate,
            ),
          if (widget.canManage && read.plate.isNotEmpty)
            btn(
              widget.watched ? 'On watchlist' : 'Add to watchlist',
              widget.watched ? Icons.star : Icons.star_border,
              widget.watched ? null : widget.onAddToWatchlist,
              c: widget.watched ? _kAmber : null,
            ),
          btn('Report (PDF)', Icons.description_outlined, widget.onReport),
        ],
      ),
    );
  }

  Widget _footer(PlateRead read, PlateStats? s, PlateHints hints) {
    final name = read.displayName?.trim() ?? '';
    Widget chip(String text, {Color? c}) => Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: (c ?? Colors.white).withValues(alpha: c == null ? 0.08 : 0.2),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        text,
        style: TextStyle(color: c ?? Colors.white70, fontSize: 10.5),
      ),
    );
    final now = DateTime.now();
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  read.plate.isEmpty ? '-' : read.plate,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              Text(
                '${_fmtClock(read.ts)}  ${_dayLabel(read.ts, now)}',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 5),
          _clipRow([
            if (s != null) chip('seen ${s.total}x'),
            if (s?.prevSeen != null) chip('last ${fmtAgo(s!.prevSeen!, now)}'),
            if (hints.isNew) chip('NEW', c: _kGreen),
            if (widget.watched) chip('Watchlist', c: _kPink),
            if (s != null && s.isRegular) chip('Regular', c: _kAmber),
            if (hints.unusualHour) chip('Unusual hour', c: _kAmber),
            if (name.isNotEmpty) chip(name, c: _kGreen),
          ]),
          if (widget.tall) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 26,
              child: s == null
                  ? const SizedBox.shrink()
                  : CustomPaint(
                      painter: _HourBarsPainter(
                        s.hours,
                        now: read.ts.toLocal().hour,
                      ),
                    ),
            ),
            const SizedBox(height: 2),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '0h',
                  style: TextStyle(color: Colors.white24, fontSize: 9),
                ),
                Text(
                  '12h',
                  style: TextStyle(color: Colors.white24, fontSize: 9),
                ),
                Text(
                  '24h',
                  style: TextStyle(color: Colors.white24, fontSize: 9),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 24 hour-of-day bars; [now] (the read's hour) is drawn solid.
class _HourBarsPainter extends CustomPainter {
  _HourBarsPainter(this.hours, {this.now});

  final List<int> hours;
  final int? now;

  @override
  void paint(Canvas canvas, Size size) {
    if (hours.isEmpty) return;
    final maxV = hours.fold<int>(1, (a, b) => b > a ? b : a);
    final slot = size.width / 24;
    for (var h = 0; h < 24 && h < hours.length; h++) {
      final v = hours[h];
      final bh = v == 0 ? 1.5 : 2 + (size.height - 2) * v / maxV;
      canvas.drawRect(
        Rect.fromLTWH(h * slot + 0.5, size.height - bh, slot - 1, bh),
        Paint()..color = h == now ? _kGreen : _kGreen.withValues(alpha: 0.35),
      );
    }
  }

  @override
  bool shouldRepaint(_HourBarsPainter old) =>
      old.now != now || !listEquals(old.hours, hours);
}

/// One sheet card at [width] with no network, for layout tests.
@visibleForTesting
Widget debugSheetCard({
  required LedgerEntry entry,
  required double width,
  PlateStats? stats,
  bool tall = false,
  PlateCropSize size = PlateCropSize.large,
  PlateCropCorner corner = PlateCropCorner.bottomLeft,
}) {
  return SizedBox(
    width: width,
    height: _cardExtent(tall),
    child: _SheetCard(
      entry: entry,
      stats: stats,
      watched: true,
      cameraName: 'Driveway LPR camera',
      selected: true,
      insetSize: size,
      insetCorner: corner,
      showInset: true,
      loupe: 2,
      tall: tall,
      session: Session(base: 'http://127.0.0.1:9', token: ''),
      gate: _ConcurrencyGate(1),
      canManage: true,
      canName: true,
      onTap: () {},
      onAddToWatchlist: () {},
      onNamePlate: () {},
      onReport: () {},
    ),
  );
}
