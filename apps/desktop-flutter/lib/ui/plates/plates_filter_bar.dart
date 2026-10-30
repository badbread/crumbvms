// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Plates tab filter bar: ONE 48 px row. What to find (search, match,
// cameras, when) sits on the left, then a taller, brighter rule, then how to
// show it (view, size, grouping toggles); count, refresh and the Watchlist
// button anchor the right edge. Groups are separated by 1 px hairlines and
// carry inline captions (MATCH / WHEN / VIEW / SIZE) instead of boxes. Below
// [_kFilterBarFullWidth] the captions drop, labels shorten and the toggles
// become icon toggles with tooltips, so the row never wraps. A `part` of
// plates_screen.dart.

part of 'plates_screen.dart';

/// At or above this width the bar shows captions and full labels.
const double _kFilterBarFullWidth = 1860;

/// Below this width the search field shrinks to its minimum.
const double _kFilterBarTightWidth = 1250;

const Color _kFbHairline = Color(0xFF343941);
const Color _kFbRule = Color(0xFF3E444E);
const Color _kFbField = Color(0xFF26292F);

/// Short labels for the range dropdown at narrow widths.
const _rangeShort = <int, String>{
  0: 'All',
  1: '1 h',
  6: '6 h',
  24: '24 h',
  72: '3 d',
  168: '7 d',
  720: '30 d',
};

class _PlatesFilterBar extends StatelessWidget {
  const _PlatesFilterBar({
    required this.searchController,
    required this.hasQuery,
    required this.onSearchChanged,
    required this.onSearchSubmitted,
    required this.onSearchCleared,
    required this.match,
    required this.onMatch,
    required this.camLabel,
    required this.camLabelShort,
    required this.onPickCameras,
    required this.hours,
    required this.onHours,
    required this.anchorEnd,
    required this.onPickWhen,
    required this.onBackToNow,
    required this.viewMode,
    required this.onViewMode,
    required this.density,
    required this.onDensity,
    required this.groupByPlate,
    required this.onGroupByPlate,
    required this.collapse,
    required this.onCollapse,
    required this.hideRegularsOn,
    required this.hideRegularsTooltip,
    required this.onHideRegulars,
    required this.deskFilter,
    required this.onClearDeskFilter,
    required this.loading,
    required this.total,
    required this.hiddenCount,
    required this.onRefresh,
    required this.abAvailable,
    required this.onBenchmark,
    required this.showWatchlist,
    required this.watchlistCount,
    required this.onToggleWatchlist,
  });

  final TextEditingController searchController;
  final bool hasQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchSubmitted;
  final VoidCallback onSearchCleared;
  final String match;
  final ValueChanged<String> onMatch;
  final String camLabel;
  final String camLabelShort;
  final VoidCallback onPickCameras;
  final int hours;
  final ValueChanged<int> onHours;
  final DateTime? anchorEnd;
  final VoidCallback onPickWhen;
  final VoidCallback onBackToNow;
  final PlatesViewMode viewMode;
  final ValueChanged<PlatesViewMode> onViewMode;
  final PlateDensity density;
  final ValueChanged<PlateDensity> onDensity;
  final bool groupByPlate;
  final ValueChanged<bool> onGroupByPlate;
  final bool collapse;
  final ValueChanged<bool> onCollapse;
  final bool hideRegularsOn;
  final String hideRegularsTooltip;

  /// Null while "Hide regulars" is unavailable (the Regulars filter is on).
  final VoidCallback? onHideRegulars;
  final DeskFilter deskFilter;
  final VoidCallback onClearDeskFilter;
  final bool loading;
  final int total;
  final int hiddenCount;
  final VoidCallback onRefresh;
  final bool abAvailable;
  final VoidCallback onBenchmark;
  final bool showWatchlist;
  final int watchlistCount;
  final VoidCallback onToggleWatchlist;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        // An anchored range or an active filter pill need extra room, so the
        // bar drops to its compact form a little sooner when they are on.
        final extra =
            (anchorEnd != null ? 90.0 : 0.0) +
            (deskFilter != DeskFilter.all ? 110.0 : 0.0);
        final full = w >= _kFilterBarFullWidth + extra;
        const gap = 8.0;
        final searchW = full
            ? 170.0
            : (w < _kFilterBarTightWidth ? 110.0 : 150.0);
        final isList = viewMode == PlatesViewMode.list;
        final canGroup = isList || viewMode == PlatesViewMode.gallery;
        Widget div({bool strong = false}) =>
            _FbDivider(strong: strong, gap: strong ? gap + 2 : gap);
        Widget cap(String t) => full ? _FbCaption(t) : const SizedBox.shrink();

