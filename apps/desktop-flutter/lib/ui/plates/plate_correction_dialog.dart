// SPDX-License-Identifier: AGPL-3.0-or-later
//
// "Correct plate..." (issue #673): tell Crumb that a misread plate is really
// another plate, so the two count as one vehicle everywhere.
//
//   * [showPlateCorrectionDialog]  type (or pick) the real plate, see what the
//     correction will move, save. Offers an Undo right after saving.
//   * [PlateMisreadsSection]       the plate profile's list of known misreads
//     of a plate, each with an Undo (admins).
//   * [plateCorrections]           bumped after every change made from this
//     client, so an open Plates page reloads its list and history.
//
// The server does the work: a correction is an alias row
// (`POST /lpr/plate-aliases`) and every read of the alias is served as the
// canonical plate, so this client never re-maps plates itself. Raw reads are
// never rewritten, which is why Undo is just deleting the alias.
//
// Corrections are admin-only server-side, like naming a plate. Callers gate
// the affordance with [canOfferPlateCorrection].

import 'package:flutter/material.dart';

import 'package:crumb_desktop/api/crumb_api.dart';
import 'package:crumb_desktop/api/models.dart';
import 'package:crumb_desktop/api/plate_alias_api.dart';
import 'package:crumb_desktop/api/plates_api.dart';
import 'package:crumb_desktop/ui/hotkeys/hotkey_gate.dart';

/// What the last correction made from this client did. [canonical] is null
/// when it was an Undo.
class PlateCorrectionEvent {
  const PlateCorrectionEvent(this.alias, this.canonical);
  final String alias;
  final String? canonical;
}

/// Notifies after every correction or undo made from this client.
class PlateCorrectionBus extends ChangeNotifier {
  PlateCorrectionEvent? _last;

  /// The most recent change, or null before the first one.
  PlateCorrectionEvent? get last => _last;

  void report(PlateCorrectionEvent e) {
    _last = e;
    notifyListeners();
  }
}

/// The app-wide bus the Plates page listens to.
final PlateCorrectionBus plateCorrections = PlateCorrectionBus();

/// Whether to show "Correct plate". Writes are admin-only server-side, so a
/// non-admin never sees a control that would 403 ([isAdmin] is the same
/// `is_admin` flag that gates naming plates). A blank plate has nothing to
/// correct.
bool canOfferPlateCorrection({required bool isAdmin, required String plate}) =>
    isAdmin && plate.trim().isNotEmpty;

/// Uppercase ASCII letters and digits only, the way the server stores plates.
String normalizePlateInput(String s) =>
    s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

String _reads(int n) => n == 1 ? '1 read' : '$n reads';

/// The sentence telling the operator what saving will do, e.g.
/// "GIT2GAB's 12 reads will count as GIF2GAB, and so will future reads of it."
/// Null when [target] is not a usable correction of [from].
String? plateCorrectionEffect({
  required String from,
  required String target,
  required int reads,
  List<String> movingAliases = const [],
}) {
  final to = normalizePlateInput(target);
  if (from.isEmpty || to.isEmpty || to == from) return null;
  final b = StringBuffer(
    reads > 0
        ? "$from's ${_reads(reads)} will count as $to, and so will future "
              'reads of it.'
        : 'Future reads of $from will count as $to.',
  );
  if (movingAliases.isNotEmpty) {
    b.write(
      ' ${movingAliases.length == 1 ? 'Its known misread' : 'Its known misreads'} '
      '${movingAliases.join(', ')} will move to $to too.',
    );
  }
  return b.toString();
}

/// [read] shown as [plate]: the same read after its plate was corrected, so
/// a view open on the misread can move to the real plate before the reload
/// lands. The name is dropped because it belonged to the old plate string.
PlateRead plateReadAs(PlateRead read, String plate) => PlateRead(
  id: read.id,
  cameraId: read.cameraId,
  ts: read.ts,
  plate: plate,
  plateRaw: read.plateRaw,
  confidence: read.confidence,
  region: read.region,
  sourceId: read.sourceId,
  eventId: read.eventId,
  snapshotUrl: read.snapshotUrl,
  displayName: null,
  bbox: read.bbox,
);

