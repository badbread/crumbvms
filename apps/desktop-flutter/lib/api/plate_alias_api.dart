// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Plate corrections (issue #673): "this misread plate is really that plate".
// An admin records an alias (`GIT2GAB` -> `GIF2GAB`) and the server counts
// every read of the alias as the canonical plate everywhere: `GET /plates`
// returns the canonical plate (with the raw read in `corrected_from`), and the
// plate desk stats and overview fold the misreads in. Raw reads are never
// rewritten, so deleting the alias undoes it.
//
//   GET    /lpr/plate-aliases[?canonical=]        view_plates, counts scoped
//   GET    /lpr/plate-alias-suggestions?plate=    view_plates, camera-scoped
//   POST   /lpr/plate-aliases {alias, canonical}  admin-only
//   DELETE /lpr/plate-aliases/{alias}             admin-only
//
// Older servers do not have these routes: the reads return null on 404 / 405
// so the UI can hide the feature; anything else throws [CrumbApiException].

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'crumb_api.dart';
import 'http_client.dart';
import 'models.dart';

/// One correction: reads of [aliasPlate] count as [canonicalPlate].
class PlateAlias {
  const PlateAlias({
    required this.aliasPlate,
    required this.canonicalPlate,
    required this.createdBy,
    required this.createdAt,
    required this.reads,
  });

  final String aliasPlate;
  final String canonicalPlate;

  /// Username of the admin who made the correction, when still known.
  final String? createdBy;
  final DateTime? createdAt;

  /// Reads stored under the misread string that this account can see.
  final int reads;

  factory PlateAlias.fromJson(Map<String, dynamic> j) => PlateAlias(
    aliasPlate: (j['alias_plate'] as String?) ?? '',
    canonicalPlate: (j['canonical_plate'] as String?) ?? '',
    createdBy: j['created_by'] as String?,
    createdAt: j['created_at'] is String
        ? DateTime.tryParse(j['created_at'] as String)
        : null,
    reads: (j['reads'] as num?)?.toInt() ?? 0,
  );
}

/// One likely real plate for a misread.
class PlateSuggestion {
  const PlateSuggestion({
    required this.plate,
    required this.reads,
    required this.distance,
    required this.displayName,
  });

  final String plate;
  final int reads;

  /// Character edits between the misread and this plate (OCR look-alikes
  /// such as O and 0 count as none).
  final int distance;
  final String? displayName;

  factory PlateSuggestion.fromJson(Map<String, dynamic> j) => PlateSuggestion(
    plate: (j['plate'] as String?) ?? '',
    reads: (j['reads'] as num?)?.toInt() ?? 0,
    distance: (j['distance'] as num?)?.toInt() ?? 0,
    displayName: j['display_name'] as String?,
  );
}

/// `GET /lpr/plate-alias-suggestions` response.
class PlateSuggestions {
  const PlateSuggestions({
    required this.plate,
    required this.canonicalPlate,
    required this.reads,
    required this.aliases,
    required this.suggestions,
  });

  /// The normalized plate being corrected.
  final String plate;

  /// What [plate] counts as today (itself unless already corrected).
  final String canonicalPlate;

  /// Reads a correction would move: [plate]'s own plus its misreads'.
  final int reads;

  /// Misreads that point at [plate] and would move with it.
  final List<String> aliases;
  final List<PlateSuggestion> suggestions;

  factory PlateSuggestions.fromJson(Map<String, dynamic> j) => PlateSuggestions(
    plate: (j['plate'] as String?) ?? '',
    canonicalPlate: (j['canonical_plate'] as String?) ?? '',
    reads: (j['reads'] as num?)?.toInt() ?? 0,
    aliases: [
      for (final a in (j['aliases'] as List<dynamic>? ?? const []))
        if (a is String) a,
    ],
    suggestions: [
      for (final s in (j['suggestions'] as List<dynamic>? ?? const []))
        if (s is Map<String, dynamic>) PlateSuggestion.fromJson(s),
    ],
  );
}

final http.Client _client = TimeoutClient();

extension PlateAliasApi on CrumbApi {
  /// `GET /lpr/plate-aliases[?canonical=]`. Null when the server predates
  /// plate corrections (404/405).
  Future<List<PlateAlias>?> listPlateAliases(
    Session s, {
    String? canonical,
  }) async {
    final uri = Uri.parse('${s.base}/lpr/plate-aliases').replace(
      queryParameters: canonical == null || canonical.isEmpty
          ? null
          : {'canonical': canonical},
    );
    final resp = await _client.get(
      uri,
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode == 404 || resp.statusCode == 405) return null;
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load plate corrections (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return [
      for (final e in jsonDecode(resp.body) as List<dynamic>)
        if (e is Map<String, dynamic>) PlateAlias.fromJson(e),
    ];
  }

  /// `GET /lpr/plate-alias-suggestions?plate=`. Null when the server
  /// predates plate corrections (404/405).
  Future<PlateSuggestions?> suggestPlateCorrections(
    Session s,
    String plate,
  ) async {
    final uri = Uri.parse(
      '${s.base}/lpr/plate-alias-suggestions',
    ).replace(queryParameters: {'plate': plate});
    final resp = await _client.get(
      uri,
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode == 404 || resp.statusCode == 405) return null;
    if (resp.statusCode != 200) {
      throw CrumbApiException(
        'Failed to load likely plates (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
    return PlateSuggestions.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  /// `POST /lpr/plate-aliases {alias, canonical}`: reads of [alias] count as
  /// [canonical] from now on. Returns the stored correction (its canonical
  /// plate can differ from [canonical] when that was itself a misread).
  /// **Admin-only**: a 403 surfaces as a [CrumbApiException].
  Future<PlateAlias> createPlateAlias(
    Session s, {
    required String alias,
    required String canonical,
  }) async {
    final resp = await _client.post(
      Uri.parse('${s.base}/lpr/plate-aliases'),
      headers: {
        'authorization': 'Bearer ${s.token}',
        'content-type': 'application/json',
      },
      body: jsonEncode({'alias': alias, 'canonical': canonical}),
    );
    if (resp.statusCode != 201 && resp.statusCode != 200) {
      throw CrumbApiException(
        switch (resp.statusCode) {
          403 => 'Only admins can correct plates.',
          400 => 'Enter a different plate to correct it to.',
          404 || 405 => 'This server cannot correct plates yet. Update it.',
          _ => 'Failed to save the correction (HTTP ${resp.statusCode}).',
        },
        statusCode: resp.statusCode,
      );
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return PlateAlias.fromJson(
      (body['alias'] as Map<String, dynamic>?) ?? const {},
    );
  }

  /// `DELETE /lpr/plate-aliases/{alias}`: undo a correction. A 404 (no
  /// correction) counts as success. **Admin-only.**
  Future<void> deletePlateAlias(Session s, String alias) async {
    final resp = await _client.delete(
      Uri.parse('${s.base}/lpr/plate-aliases/${Uri.encodeComponent(alias)}'),
      headers: {'authorization': 'Bearer ${s.token}'},
    );
    if (resp.statusCode != 204 && resp.statusCode != 404) {
      throw CrumbApiException(
        resp.statusCode == 403
            ? 'Only admins can correct plates.'
            : 'Failed to undo the correction (HTTP ${resp.statusCode}).',
        statusCode: resp.statusCode,
      );
    }
  }
}