        final search = SizedBox(
          width: searchW,
          height: 34,
          child: TextField(
            controller: searchController,
            onChanged: onSearchChanged,
            onSubmitted: (_) => onSearchSubmitted(),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search plate…',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
              prefixIcon: const Icon(
                Icons.search,
                size: 16,
                color: Colors.white38,
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
              suffixIcon: hasQuery
                  ? IconButton(
                      icon: const Icon(
                        Icons.clear,
                        size: 14,
                        color: Colors.white38,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onPressed: onSearchCleared,
                    )
                  : null,
              filled: true,
              fillColor: _kFbField,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        );

        final when = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButton<int>(
              value: hours,
              isDense: true,
              dropdownColor: const Color(0xFF23252C),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              underline: const SizedBox.shrink(),
              selectedItemBuilder: full
                  ? null
                  : (context) => [
                      for (final e in _rangeOptions.entries)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(_rangeShort[e.key] ?? e.value),
                        ),
                    ],
              items: [
                for (final e in _rangeOptions.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) {
                if (v != null) onHours(v);
              },
            ),
            SizedBox(width: full ? 6 : 2),
            _ToolButton(
              icon: Icons.event,
              label: anchorEnd == null
                  ? (full ? 'Ending now' : 'now')
                  : (full
                        ? 'Ending ${_fmtDateTime(anchorEnd!)}'
                        : '${anchorEnd!.toLocal().month}/${anchorEnd!.toLocal().day}'),
              tooltip: anchorEnd == null
                  ? 'Pick the date and time the range ends at'
                  : 'Range ends ${_fmtDateTime(anchorEnd!)}. Click to change.',
              onTap: hours == 0 ? null : onPickWhen,
            ),
            if (anchorEnd != null && hours != 0)
              Tooltip(
                message: 'Back to now',
                child: InkWell(
                  onTap: onBackToNow,
                  borderRadius: BorderRadius.circular(6),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.restore, size: 16, color: Colors.white70),
                  ),
                ),
              ),
          ],
        );

        final toggles = <Widget>[
          if (canGroup)
            _ToolToggle(
              label: 'Group by plate',
              icon: Icons.layers_outlined,
              iconOnly: !full,
              on: groupByPlate,
              tooltip: 'Fold every read of a plate into one expandable row',
              onTap: () => onGroupByPlate(!groupByPlate),
            ),
          if (isList)
            _ToolToggle(
              label: 'Merge duplicates',
              icon: Icons.call_merge,
              iconOnly: !full,
              on: collapse,
              tooltip: collapse
                  ? 'Duplicate reads of the same car (both engines +\nrepeat reads) are merged into one row. Click to show every raw read.'
                  : 'Showing every raw read. Click to merge duplicates of the\nsame car into one row.',
              onTap: () => onCollapse(!collapse),
            ),
          _ToolToggle(
            label: 'Hide regulars',
            icon: Icons.visibility_off_outlined,
            iconOnly: !full,
            badge: hideRegularsOn && hiddenCount > 0 ? '$hiddenCount' : null,
            on: hideRegularsOn,
            tooltip: hideRegularsTooltip,
            onTap: onHideRegulars,
          ),
        ];

        final countText = loading
            ? const SizedBox.shrink()
            : Tooltip(
                message:
                    '$total plate${total == 1 ? '' : 's'}'
                    '${hiddenCount > 0 ? ', $hiddenCount reads hidden as regulars' : ''}',
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$total',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (full)
                        TextSpan(
                          text:
                              ' plate${total == 1 ? '' : 's'}',
                        ),
                    ],
                  ),
                  maxLines: 1,
                  softWrap: false,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              );

        final watchlist = Tooltip(
          message: showWatchlist
              ? 'Hide the watchlist panel'
              : 'Show the watchlist panel',
          child: InkWell(
            onTap: onToggleWatchlist,
            borderRadius: BorderRadius.circular(7),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: showWatchlist
                    ? _kLprAccent.withValues(alpha: 0.16)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    showWatchlist
                        ? Icons.playlist_add_check
                        : Icons.playlist_add,
                    size: 16,
                    color: showWatchlist ? _kLprAccent : Colors.white70,
                  ),
                  if (full || watchlistCount > 0) ...[
                    const SizedBox(width: 6),
                    Text(
                      full
                          ? (watchlistCount == 0
                                ? 'Watchlist'
                                : 'Watchlist ($watchlistCount)')
                          : '$watchlistCount',
                      style: TextStyle(
                        color: showWatchlist ? _kLprAccent : Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );

        return Container(
          height: 48,
          padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
          decoration: const BoxDecoration(
            color: Color(0xFF1E2026),
            border: Border(bottom: BorderSide(color: Color(0xFF262A31))),
          ),
          child: Row(
            children: [
              search,
              div(),
              cap('MATCH'),
              if (full) const SizedBox(width: 8),
              _Seg<String>(
                value: match,
                options: const [
                  ('exact', 'Exact'),
                  ('contains', 'Contains'),
                  ('fuzzy', 'Fuzzy'),
                ],
                onChanged: onMatch,
              ),
              div(),
              _ToolButton(
                icon: Icons.videocam_outlined,
                label: full ? camLabel : camLabelShort,
                tooltip: 'Choose which cameras to search ($camLabel)',
                onTap: onPickCameras,
              ),
              div(),
              cap('WHEN'),
              if (full) const SizedBox(width: 8),
              when,
              div(strong: true),
              cap('VIEW'),
              if (full) const SizedBox(width: 8),
              _ViewModeToggle(value: viewMode, onChanged: onViewMode),
              if (isList) ...[
                div(),
                cap('SIZE'),
                if (full) const SizedBox(width: 8),
                _DensityToggle(value: density, onChanged: onDensity),
              ],
              div(),
              for (var i = 0; i < toggles.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                toggles[i],
              ],
              if (deskFilter != DeskFilter.all) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: _FbFilterChip(
                    label: deskFilterLabel(deskFilter),
                    iconOnly: w < _kFilterBarTightWidth,
                    onClear: onClearDeskFilter,
                  ),
                ),
              ],
              const Spacer(),
              countText,
              const SizedBox(width: 2),
              Tooltip(
                message: 'Refresh',
                child: InkWell(
                  onTap: onRefresh,
                  borderRadius: BorderRadius.circular(6),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.refresh, size: 17, color: Colors.white70),
                  ),
                ),
              ),
              if (abAvailable)
                Tooltip(
                  message: 'Benchmark',
                  child: InkWell(
                    onTap: onBenchmark,
                    borderRadius: BorderRadius.circular(6),
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(Icons.speed, size: 17, color: Colors.white70),
                    ),
                  ),
                ),
              div(),
              watchlist,
            ],
          ),
        );
      },
    );
  }
}

