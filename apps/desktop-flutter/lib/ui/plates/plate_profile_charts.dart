// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The plate profile's two interactive charts: the 30-day bars and the 24-hour
// radial clock. Each is a small StatefulWidget that owns its animation, so a
// hover repaints only the chart (the painters listen to the controllers via
// CustomPaint.repaint) and never rebuilds the profile. Both grow in on first
// show (staggered), highlight the hovered bar / wedge in hot pink while the
// rest dim, and show the hovered number. Reduced motion
// (MediaQuery.disableAnimations) skips the intro and snaps every transition.
// A `part` of plates_screen.dart.

part of 'plates_screen.dart';

const _kHotPink = Color(0xFFF06A9C);
const _kTipBg = Color(0xFF262A33);
const _kTipBorder = Color(0xFF3A3F4B);

/// A set of values that glide from where they currently are to a new target
/// over [duration], on one controller. Read with [at]; listen via [listenable].
class _Glide {
  _Glide(TickerProvider vsync, int n, {required this.duration})
    : _from = List<double>.filled(n, 0),
      _to = List<double>.filled(n, 0),
      _c = AnimationController(vsync: vsync, value: 1);

  final Duration duration;
  final AnimationController _c;
  List<double> _from;
  List<double> _to;

  Listenable get listenable => _c;

  double at(int i) {
    final t = Curves.easeInOutCubic.transform(_c.value);
    return _from[i] + (_to[i] - _from[i]) * t;
  }

  /// Retarget; [instant] snaps (reduced motion).
  void to(List<double> target, {required bool instant}) {
    _from = [for (var i = 0; i < _to.length; i++) at(i)];
    _to = target;
    if (instant) {
      _from = List<double>.of(target);
      _c.value = 1;
    } else {
      _c.duration = duration;
      _c.forward(from: 0);
    }
  }

  void dispose() => _c.dispose();
}

const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _mo = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _tipDate(DateTime d, bool today) =>
    today ? 'Today' : '${_wd[d.weekday - 1]}, ${_mo[d.month - 1]} ${d.day}';

int _countUp(int from, int to, double t) =>
    (from + (to - from) * Curves.easeOutCubic.transform(t)).round();

// ─── 30-day bars ───────────────────────────────────────────────────────────

/// The "last 30 days" bars with their footer row.
class _DayBarsChart extends StatefulWidget {
  const _DayBarsChart({required this.days, required this.total});

  final List<int> days;
  final int total;

  @override
  State<_DayBarsChart> createState() => _DayBarsChartState();
}

