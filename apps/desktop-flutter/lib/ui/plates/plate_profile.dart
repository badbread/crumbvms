// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The plate profile: opened from any row or card, it covers the results area
// with everything known about one plate. Hero plate and crop, name (editable
// through the plate-label API) and watchlist star, first / last seen and
// counts, a 30-day activity strip, a 24-hour radial clock of when it usually
// comes, the camera breakdown, recent visits (reads within 5 minutes on one
// camera collapse into one visit), and a plain-English summary. History comes
// from POST /lpr/plates/stats (the screen's shared cache), visits from
// GET /plates?q=<plate>&match=exact. A `part` of plates_screen.dart.

part of 'plates_screen.dart';

/// Visits list: the newest reads of the plate fetched for the profile.
const _profileReadLimit = 200;

/// Main-column width from which the visits list sits beside the hero video.
const _profileSideBySideMin = 1100.0;
const _profileVisitsMinW = 320.0;
const _profileVisitsMaxW = 380.0;

/// Height of the caption bar under the hero video.
const _profileCaptionH = 32.0;

/// Most visits drawn in the profile.
const _profileMaxVisits = 40;

class _PlateProfile extends StatefulWidget {
  const _PlateProfile({
    super.key,
    required this.focus,
    required this.stats,
    required this.statsUnsupported,
    required this.displayName,
    required this.watchEntry,
    required this.cameraIds,
    required this.camName,
    required this.api,
    required this.session,
    required this.gate,
    required this.canManage,
    required this.canName,
    required this.onClose,
    required this.onPlay,
    required this.onTimeline,
    required this.onName,
    required this.onWatch,
    required this.onUnwatch,
    required this.onReport,
  });

  /// The read the profile was opened from (its plate is the profile's plate).
  final PlateRead focus;
  final PlateStats? stats;
  final bool statsUnsupported;
  final String? displayName;
  final PlateWatchlistEntry? watchEntry;

  /// Every camera this account can see (the visits search spans them all).
  final List<String> cameraIds;
  final String Function(String cameraId) camName;
  final CrumbApi api;
  final Session session;
  final _ConcurrencyGate gate;
  final bool canManage;
  final bool canName;
  final VoidCallback onClose;
  final ValueChanged<PlateRead> onPlay;
  final ValueChanged<PlateRead> onTimeline;
  final VoidCallback onName;
  final VoidCallback onWatch;
  final VoidCallback onUnwatch;
  final ValueChanged<PlateRead> onReport;

  @override
  State<_PlateProfile> createState() => _PlateProfileState();
}

class _PlateProfileState extends State<_PlateProfile> {
  List<PlateVisit> _visits = const [];
  List<PlateRead> _reads = const [];
  bool _loading = true;
  String? _error;

  /// The read whose clip the hero player shows: starts as the read the profile
  /// was opened from, then follows the visit row the operator clicks.
  late PlateRead _selected = widget.focus;
  final ScrollController _scroll = ScrollController();

  String get _plate => widget.focus.plate;

  @override
  void initState() {
    super.initState();
    _loadVisits();
  }

