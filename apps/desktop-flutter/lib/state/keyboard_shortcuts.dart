// Remappable ACTION shortcut bindings (snapshot / toggle audio / perf HUD) —
// the single-key "do something" hotkeys, as opposed to the per-camera number
// keys ([HotkeyConfigStore], lib/state/hotkey_config.dart) and the inherent
// transport keys (Space/arrows/,/. in playback_hotkeys_listener.dart), which
// stay fixed.
//
// Mirrors HotkeyConfigStore's shape: one instance constructed via [load] near
// the app root and passed down to every key listener AND to the Keyboard
// Shortcuts settings screen, `shared_preferences`-persisted (one int keyId per
// action), degrading gracefully to in-memory-only when the plugin is
// unavailable. It is a [ChangeNotifier] so the settings screen rebuilds its
// binding labels live; the key listeners read [keyFor] at key-press time, so
// they don't need to listen.
//
// Every consumer treats a missing store (null) as "use the defaults" — the
// hardcoded S/M/F8 the listeners shipped with — so nothing crashes if the
// store failed to load.

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The remappable action shortcuts. Camera "go to" number keys are NOT here —
/// they're a separate two-bank system owned by [HotkeyConfigStore] and remapped
/// in the Camera Hotkeys settings section.
enum ShortcutAction {
  /// Save a PNG of the active (maximized else selected) pane. Default `S`.
  snapshot('Snapshot active pane', 'Save a PNG of the active video pane.'),

  /// Mute/unmute the active pane's audio. Default `M`.
  toggleAudio('Toggle audio', 'Mute or unmute the active pane\'s audio.'),

  /// Show/hide the live performance HUD footer. Default `F8`.
  hudToggle('Performance HUD', 'Show or hide the performance footer.');

  const ShortcutAction(this.label, this.description);

  /// Short human name, shown in the settings list and conflict messages.
  final String label;

  /// One-line description under the label in the settings list.
  final String description;

  /// The out-of-the-box binding — also the hardcoded fallback every listener
  /// uses when no [KeyboardShortcutsStore] was wired up.
  LogicalKeyboardKey get defaultKey => switch (this) {
    ShortcutAction.snapshot => LogicalKeyboardKey.keyS,
    ShortcutAction.toggleAudio => LogicalKeyboardKey.keyM,
    ShortcutAction.hudToggle => LogicalKeyboardKey.f8,
  };
}

/// Human label for a bound key ("S", "F8", …). [LogicalKeyboardKey.keyLabel]
/// covers letters/digits/F-keys; fall back to the debug name for the rare key
/// without a printable label.
String shortcutKeyLabel(LogicalKeyboardKey key) {
  final l = key.keyLabel;
  if (l.isNotEmpty && l.trim().isNotEmpty) return l;
  return key.debugName ?? 'Key ${key.keyId}';
}

String _prefsKeyFor(ShortcutAction action) => 'crumb.shortcut.${action.name}';

/// Loads/holds/persists the action-shortcut bindings. See the file header for
/// the wiring contract.
class KeyboardShortcutsStore extends ChangeNotifier {
  KeyboardShortcutsStore._(this._prefs, this._bindings);

  final SharedPreferences? _prefs;
  final Map<ShortcutAction, LogicalKeyboardKey> _bindings;

  static Future<KeyboardShortcutsStore> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null; // plugin unavailable — in-memory only, per-session
    }
    final bindings = <ShortcutAction, LogicalKeyboardKey>{};
    for (final action in ShortcutAction.values) {
      LogicalKeyboardKey? key;
      final id = prefs?.getInt(_prefsKeyFor(action));
      if (id != null) key = LogicalKeyboardKey.findKeyByKeyId(id);
      bindings[action] = key ?? action.defaultKey;
    }
    return KeyboardShortcutsStore._(prefs, bindings);
  }

  /// The CURRENT key bound to [action]. Listeners call this at key-press time
  /// so a remap takes effect immediately, no rebuild needed.
  LogicalKeyboardKey keyFor(ShortcutAction action) =>
      _bindings[action] ?? action.defaultKey;

  /// The action currently holding [key], or null. [except] skips one action —
  /// pass the action being remapped so re-recording its own key isn't flagged
  /// as a conflict with itself.
  ShortcutAction? actionForKey(LogicalKeyboardKey key, {ShortcutAction? except}) {
    for (final action in ShortcutAction.values) {
      if (action == except) continue;
      if (keyFor(action) == key) return action;
    }
    return null;
  }

  /// True when every action still holds its default key (drives the
  /// enabled-state of "Reset to defaults").
  bool get allDefaults =>
      ShortcutAction.values.every((a) => keyFor(a) == a.defaultKey);

  /// Bind [key] to [action]. The CALLER validates first (reserved keys,
  /// conflicts — see KeyboardShortcutsScreen); this just stores + persists.
  void setKey(ShortcutAction action, LogicalKeyboardKey key) {
    if (keyFor(action) == key) return;
    _bindings[action] = key;
    unawaited(_prefs?.setInt(_prefsKeyFor(action), key.keyId));
    notifyListeners();
  }

  /// Restore every action to its default key and clear the persisted values.
  void resetToDefaults() {
    for (final action in ShortcutAction.values) {
      _bindings[action] = action.defaultKey;
      unawaited(_prefs?.remove(_prefsKeyFor(action)));
    }
    notifyListeners();
  }
}
