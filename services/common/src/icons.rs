// SPDX-License-Identifier: AGPL-3.0-or-later

//! Icon-glyph resolution shared by the API (status + config DTOs) and clients.
//!
//! Two entities carry a customizable glyph:
//!
//! * **Storage** — a media glyph (`ssd`/`hdd`/`disk`). By default it is *inferred
//!   from the location name* (NVMe→SSD, Spinner→HDD, …); an operator may pin an
//!   explicit override when the heuristic guesses wrong.
//! * **Camera** — a form-factor glyph (`cam_ptz`/`cam_dome`/`cam_bullet`/
//!   `cam_lpr`/`cam_other`). By default it is *derived from `camera_type`*; an
//!   operator may pin a different glyph than the type implies.
//!
//! The override values stored in the DB are validated through
//! [`normalize_storage_icon`] / [`normalize_camera_icon`] (the API canonicalises
//! before writing; a CHECK constraint guards direct DB writes). [`storage_icon_kind`]
//! is the single resolution point so the desktop client renders exactly what the
//! admin console would — the JS `storageIcon()` heuristic in `admin.html` is kept
//! in lockstep with the name matching here.

/// Canonical storage media glyph kinds (also the DB CHECK allow-list).
pub const STORAGE_ICON_KINDS: [&str; 3] = ["ssd", "hdd", "disk"];

/// Canonical per-camera glyph keys (mirror the admin console `ICON_PATHS` keys;
/// also the DB CHECK allow-list).
pub const CAMERA_ICON_KINDS: [&str; 5] =
    ["cam_ptz", "cam_dome", "cam_bullet", "cam_lpr", "cam_other"];

/// Validate + canonicalise a storage icon override. Accepts the canonical kinds
/// plus a few friendly aliases; returns `None` for anything unrecognised.
#[must_use]
pub fn normalize_storage_icon(s: &str) -> Option<&'static str> {
    match s.trim().to_ascii_lowercase().as_str() {
        "ssd" | "nvme" | "flash" | "m.2" | "m2" => Some("ssd"),
        "hdd" | "spinner" | "spinning" | "sata" | "platter" => Some("hdd"),
        "disk" | "generic" | "other" => Some("disk"),
        _ => None,
    }
}

/// Validate + canonicalise a camera icon override (a glyph key). Accepts the
/// canonical `cam_*` keys plus the bare `camera_type` words; returns `None` for
/// anything unrecognised.
#[must_use]
pub fn normalize_camera_icon(s: &str) -> Option<&'static str> {
    match s.trim().to_ascii_lowercase().as_str() {
        "cam_ptz" | "ptz" => Some("cam_ptz"),
        "cam_dome" | "dome" => Some("cam_dome"),
        "cam_bullet" | "bullet" => Some("cam_bullet"),
        "cam_lpr" | "lpr" => Some("cam_lpr"),
        "cam_other" | "other" | "generic" => Some("cam_other"),
        _ => None,
    }
}

/// Resolve the storage media glyph: an explicit (valid) override wins, else the
/// glyph is inferred from `name`. Kept in lockstep with the `storageIcon()`
/// heuristic in `admin.html` so the admin console and desktop agree.
#[must_use]
pub fn storage_icon_kind(name: &str, icon_override: Option<&str>) -> &'static str {
    if let Some(o) = icon_override.and_then(normalize_storage_icon) {
        return o;
    }
    let n = name.to_ascii_lowercase();
    const SSD: [&str; 5] = ["nvme", "ssd", "flash", "m.2", "m2"];
    const HDD: [&str; 7] = [
        "spinner", "spinning", "hdd", "sata", "disk", "drive", "platter",
    ];
    if SSD.iter().any(|k| n.contains(k)) {
        "ssd"
    } else if HDD.iter().any(|k| n.contains(k)) {
        "hdd"
    } else {
        "disk"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn name_inference_matches_admin_heuristic() {
        assert_eq!(storage_icon_kind("2TB NVMe", None), "ssd");
        assert_eq!(storage_icon_kind("16TB Spinner", None), "hdd");
        assert_eq!(storage_icon_kind("NAS-Archive", None), "disk");
        assert_eq!(storage_icon_kind("Samsung 990 SSD", None), "ssd");
    }

    #[test]
    fn explicit_override_wins_over_name() {
        // A flash array misleadingly named "Bulk" → operator pins SSD.
        assert_eq!(storage_icon_kind("Bulk", Some("ssd")), "ssd");
        // An invalid override falls back to the name heuristic, not garbage.
        assert_eq!(storage_icon_kind("16TB Spinner", Some("bogus")), "hdd");
    }

    #[test]
    fn normalizers_canonicalise_and_reject() {
        assert_eq!(normalize_storage_icon("NVMe"), Some("ssd"));
        assert_eq!(normalize_storage_icon("hdd"), Some("hdd"));
        assert_eq!(normalize_storage_icon("nope"), None);
        assert_eq!(normalize_camera_icon("dome"), Some("cam_dome"));
        assert_eq!(normalize_camera_icon("cam_lpr"), Some("cam_lpr"));
        assert_eq!(normalize_camera_icon("nope"), None);
    }
}