/// How far a suggestion is from the misread, in words.
String plateSuggestionDistanceLabel(int distance) => switch (distance) {
  0 => 'look-alike characters',
  1 => '1 character off',
  _ => '$distance characters off',
};

/// Ask for the real plate behind [plate] and save the correction. Returns the
/// stored correction, or null when cancelled. After saving it shows a
/// SnackBar with Undo and reports the change on [plateCorrections].
Future<PlateAlias?> showPlateCorrectionDialog(
  BuildContext context, {
  required CrumbApi api,
  required Session session,
  required String plate,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final saved = await showDialog<PlateAlias>(
    context: context,
    builder: (_) =>
        _PlateCorrectionDialog(api: api, session: session, plate: plate),
  );
  if (saved == null) return null;
  plateCorrections.report(
    PlateCorrectionEvent(saved.aliasPlate, saved.canonicalPlate),
  );
  messenger?.showSnackBar(
    SnackBar(
      content: Text(
        '${saved.aliasPlate} now counts as ${saved.canonicalPlate}.',
      ),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => undoPlateCorrection(
          messenger,
          api: api,
          session: session,
          alias: saved.aliasPlate,
        ),
      ),
    ),
  );
  return saved;
}

/// Delete the correction for [alias] and report it. Errors go to [messenger].
Future<void> undoPlateCorrection(
  ScaffoldMessengerState? messenger, {
  required CrumbApi api,
  required Session session,
  required String alias,
}) async {
  try {
    await api.deletePlateAlias(session, alias);
    plateCorrections.report(PlateCorrectionEvent(alias, null));
    messenger?.showSnackBar(
      SnackBar(
        content: Text('$alias counts as itself again.'),
        duration: const Duration(seconds: 3),
      ),
    );
  } on CrumbApiException catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Undo failed: $e')));
  }
}

class _PlateCorrectionDialog extends StatefulWidget {
  const _PlateCorrectionDialog({
    required this.api,
    required this.session,
    required this.plate,
  });

  final CrumbApi api;
  final Session session;
  final String plate;

  @override
  State<_PlateCorrectionDialog> createState() => _PlateCorrectionDialogState();
}

class _PlateCorrectionDialogState extends State<_PlateCorrectionDialog> {
  final _controller = TextEditingController();
  PlateSuggestions? _info;
  bool _loading = true;
  bool _unsupported = false;
  bool _saving = false;
  String? _error;

