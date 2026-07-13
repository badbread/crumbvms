// Client-side-only saved-view preferences: drag-reorder order and the
// "launch view" star. Neither is server state — the server has no ordering
// column and no per-user default-view field, so (matching the Tauri client's
// LS_VIEW_ORDER / LS_DEFAULT_VIEW localStorage keys exactly) these live in
// local device storage only and do not sync across machines.

import 'package:shared_preferences/shared_preferences.dart';

class ViewPrefs {
  static const _kOrder = 'crumb_view_order';
  static const _kDefault = 'crumb_default_view';

  /// Sentinel id for the built-in "All Cameras" auto-grid view (not a real
  /// server-side saved view), matching the Tauri client's '__all__'.
  static const allCamerasId = '__all__';

  Future<List<String>> getOrder() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kOrder) ?? const [];
  }

  Future<void> setOrder(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kOrder, ids);
  }

  /// Move `id` one position earlier (`dir < 0`) or later (`dir > 0`) within
  /// `allIds` (all currently-known view ids, used to seed unordered ids at
  /// the tail before reordering). Persists and returns the new order.
  Future<List<String>> move(String id, int dir, List<String> allIds) async {
    final order = _reconciled(await getOrder(), allIds);
    final i = order.indexOf(id);
    if (i < 0) return order;
    final j = i + (dir < 0 ? -1 : 1);
    if (j < 0 || j >= order.length) return order;
    final next = List<String>.from(order);
    final tmp = next[i];
    next[i] = next[j];
    next[j] = tmp;
    await setOrder(next);
    return next;
  }

  /// Reorder to an explicit sequence (drag-drop drop), keeping any ids not
  /// present in `allIds` out of the persisted list.
  Future<void> setExplicitOrder(List<String> ids) => setOrder(ids);

  /// `allIds` in persisted order, with any ids missing from the stored order
  /// appended at the end in their natural order (newly created / never
  /// explicitly reordered views).
  List<String> _reconciled(List<String> stored, List<String> allIds) {
    final known = allIds.toSet();
    final ordered = stored.where(known.contains).toList();
    final seen = ordered.toSet();
    for (final id in allIds) {
      if (!seen.contains(id)) ordered.add(id);
    }
    return ordered;
  }

  /// `allIds` (real view ids, plus [allCamerasId] if that quick-view is
  /// shown) reconciled against the persisted order.
  Future<List<String>> reconciledOrder(List<String> allIds) async =>
      _reconciled(await getOrder(), allIds);

  Future<String?> getDefaultViewId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kDefault);
  }

  /// Toggle `id` as the launch view: clears it if already the default, else
  /// sets it (matching setDefaultView's toggle behavior in app.js).
  Future<bool> toggleDefault(String id) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kDefault) == id) {
      await prefs.remove(_kDefault);
      return false;
    }
    await prefs.setString(_kDefault, id);
    return true;
  }

  Future<void> clearDefaultIfStale(String staleId) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kDefault) == staleId) {
      await prefs.remove(_kDefault);
    }
  }
}
