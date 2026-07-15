// The camera's linked-entity picker for the HA overlay editor bar (issue
// #170 §4.5, POC): a search field + the LINKED entities (already fetched via
// `HaApi.cameraHaLinks`) grouped by domain — Sensors (`binary_sensor.*`,
// subtitled with device_class), Lights (`light.*`), Switches (`switch.*`),
// Scenes (`scene.*`). Each row shows the same icon mapping as the on-video
// badge (`ha_icons.dart`), the display label (`link.label ?? entity_id`),
// and a checkmark for links currently placed in the edit session. Tapping
// ANY row calls [onPick] — the host decides what that means (place at
// frame-center if new, or just re-select if already placed; see
// `ha_overlay_controller.dart`'s `pickFromPalette`).
//
// This is intentionally the FLAT grouped+search picker (not the HA
// Area->Device->Entity tree — that needs the HA registry API and is a later
// phase, see the desktop P0 plan §4.5/§7 Q1).

import 'package:flutter/material.dart';

import '../../api/ha_models.dart';
import 'ha_icons.dart';

class HaEntityPalette extends StatefulWidget {
  const HaEntityPalette({
    super.key,
    required this.links,
    required this.placedIds,
    required this.onPick,
  });

  /// The camera's full linked-entity set (`GET /cameras/:id/ha/links`).
  final List<HaLink> links;

  /// Ids of links currently placed in THIS edit session — drives the row
  /// checkmark. Pass the live set from the host (e.g.
  /// `HaOverlayController.placedIdsInSession`) so it stays in sync as the
  /// operator drags/deletes badges.
  final Set<String> placedIds;

  final void Function(HaLink link) onPick;

  @override
  State<HaEntityPalette> createState() => _HaEntityPaletteState();
}

class _HaEntityPaletteState extends State<HaEntityPalette> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  static const _groupOrder = <String, String>{
    'binary_sensor': 'Sensors',
    'light': 'Lights',
    'switch': 'Switches',
    'scene': 'Scenes',
  };

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final groups = <String, List<HaLink>>{};
    for (final link in widget.links) {
      if (q.isNotEmpty &&
          !link.displayLabel.toLowerCase().contains(q) &&
          !link.entityId.toLowerCase().contains(q)) {
        continue;
      }
      final group = _groupOrder.containsKey(link.domain) ? link.domain : 'other';
      (groups[group] ??= []).add(link);
    }

    return SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 32,
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, color: Colors.white38, size: 16),
                hintText: 'Search linked entities…',
                hintStyle: TextStyle(color: Colors.white38),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in _orderedGroups(groups))
                    _group(entry.key, entry.value),
                  if (groups.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No linked entities match.',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<MapEntry<String, List<HaLink>>> _orderedGroups(
    Map<String, List<HaLink>> groups,
  ) {
    final ordered = <MapEntry<String, List<HaLink>>>[];
    for (final domain in _groupOrder.keys) {
      final list = groups[domain];
      if (list != null && list.isNotEmpty) ordered.add(MapEntry(domain, list));
    }
    final other = groups['other'];
    if (other != null && other.isNotEmpty) ordered.add(MapEntry('other', other));
    return ordered;
  }

  Widget _group(String domain, List<HaLink> links) {
    final title = _groupOrder[domain] ?? 'Other';
    links.sort(
      (a, b) => a.displayLabel.toLowerCase().compareTo(b.displayLabel.toLowerCase()),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          for (final link in links) _row(link),
        ],
      ),
    );
  }

  Widget _row(HaLink link) {
    final placed = widget.placedIds.contains(link.id);
    final visual = haVisualFor(
      domain: link.domain,
      deviceClass: link.deviceClass,
      state: null,
      stale: false,
    );
    return InkWell(
      onTap: () => widget.onPick(link),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          children: [
            Icon(visual.icon, size: 15, color: visual.color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    link.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                  ),
                  if (link.domain == 'binary_sensor' && link.deviceClass != null)
                    Text(
                      link.deviceClass!,
                      style: const TextStyle(color: Colors.white38, fontSize: 10.5),
                    ),
                ],
              ),
            ),
            if (placed) const Icon(Icons.check, size: 14, color: Colors.greenAccent),
          ],
        ),
      ),
    );
  }
}