  String get _plate => normalizePlateInput(widget.plate);

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await widget.api.suggestPlateCorrections(
        widget.session,
        _plate,
      );
      if (!mounted) return;
      setState(() {
        _info = info;
        _unsupported = info == null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String? get _effect => plateCorrectionEffect(
    from: _plate,
    target: _controller.text,
    reads: _info?.reads ?? 0,
    movingAliases: _info?.aliases ?? const [],
  );

  Future<void> _save() async {
    if (_effect == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.api.createPlateAlias(
        widget.session,
        alias: _plate,
        canonical: normalizePlateInput(_controller.text),
      );
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } on CrumbApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Save failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const dim = TextStyle(color: Colors.white54, fontSize: 12);
    final info = _info;
    final already = info != null && info.canonicalPlate != info.plate;
    final effect = _effect;
    return AlertDialog(
      backgroundColor: const Color(0xFF23262E),
      title: Text(
        'Correct plate $_plate',
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'If the camera misread this plate, enter the real one. Its '
              'reads then count as that plate everywhere, on every client. '
              'The original reads are kept, and you can undo this from the '
              "real plate's profile.",
              style: dim,
            ),
            if (already) ...[
              const SizedBox(height: 8),
              Text(
                'Already counted as ${info.canonicalPlate}.',
                style: const TextStyle(color: Color(0xFFE8A33D), fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            HotkeySuppressor.whileFocused(
              child: TextField(
                controller: _controller,
                autofocus: true,
                enabled: !_unsupported,
                textCapitalization: TextCapitalization.characters,
                onSubmitted: (_) => _save(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  letterSpacing: 1.2,
                ),
                decoration: const InputDecoration(
                  labelText: 'Real plate',
                  hintText: 'e.g. GIF2GAB',
                  labelStyle: TextStyle(color: Colors.white54, fontSize: 13),
                  hintStyle: TextStyle(color: Colors.white24, fontSize: 13),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Text('Looking for likely plates...', style: dim)
            else if (_unsupported)
              const Text(
                'This server cannot correct plates yet. Update the Crumb '
                'server to use this.',
                style: TextStyle(color: Color(0xFFE8A33D), fontSize: 12),
              )
            else if (info != null && info.suggestions.isNotEmpty) ...[
              const Text('Likely matches', style: dim),
              const SizedBox(height: 4),
              for (final s in info.suggestions) _suggestion(s),
            ] else if (info != null)
              const Text('No similar plates seen yet.', style: dim),
            if (effect != null) ...[
              const SizedBox(height: 12),
              Text(
                effect,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFE05A5A), fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text(
            'Cancel',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ),
        TextButton(
          onPressed: effect == null || _saving || _unsupported ? null : _save,
          child: Text(
            _saving ? 'Saving...' : 'Correct',
            style: TextStyle(
              color: effect == null ? Colors.white24 : Colors.white,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }

  Widget _suggestion(PlateSuggestion s) {
    final picked = normalizePlateInput(_controller.text) == s.plate;
    final name = s.displayName?.trim() ?? '';
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        _controller.text = s.plate;
        _controller.selection = TextSelection.collapsed(offset: s.plate.length);
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: picked ? Colors.white.withValues(alpha: 0.10) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Text(
              s.plate,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            if (name.isNotEmpty) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
            const Spacer(),
            Text(
              '${_reads(s.reads)}, ${plateSuggestionDistanceLabel(s.distance)}',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// The plate profile's "Known misreads" card: the plates that were corrected
/// to [plate], how many reads each moved, and an Undo for admins
/// ([canEdit]). Renders nothing when there are none or the server predates
/// corrections. Reloads after any correction made from this client.
class PlateMisreadsSection extends StatefulWidget {
  const PlateMisreadsSection({
    super.key,
    required this.api,
    required this.session,
    required this.plate,
    required this.canEdit,
  });

  final CrumbApi api;
  final Session session;
  final String plate;
  final bool canEdit;

  @override
  State<PlateMisreadsSection> createState() => _PlateMisreadsSectionState();
}

class _PlateMisreadsSectionState extends State<PlateMisreadsSection> {
  List<PlateAlias> _aliases = const [];

  @override
  void initState() {
    super.initState();
    plateCorrections.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(PlateMisreadsSection old) {
    super.didUpdateWidget(old);
    if (old.plate != widget.plate) _load();
  }

  @override
  void dispose() {
    plateCorrections.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final plate = widget.plate;
    if (plate.isEmpty) return;
    try {
      final list = await widget.api.listPlateAliases(
        widget.session,
        canonical: plate,
      );
      if (!mounted || plate != widget.plate) return;
      setState(() => _aliases = list ?? const []);
    } catch (_) {
      // Purely informational: keep whatever was shown.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_aliases.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'KNOWN MISREADS',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 11,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 4),
          for (final a in _aliases)
            Row(
              children: [
                Text(
                  a.aliasPlate,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _reads(a.reads),
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
                if (widget.canEdit)
                  TextButton(
                    onPressed: () => undoPlateCorrection(
                      ScaffoldMessenger.maybeOf(context),
                      api: widget.api,
                      session: widget.session,
                      alias: a.aliasPlate,
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white54,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Undo', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