class _DayBarsChartState extends State<_DayBarsChart>
    with TickerProviderStateMixin {
  static const _stagger = 18, _grow = 300;

  late final AnimationController _intro;
  late final _Glide _hover; // [0..n) emphasis, [n] any-hover, [n+1] tooltip x
  late final AnimationController _count;
  int? _idx; // hovered column
  int _last = 0; // last hovered: the tooltip stays put while it fades out
  int _countFrom = 0;
  bool _reduced = false;
  bool _started = false;

  int get _n => widget.days.length;

  @override
  void initState() {
    super.initState();
    _hover = _Glide(this, _n + 2, duration: const Duration(milliseconds: 250));
    _count = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
    _intro = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: _stagger * (_n > 0 ? _n - 1 : 0) + _grow,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!_started) {
      _started = true;
      _reduced ? _intro.value = 1 : _intro.forward();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _hover.dispose();
    _count.dispose();
    super.dispose();
  }

  void _set(int? i) {
    if (i == _idx || _n == 0) return;
    final shown = widget.days[_last];
    setState(() {
      _idx = i;
      if (i != null) {
        _countFrom = _countUp(_countFrom, shown, _count.value);
        _last = i;
      }
    });
    if (i != null) _reduced ? _count.value = 1 : _count.forward(from: 0);
    _hover.to([
      for (var k = 0; k < _n; k++) k == i ? 1.0 : 0.0,
      i == null ? 0.0 : 1.0,
      i == null ? _hover.at(_n + 1) : i.toDouble(),
    ], instant: _reduced);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final first = now.subtract(const Duration(days: 29));
    final hoverDate = _idx == null
        ? null
        : _tipDate(
            now.subtract(Duration(days: _n - 1 - _idx!)),
            _idx == _n - 1,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 64,
          child: LayoutBuilder(
            builder: (context, c) {
              final slot = _n == 0 ? 1.0 : c.maxWidth / _n;
              void hit(Offset p) {
                if (_n == 0) return;
                _set((p.dx / slot).floor().clamp(0, _n - 1));
              }

              return MouseRegion(
                onEnter: (e) => hit(e.localPosition),
                onHover: (e) => hit(e.localPosition),
                onExit: (_) => _set(null),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _DayBarsPainter(
                          widget.days,
                          intro: _intro,
                          hover: _hover,
                        ),
                      ),
                    ),
                    if (_n > 0) _tooltip(slot, now),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              fmtShortDate(first, now),
              style: const TextStyle(color: Colors.white24, fontSize: 10),
            ),
            const Spacer(),
            Text(
              hoverDate ?? '${widget.total} reads',
              style: TextStyle(
                color: hoverDate == null ? Colors.white38 : _kHotPink,
                fontSize: 10,
              ),
            ),
            const Spacer(),
            const Text(
              'today',
              style: TextStyle(color: Colors.white24, fontSize: 10),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tooltip(double slot, DateTime now) {
    final maxV = widget.days.fold<int>(1, (a, b) => b > a ? b : a);
    return AnimatedBuilder(
      animation: Listenable.merge([_hover.listenable, _count]),
      builder: (context, _) {
        final a = _hover.at(_n).clamp(0.0, 1.0);
        if (a <= 0.001) return const SizedBox.shrink();
        final x = _hover.at(_n + 1);
        final v = widget.days[_last];
        final h = v == 0 ? 2.0 : 3 + (64 - 3) * v / maxV;
        final n = _countUp(_countFrom, v, _count.value);
        final date = _tipDate(
          now.subtract(Duration(days: _n - 1 - _last)),
          _last == _n - 1,
        );
        return Positioned(
          left: (x + 0.5) * slot,
          bottom: h * 1.08 + 8,
          child: FractionalTranslation(
            translation: const Offset(-0.5, 0),
            child: IgnorePointer(
              child: Opacity(
                opacity: a,
                child: Transform.scale(
                  scale: 0.92 + 0.08 * a,
                  alignment: Alignment.bottomCenter,
                  child: _ChartTip(
                    children: [
                      Text(
                        '$n',
                        style: const TextStyle(
                          color: _kHotPink,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        v == 1 ? 'read' : 'reads',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        date,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ChartTip extends StatelessWidget {
  const _ChartTip({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: _kTipBg,
      border: Border.all(color: _kTipBorder),
      borderRadius: BorderRadius.circular(8),
      boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: children,
    ),
  );
}

/// 30 daily bars, oldest left; today is the solid one. [intro] grows them in,
/// [hover] carries per-bar emphasis (see _DayBarsChartState).
class _DayBarsPainter extends CustomPainter {
  _DayBarsPainter(this.days, {required this.intro, required this.hover})
    : super(repaint: Listenable.merge([intro, hover.listenable]));

  final List<int> days;
  final AnimationController intro;
  final _Glide hover;

  @override
  void paint(Canvas canvas, Size size) {
    if (days.isEmpty) return;
    final n = days.length;
    final maxV = days.fold<int>(1, (a, b) => b > a ? b : a);
    final slot = size.width / n;
    final w = (slot * 0.78).clamp(1.0, 24.0);
    final totalMs =
        _DayBarsChartState._stagger * (n - 1) + _DayBarsChartState._grow;
    final dim = hover.at(n).clamp(0.0, 1.0);
    for (var i = 0; i < n; i++) {
      final v = days[i];
      final p =
          ((intro.value * totalMs - i * _DayBarsChartState._stagger) /
                  _DayBarsChartState._grow)
              .clamp(0.0, 1.0);
      if (p == 0) continue;
      final grow = Curves.easeOutBack.transform(p);
      final e = hover.at(i).clamp(0.0, 1.0);
      final baseH = v == 0 ? 2.0 : 3 + (size.height - 3) * v / maxV;
      final h = baseH * grow * (1 + 0.08 * e);
      final bw = w * (1 + 0.15 * e);
      final isToday = i == n - 1;
      final base = v == 0
          ? _kSurface2
          : isToday
          ? _kPink
          : _kPink.withValues(alpha: 0.45);
      final color = Color.lerp(base, _kHotPink, e)!;
      final fade = 1 - 0.65 * dim * (1 - e);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * slot + (slot - bw) / 2, size.height - h, bw, h),
          const Radius.circular(2),
        ),
        Paint()..color = color.withValues(alpha: color.a * fade),
      );
    }
  }

  @override
  bool shouldRepaint(_DayBarsPainter old) =>
      !listEquals(old.days, days) || old.intro != intro || old.hover != hover;
}

// ─── 24-hour clock ─────────────────────────────────────────────────────────

/// Inner (disc) radius, shared by the painter and the hit test.
double _clockInner(double r) => r * 0.4;

/// The radial clock, its centre read-out and its footer.
class _HourClock extends StatefulWidget {
  const _HourClock({required this.hours, this.highlight});

  final List<int> hours;
  final int? highlight; // unusual hour of the focused read, drawn amber

  @override
  State<_HourClock> createState() => _HourClockState();
}

class _HourClockState extends State<_HourClock> with TickerProviderStateMixin {
  static const _stagger = 22, _bloom = 380;
  static const _size = 200.0;

  late final AnimationController _intro;
  late final _Glide _hover; // [0..24) emphasis, [24] any-hover
  late final AnimationController _count;
  int? _idx;
  int _last = 0;
  int _countFrom = 0;
  bool _reduced = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _hover = _Glide(this, 25, duration: const Duration(milliseconds: 250));
    _count = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _stagger * 23 + _bloom),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!_started) {
      _started = true;
      _reduced ? _intro.value = 1 : _intro.forward();
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _hover.dispose();
    _count.dispose();
    super.dispose();
  }

  int _hrs(int h) => h < widget.hours.length ? widget.hours[h] : 0;

  void _set(int? i) {
    if (i == _idx) return;
    final shown = _hrs(_last);
    setState(() {
      _idx = i;
      if (i != null) {
        _countFrom = _countUp(_countFrom, shown, _count.value);
        _last = i;
      }
    });
    if (i != null) _reduced ? _count.value = 1 : _count.forward(from: 0);
    _hover.to([
      for (var k = 0; k < 24; k++) k == i ? 1.0 : 0.0,
      i == null ? 0.0 : 1.0,
    ], instant: _reduced);
  }

  /// Angle and radius from the centre: anywhere in a wedge's slice between the
  /// inner disc and the outer edge counts.
  void _hit(Offset p) {
    const r = _size / 2;
    final d = p - const Offset(r, r);
    final dist = d.distance;
    if (dist < _clockInner(r) || dist > r) return _set(null);
    var a = math.atan2(d.dy, d.dx) + math.pi / 2;
    a = (a % (2 * math.pi) + 2 * math.pi) % (2 * math.pi);
    _set((a / (2 * math.pi / 24)).floor().clamp(0, 23));
  }

  @override
  Widget build(BuildContext context) {
    final (peak, peakN) = busiestHours(widget.hours, 1);
    final idx = _idx;
    final footer = idx != null
        ? '${fmtHour(idx)} to ${fmtHour((idx + 1) % 24)}'
        : peakN == 0
        ? 'Midnight at the top'
        : 'Peak ${fmtHour(peak)}  ·  midnight at the top';
    return Column(
      children: [
        SizedBox(
          width: _size,
          height: _size,
          child: MouseRegion(
            onEnter: (e) => _hit(e.localPosition),
            onHover: (e) => _hit(e.localPosition),
            onExit: (_) => _set(null),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _RadialClockPainter(
                      widget.hours,
                      highlight: widget.highlight,
                      intro: _intro,
                      hover: _hover,
                    ),
                  ),
                ),
                IgnorePointer(child: _centre()),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          footer,
          style: TextStyle(
            color: idx == null ? Colors.white38 : _kHotPink,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _centre() {
    final idx = _idx;
    return AnimatedBuilder(
      animation: _count,
      builder: (context, _) {
        final v = _hrs(_last);
        final n = _countUp(_countFrom, v, _count.value);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              idx != null ? fmtHour(idx) : '24 h',
              style: TextStyle(
                color: Colors.white,
                fontSize: idx != null ? 15 : 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              idx != null ? '$n ${v == 1 ? 'read' : 'reads'}' : 'by hour',
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The 24-hour "clock": one wedge per hour, midnight at the top, longer and
/// brighter for busier hours. [highlight] draws that hour in amber; the
/// hovered wedge (via [hover]) goes hot pink and pushes out.
class _RadialClockPainter extends CustomPainter {
  _RadialClockPainter(
    this.hours, {
    this.highlight,
    required this.intro,
    required this.hover,
  }) : super(repaint: Listenable.merge([intro, hover.listenable]));

  final List<int> hours;
  final int? highlight;
  final AnimationController intro;
  final _Glide hover;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final inner = _clockInner(r);
    final span = r - inner - 10; // headroom for the hover push
    final maxV = hours.fold<int>(1, (a, b) => b > a ? b : a);
    canvas.drawCircle(c, inner - 4, Paint()..color = _kSurface0);
    const sweep = 2 * math.pi / 24;
    const totalMs = _HourClockState._stagger * 23 + _HourClockState._bloom;
    final dim = hover.at(24).clamp(0.0, 1.0);
    for (var h = 0; h < 24 && h < hours.length; h++) {
      final v = hours[h];
      final outer = inner + (v == 0 ? 2 : 4 + (span - 4) * v / maxV);
      final start = -math.pi / 2 + h * sweep + 0.02;
      final path = Path()
        ..arcTo(
          Rect.fromCircle(center: c, radius: outer),
          start,
          sweep - 0.04,
          true,
        )
        ..arcTo(
          Rect.fromCircle(center: c, radius: inner),
          start + sweep - 0.04,
          -(sweep - 0.04),
          false,
        )
        ..close();
      final p =
          ((intro.value * totalMs - h * _HourClockState._stagger) /
                  _HourClockState._bloom)
              .clamp(0.0, 1.0);
      if (p == 0) continue;
      final bloom = Curves.easeOutCubic.transform(p);
      final e = hover.at(h).clamp(0.0, 1.0);
      final pop = Curves.easeOutBack.transform(e);
      final mid = start + (sweep - 0.04) / 2;
      final isHi = h == highlight;
      final baseA = v == 0 ? 0.12 : 0.35 + 0.65 * v / maxV;
      final base = (isHi ? _kAmber : _kPink).withValues(
        alpha: isHi ? 1 : baseA,
      );
      final color = Color.lerp(base, _kHotPink, e)!;
      final fade = (1 - 0.7 * dim * (1 - e)) * bloom;
      canvas.save();
      canvas.translate(math.cos(mid) * 6 * pop, math.sin(mid) * 6 * pop);
      canvas.translate(c.dx, c.dy);
      canvas.scale((0.4 + 0.6 * bloom) * (1 + 0.06 * pop));
      canvas.translate(-c.dx, -c.dy);
      canvas.drawPath(
        path,
        Paint()..color = color.withValues(alpha: color.a * fade),
      );
      canvas.restore();
    }
    final tp = TextPainter(textDirection: TextDirection.ltr);
    void label(String text, double angle) {
      tp.text = TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white38, fontSize: 9),
      );
      tp.layout();
      final q = c + Offset(math.cos(angle), math.sin(angle)) * (inner - 11);
      tp.paint(canvas, q - Offset(tp.width / 2, tp.height / 2));
    }

    label('0', -math.pi / 2);
    label('6', 0);
    label('12', math.pi / 2);
    label('18', math.pi);
  }

  @override
  bool shouldRepaint(_RadialClockPainter old) =>
      old.highlight != highlight ||
      !listEquals(old.hours, hours) ||
      old.intro != intro ||
      old.hover != hover;
}