/// A 1 px vertical rule between filter groups. [strong] is the taller,
/// brighter rule between the find zone and the show zone.
class _FbDivider extends StatelessWidget {
  const _FbDivider({this.strong = false, required this.gap});

  final bool strong;
  final double gap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: gap),
    child: SizedBox(
      width: 1,
      height: strong ? 34 : 26,
      child: ColoredBox(color: strong ? _kFbRule : _kFbHairline),
    ),
  );
}

/// The inline group caption (MATCH / WHEN / VIEW / SIZE).
class _FbCaption extends StatelessWidget {
  const _FbCaption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    softWrap: false,
    style: const TextStyle(
      color: Colors.white38,
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.6,
    ),
  );
}

/// The "filter is on" pill with a clear button.
class _FbFilterChip extends StatelessWidget {
  const _FbFilterChip({
    required this.label,
    required this.onClear,
    this.iconOnly = false,
  });

  final String label;
  final VoidCallback onClear;

  /// Narrow bar: just a funnel and an x, the filter name in the tooltip.
  final bool iconOnly;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: iconOnly ? 'Filter: $label. Click to clear.' : 'Clear the filter',
    child: InkWell(
      onTap: onClear,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 3, 5, 3),
        decoration: BoxDecoration(
          color: _kLprChipBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (iconOnly)
              const Padding(
                padding: EdgeInsets.only(right: 2),
                child: Icon(Icons.filter_alt_outlined, size: 13, color: _kLprHot),
              )
            else
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: _kLprHot,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const SizedBox(width: 3),
            const Icon(Icons.close, size: 13, color: _kLprHot),
          ],
        ),
      ),
    ),
  );
}

/// The filter bar with no network or state, for layout tests.
@visibleForTesting
Widget debugPlatesFilterBar({
  PlatesViewMode viewMode = PlatesViewMode.list,
  DeskFilter deskFilter = DeskFilter.all,
  bool anchored = false,
  int hiddenCount = 12,
  bool abAvailable = true,
}) {
  return _PlatesFilterBar(
    searchController: TextEditingController(text: '8DIS'),
    hasQuery: true,
    onSearchChanged: (_) {},
    onSearchSubmitted: () {},
    onSearchCleared: () {},
    match: 'contains',
    onMatch: (_) {},
    camLabel: '3 of 12 cameras',
    camLabelShort: '3/12',
    onPickCameras: () {},
    hours: 24,
    onHours: (_) {},
    anchorEnd: anchored ? DateTime(2026, 10, 29, 15, 30) : null,
    onPickWhen: () {},
    onBackToNow: () {},
    viewMode: viewMode,
    onViewMode: (_) {},
    density: PlateDensity.standard,
    onDensity: (_) {},
    groupByPlate: true,
    onGroupByPlate: (_) {},
    collapse: true,
    onCollapse: (_) {},
    hideRegularsOn: true,
    hideRegularsTooltip: 'Hide regulars',
    onHideRegulars: () {},
    deskFilter: deskFilter,
    onClearDeskFilter: () {},
    loading: false,
    total: 18,
    hiddenCount: hiddenCount,
    onRefresh: () {},
    abAvailable: abAvailable,
    onBenchmark: () {},
    showWatchlist: true,
    watchlistCount: 2,
    onToggleWatchlist: () {},
  );
}