  @override
  void didUpdateWidget(_PlateProfile old) {
    super.didUpdateWidget(old);
    if (old.focus.plate != widget.focus.plate) {
      _selected = widget.focus;
      _loadVisits();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// A visit row was clicked: play that visit's best read in the hero player.
  void _selectRead(PlateRead r) {
    setState(() => _selected = r);
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _loadVisits() async {
    final plate = _plate;
    setState(() {
      _loading = true;
      _error = null;
      _visits = const [];
      _reads = const [];
    });
    if (plate.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    try {
      final page = await widget.api.listPlates(
        widget.session,
        cameraIds: widget.cameraIds,
        query: plate,
        match: 'exact',
        limit: _profileReadLimit,
      );
      if (!mounted || plate != _plate) return;
      setState(() {
        _reads = page.plates;
        _visits = collapseVisits(page.plates);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || plate != _plate) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // The mouse's Back button returns to the list, like Esc.
    return Listener(
      onPointerDown: (e) {
        if (e.buttons & kBackMouseButton != 0) widget.onClose();
      },
      child: Material(
        color: _kSurface0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 290, child: _aside(context)),
                  const VerticalDivider(width: 1, color: _kSurface2),
                  Expanded(child: _main(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The screen's title bar: a filled Back button, where you are, and how to
  /// get back. It replaces the list's controls so the profile can't be
  /// mistaken for part of the list.
  Widget _header() {
    final name = widget.displayName?.trim() ?? '';
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF262A33),
        border: Border(bottom: BorderSide(color: _kPink, width: 2)),
      ),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: widget.onClose,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Back to plates'),
            style: FilledButton.styleFrom(
              backgroundColor: _kPink,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
          const SizedBox(width: 18),
          const Text(
            'Plate profile',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
          Expanded(
            child: Text(
              name.isEmpty ? _plate : '$_plate  ·  $name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Flexible(
            child: Text(
              'Esc or mouse Back to return',
              maxLines: 1,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  // ── left column ──────────────────────────────────────────────────────────

  void _copyPlate(BuildContext context) {
    final plate = _plate;
    if (plate.isEmpty) return;
    Clipboard.setData(ClipboardData(text: plate));
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Copied $plate'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          width: 220,
        ),
      );
  }

  Widget _aside(BuildContext context) {
    final s = widget.stats;
    final read = widget.focus;
    final name = widget.displayName?.trim() ?? '';
    final watched = widget.watchEntry?.kind == 'watch';
    final hints = plateHints(s, read.ts);
    final crop = peekPlateCrop(read.id);
    final now = DateTime.now();
    final confs = [
      for (final r in _reads)
        if (r.confidence != null) r.confidence!,
    ];
    final avg = confs.isEmpty
        ? null
        : confs.reduce((a, b) => a + b) / confs.length;
    final kind = s == null
        ? null
        : s.isNew
        ? 'First-time'
        : s.isRegular
        ? 'Regular'
        : 'Returning';
    final sub = [
      ?kind,
      if (read.region != null && read.region!.isNotEmpty) read.region!,
      if (avg != null) '${(avg * 100).round()}% avg confidence',
    ].join('  ·  ');
    Widget fact(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(k, style: const TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              v,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
    final dash = widget.statsUnsupported ? '-' : '';
    return Container(
      color: _kSurface1,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        children: [
          // Click to copy the plate (the text is also selectable).
          Tooltip(
            message: 'Click to copy',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _copyPlate(context),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: 78,
                    child: _PlateTile(
                      plate: _plate,
                      height: 78,
                      selectable: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (crop != null) ...[
            const SizedBox(height: 8),
            // The crop at the column's full width in its own shape: a fixed
            // black box letterboxed it into a small strip with wide bars.
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(
                crop,
                width: double.infinity,
                fit: BoxFit.fitWidth,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  name.isEmpty ? 'Unnamed plate' : name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: name.isEmpty ? Colors.white38 : Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (canOfferPlateName(isAdmin: widget.canName, plate: _plate))
                IconButton(
                  tooltip: plateNameActionTooltip(widget.displayName),
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onName,
                  icon: const Icon(
                    Icons.edit_outlined,
                    size: 18,
                    color: Colors.white54,
                  ),
                ),
              if (widget.canManage && _plate.isNotEmpty)
                IconButton(
                  tooltip: watched
                      ? 'Remove from the watchlist'
                      : 'Add to the watchlist',
                  visualDensity: VisualDensity.compact,
                  onPressed: watched ? widget.onUnwatch : widget.onWatch,
                  icon: Icon(
                    watched ? Icons.star : Icons.star_border,
                    size: 20,
                    color: watched ? _kAmber : Colors.white54,
                  ),
                )
              else if (watched)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.star, size: 20, color: _kAmber),
                ),
            ],
          ),
          if (sub.isNotEmpty)
            Text(
              sub,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          if (hints.isNew || hints.showToday || hints.unusualHour || watched)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                runSpacing: 4,
                children: [
                  if (hints.isNew) _tag('NEW', _kGreen),
                  if (watched) _tag('WATCHLIST', _kPink),
                  if (hints.showToday)
                    _tag('${hints.todayCount}x TODAY', _kPink),
                  if (hints.unusualHour) _tag('UNUSUAL HOUR', _kAmber),
                ],
              ),
            ),
          const SizedBox(height: 14),
          fact('First seen', s == null ? dash : _fmtDate(s.firstSeen)),
          fact('Last seen', s == null ? dash : _fmtWhen(s.lastSeen, now)),
          fact('Seen total', s == null ? dash : '${s.total}'),
          fact('Last 30 days', s == null ? dash : '${s.seen30d}'),
          fact('Last 7 days', s == null ? dash : '${s.seen7d}'),
          fact('Cameras', s == null ? dash : '${s.cameras.length}'),
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (read.eventId != null && read.eventId!.isNotEmpty)
                _ProfileButton(
                  icon: Icons.play_arrow,
                  label: 'Full-screen clip',
                  primary: true,
                  onTap: () => widget.onPlay(_selected),
                ),
              _ProfileButton(
                icon: Icons.timeline,
                label: 'View on timeline',
                onTap: () => widget.onTimeline(_selected),
              ),
              if (plateCopyText(read).isNotEmpty)
                _ProfileButton(
                  icon: Icons.content_copy_outlined,
                  label: 'Copy plate',
                  onTap: () =>
                      copyPlateToClipboard(context, plateCopyText(read)),
                ),
              _ProfileButton(
                icon: Icons.description_outlined,
                label: 'Report',
                onTap: () => widget.onReport(read),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── right column ─────────────────────────────────────────────────────────

  Widget _main(BuildContext context) {
    final s = widget.stats;
    final summary = s == null
        ? null
        : plateSummary(s, camName: widget.camName, focus: widget.focus.ts);
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 640;
        // Wide screens: the visits list sits beside the hero video instead of
        // below the stats, so the video needs no letterbox bars.
        final side = c.maxWidth >= _profileSideBySideMin;
        final avail = c.maxWidth - 44;
        final left = <Widget>[
          _card('Last 30 days', _daysStrip(s)),
          _card('Cameras', _cameraBreakdown(s)),
        ];
        final clock = _card('Hour of day', _clock(s));
        return ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
          children: [
            if (side) _heroRow(avail, c.maxHeight, s) else _hero(avail),
            if (summary != null && summary.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: BoxDecoration(
                  color: _kPink.withValues(alpha: 0.12),
                  border: const Border(
                    left: BorderSide(color: _kPink, width: 3),
                  ),
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(8),
                    bottomRight: Radius.circular(8),
                  ),
                ),
                child: Text(
                  summary,
                  style: const TextStyle(color: Colors.white, fontSize: 12.5),
                ),
              ),
            if (s == null && widget.statsUnsupported)
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text(
                  'This server does not report plate history. Update the '
                  'Crumb server to see counts, charts and the summary.',
                  style: TextStyle(color: Colors.white38),
                ),
              ),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Column(children: left)),
                  const SizedBox(width: 14),
                  SizedBox(width: 250, child: clock),
                ],
              )
            else ...[
              ...left,
              clock,
            ],
            if (!side)
              _card(
                'Recent visits (click one to play it above)',
                _visitsList(s),
              ),
          ],
        );
      },
    );
  }

  /// Wide layout: the clip at its own 16:9 (no black side bars) with the
  /// visits panel to its right, the same height, scrolling internally.
  Widget _heroRow(double avail, double maxHeight, PlateStats? s) {
    const gap = 14.0;
    final budget = (maxHeight.isFinite ? maxHeight * 0.58 : 460.0).clamp(
      260.0,
      560.0,
    );
    var videoW = budget * 16 / 9;
    final maxVideoW = avail - gap - _profileVisitsMinW;
    if (videoW > maxVideoW) videoW = maxVideoW;
    final videoH = videoW * 9 / 16;
    final panelW = (avail - videoW - gap).clamp(
      _profileVisitsMinW,
      _profileVisitsMaxW,
    );
    final totalH = videoH + _profileCaptionH + 2;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: videoW,
            child: _hero(videoW, videoHeight: videoH, bottomMargin: 0),
          ),
          const SizedBox(width: gap),
          Container(
            key: const ValueKey('profile-visits'),
            width: panelW,
            height: totalH,
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 8),
            decoration: BoxDecoration(
              color: _kSurface1,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'RECENT VISITS',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(right: 6),
                    child: _visitsList(s),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The hero: the selected read's clip, large, at the top of the column.
  Widget _hero(double width, {double? videoHeight, double bottomMargin = 14}) {
    final r = _selected;
    final hasClip = r.eventId != null && r.eventId!.isNotEmpty;
    final h = videoHeight ?? (width * 9 / 16).clamp(180.0, 480.0);
    final now = DateTime.now();
    return Container(
      key: const ValueKey('profile-hero'),
      margin: EdgeInsets.only(bottom: bottomMargin),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _kSurface2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: h,
            child: hasClip
                ? _InlineClip(
                    key: ValueKey('inline:${r.id}'),
                    api: widget.api,
                    session: widget.session,
                    read: r,
                  )
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'No clip for this read.',
                          style: TextStyle(color: Colors.white54),
                        ),
                        const SizedBox(height: 8),
                        _ProfileButton(
                          icon: Icons.timeline,
                          label: 'View on timeline',
                          onTap: () => widget.onTimeline(r),
                        ),
                      ],
                    ),
                  ),
          ),
          Container(
            color: _kSurface1,
            height: _profileCaptionH,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '${widget.camName(r.cameraId)}  ·  ${_fmtWhen(r.ts, now)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(String title, Widget child) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _kSurface1,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );

  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(text, style: const TextStyle(color: Colors.white38)),
  );

  Widget _daysStrip(PlateStats? s) {
    if (s == null) return _empty(widget.statsUnsupported ? '-' : 'Loading...');
    return _DayBarsChart(days: s.days30, total: s.seen30d);
  }

  Widget _cameraBreakdown(PlateStats? s) {
    if (s == null) return _empty(widget.statsUnsupported ? '-' : 'Loading...');
    if (s.cameras.isEmpty) return _empty('No reads.');
    final maxN = s.cameras.first.n.clamp(1, 1 << 30);
    const colors = [_kGreen, _kPink, _kAmber, _kSlate];
    return Column(
      children: [
        for (var i = 0; i < s.cameras.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 130,
                  child: Text(
                    widget.camName(s.cameras[i].cameraId),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: (c.maxWidth * s.cameras[i].n / maxN).clamp(
                          3.0,
                          c.maxWidth,
                        ),
                        height: 8,
                        decoration: BoxDecoration(
                          color: colors[i % colors.length],
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    '${s.cameras[i].n}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _clock(PlateStats? s) {
    if (s == null) return _empty(widget.statsUnsupported ? '-' : 'Loading...');
    final focusHour = widget.focus.ts.toLocal().hour;
    final unusual = isUnusualHour(s.hours, focusHour);
    return Column(
      children: [
        _HourClock(hours: s.hours, highlight: unusual ? focusHour : null),
        if (unusual)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Amber: the hour of this read, which is unusual',
              style: TextStyle(color: _kAmber, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Widget _visitsList(PlateStats? s) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_error != null) return _empty("Couldn't load visits: $_error");
    if (_visits.isEmpty) return _empty('No reads of this plate.');
    final now = DateTime.now();
    final shown = _visits.take(_profileMaxVisits).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final v in shown) _visitRow(v, s, now),
        if (_visits.length > shown.length || _reads.length >= _profileReadLimit)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Showing the latest ${shown.length} visits.',
              style: const TextStyle(color: Colors.white24, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Widget _visitRow(PlateVisit v, PlateStats? s, DateTime now) {
    final best = v.best;
    final unusual = s != null && isUnusualHour(s.hours, v.end.toLocal().hour);
    final span = v.end.difference(v.start);
    final when = span.inMinutes >= 1
        ? '${_dayLabelCap(v.end, now)} ${_fmtClock(v.start)} to ${_fmtClock(v.end)}'
        : '${_dayLabelCap(v.end, now)} ${_fmtClock(v.end)}';
    final conf = v.bestConfidence == null
        ? ''
        : ', ${(v.bestConfidence! * 100).round()}%';
    final hasClip = best.eventId != null && best.eventId!.isNotEmpty;
    final playing = v.reads.any((r) => r.id == _selected.id);
    return InkWell(
      onTap: () => hasClip ? _selectRead(best) : widget.onTimeline(best),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        decoration: BoxDecoration(
          color: playing ? _kPink.withValues(alpha: 0.14) : null,
          border: Border(
            top: const BorderSide(color: _kSurface2),
            left: BorderSide(
              color: playing ? _kPink : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            _FrameCell(
              read: best,
              width: 74,
              height: 42,
              session: widget.session,
              gate: widget.gate,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _clipRow([
                Text(
                  when,
                  style: const TextStyle(color: Colors.white, fontSize: 12.5),
                ),
                const SizedBox(width: 10),
                Text(
                  '${widget.camName(v.cameraId)}  ·  '
                  '${v.count} read${v.count == 1 ? '' : 's'}$conf',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                if (unusual) _tag('UNUSUAL HOUR', _kAmber),
              ]),
            ),
            Tooltip(
              message: hasClip ? 'Play above' : 'View on timeline',
              child: Icon(
                hasClip
                    ? (playing ? Icons.play_circle : Icons.play_circle_outline)
                    : Icons.timeline,
                size: 18,
                color: playing ? _kPink : Colors.white38,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _dayLabelCap(DateTime t, DateTime now) {
  final d = _dayLabel(t, now);
  return d.isEmpty ? d : d[0].toUpperCase() + d.substring(1);
}

/// "Mar 14, 2026".
String _fmtDate(DateTime t) {
  final l = t.toLocal();
  return '${_months[l.month - 1]} ${l.day}, ${l.year}';
}

/// "Today 5:42 PM", "Yesterday 9:10 AM", "Jun 3 9:10 AM".
String _fmtWhen(DateTime t, DateTime now) =>
    '${_dayLabelCap(t, now)} ${_fmtClock(t)}';

class _ProfileButton extends StatelessWidget {
  const _ProfileButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: primary ? _kPink : _kSurface2,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The profile at a given size with no server (the visits fetch fails fast
/// under test), for layout tests.
@visibleForTesting
Widget debugPlateProfile({
  required PlateRead focus,
  PlateStats? stats,
  bool watched = false,
}) {
  return _PlateProfile(
    focus: focus,
    stats: stats,
    statsUnsupported: stats == null,
    displayName: focus.displayName,
    watchEntry: watched
        ? PlateWatchlistEntry.fromJson({
            'id': 'w',
            'plate': focus.plate,
            'kind': 'watch',
            'notify': true,
            'created_at': '2026-01-01T00:00:00Z',
          })
        : null,
    cameraIds: const ['cam'],
    camName: (id) => 'A camera with a fairly long name $id',
    api: CrumbApi(),
    session: Session(base: 'http://127.0.0.1:9', token: ''),
    gate: _ConcurrencyGate(1),
    canManage: true,
    canName: true,
    onClose: () {},
    onPlay: (_) {},
    onTimeline: (_) {},
    onName: () {},
    onWatch: () {},
    onUnwatch: () {},
    onReport: (_) {},
  );
}

/// The profile's hero player: plays [read]'s detection clip inline (muted,
/// autoplay, with media_kit's standard transport controls). Resolves the clip
/// like the pop-up [_PlateClipPlayer]: `/clip/d:<event>/clip.mp4` on a scoped
/// media `?token=`. Key it by the read so switching reads builds a fresh Video
/// (media_kit binds the controller only in initState). Any failure to resolve
/// or open (offline, tests) degrades to a text placeholder.
class _InlineClip extends StatefulWidget {
  const _InlineClip({
    super.key,
    required this.api,
    required this.session,
    required this.read,
  });

  final CrumbApi api;
  final Session session;
  final PlateRead read;

  @override
  State<_InlineClip> createState() => _InlineClipState();
}

class _InlineClipState extends State<_InlineClip> {
  Player? _player;
  VideoController? _controller;
  String? _error;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final id = Uri.encodeComponent('d:${widget.read.eventId}');
      final url = await widget.api.mediaUrlForCamera(
        widget.session,
        widget.read.cameraId,
        '/clip/$id/clip.mp4?q=preview',
      );
      if (_disposed || !mounted) return;
      if (url == null) {
        setState(() => _error = 'Could not authorize this clip.');
        return;
      }
      final player = Player();
      final controller = VideoController(player);
      setState(() {
        _player = player;
        _controller = controller;
      });
      await player.setVolume(0);
      await player.open(Media(url));
      await player.play();
    } catch (_) {
      if (mounted && !_disposed) {
        setState(() => _error = 'Clip unavailable.');
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final p = _player;
    if (p != null) {
      // Dispose after the frame so the Video widget has let go of the
      // controller first.
      WidgetsBinding.instance.addPostFrameCallback((_) => p.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Colors.white54)),
      );
    }
    final c = _controller;
    if (c == null) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Video(controller: c, fit: BoxFit.contain);
  }
}
