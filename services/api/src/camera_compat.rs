//! Camera compatibility database: match a camera's ONVIF make/model against the
//! bundled `data/camera-compatibility.json` to surface known quirks and
//! recommended settings, and to prefill a community "contribute this camera"
//! report. See `docs/DECISIONS.md` (2026-07-10).
//!
//! The JSON is the same file the docs site renders; it is compiled in with
//! `include_str!` and parsed once. Matching is machine-first off each entry's
//! `match` block (an entry without one is documentation-only) and is two-tier:
//! an exact make+model hit is `Identified`; a make/alias hit with no model hit
//! is `Possible` and deliberately carries **no** entry, so we never assert one
//! model's quirks against a different model from the same maker. Firmware is
//! never used to match.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

/// The compiled-in database (same file the docs site renders).
const RAW_DB: &str = include_str!("../../../data/camera-compatibility.json");

#[derive(Debug, Deserialize)]
struct CompatFile {
    #[serde(default)]
    cameras: Vec<CompatEntry>,
}

/// One camera entry. Permissive on unknown fields so the schema can grow.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct CompatEntry {
    pub make: String,
    pub model: String,
    #[serde(default)]
    pub aka: Vec<String>,
    #[serde(default)]
    pub category: Option<String>,
    // Machine-match internals: deserialized from the JSON, never serialized back
    // out to a client (they're not useful there, and we don't leak the matcher).
    #[serde(default, rename = "match", skip_serializing)]
    match_block: Option<CameraMatch>,
    #[serde(default)]
    pub firmware_observed: Vec<String>,
    #[serde(default)]
    pub streams: Option<Streams>,
    #[serde(default)]
    pub support: BTreeMap<String, String>,
    #[serde(default)]
    pub quirks: Vec<Quirk>,
    #[serde(default)]
    pub recommended_settings: Vec<String>,
    #[serde(default)]
    pub references: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct CameraMatch {
    #[serde(default)]
    make: String,
    #[serde(default)]
    make_aliases: Vec<String>,
    #[serde(default)]
    models: Vec<String>,
    #[serde(default)]
    model_globs: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Streams {
    #[serde(default)]
    pub main: Option<Stream>,
    #[serde(default)]
    pub sub: Option<Stream>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Stream {
    pub codec: String,
    #[serde(default)]
    pub notes: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Quirk {
    pub summary: String,
    #[serde(default)]
    pub affects: Vec<String>,
    #[serde(default)]
    pub detail: Option<String>,
    #[serde(default)]
    pub fix: Option<String>,
}

/// How confident the match is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum MatchLevel {
    /// Exact make + model hit; the entry's quirks apply.
    Identified,
    /// The manufacturer is recognized but the exact model is not; carries no
    /// entry (do not assert another model's quirks).
    Possible,
    /// No recognized manufacturer.
    None,
}

/// Result of matching a camera against the database.
pub struct CompatMatch {
    pub level: MatchLevel,
    pub entry: Option<&'static CompatEntry>,
}

/// Parse the bundled DB once. A parse failure degrades to an empty database
/// (logged) rather than panicking a request; the `bundled_db_is_valid` test
/// guards against shipping a broken file.
fn db() -> &'static [CompatEntry] {
    static DB: OnceLock<Vec<CompatEntry>> = OnceLock::new();
    DB.get_or_init(|| match serde_json::from_str::<CompatFile>(RAW_DB) {
        Ok(f) => f.cameras,
        Err(e) => {
            tracing::error!(error = %e, "camera-compatibility.json failed to parse; matching disabled");
            Vec::new()
        }
    })
}

/// Normalize a make/model string for comparison: lowercase, ASCII alphanumerics
/// only (drops spaces, dashes, parens, dots, etc.).
fn normalize(s: &str) -> String {
    s.chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

/// Normalize a glob pattern, preserving the `*` wildcard.
fn glob_normalize(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '*')
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

/// Classic `*`-only wildcard match (`*` matches any run, including empty).
/// Both inputs must already be normalized.
fn glob_matches(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    let (mut i, mut j) = (0usize, 0usize);
    let mut star: Option<usize> = None;
    let mut mark = 0usize;
    while j < t.len() {
        if i < p.len() && (p[i] == t[j]) {
            i += 1;
            j += 1;
        } else if i < p.len() && p[i] == '*' {
            star = Some(i);
            mark = j;
            i += 1;
        } else if let Some(si) = star {
            i = si + 1;
            mark += 1;
            j = mark;
        } else {
            return false;
        }
    }
    while i < p.len() && p[i] == '*' {
        i += 1;
    }
    i == p.len()
}

impl CameraMatch {
    fn make_hit(&self, make_n: &str) -> bool {
        normalize(&self.make) == make_n || self.make_aliases.iter().any(|a| normalize(a) == make_n)
    }
    fn model_hit(&self, model_n: &str) -> bool {
        if model_n.is_empty() {
            return false;
        }
        self.models.iter().any(|m| normalize(m) == model_n)
            || self
                .model_globs
                .iter()
                .any(|g| glob_matches(&glob_normalize(g), model_n))
    }
}

/// Match a camera's reported make/model against the database.
pub fn match_camera(make: Option<&str>, model: Option<&str>) -> CompatMatch {
    let make_n = make.map(normalize).unwrap_or_default();
    let model_n = model.map(normalize).unwrap_or_default();
    if make_n.is_empty() {
        return CompatMatch {
            level: MatchLevel::None,
            entry: None,
        };
    }
    let mut any_make = false;
    for e in db() {
        let Some(m) = &e.match_block else { continue };
        if !m.make_hit(&make_n) {
            continue;
        }
        any_make = true;
        if m.model_hit(&model_n) {
            return CompatMatch {
                level: MatchLevel::Identified,
                entry: Some(e),
            };
        }
    }
    CompatMatch {
        // Manufacturer recognized but not the exact model: possible, no entry.
        level: if any_make {
            MatchLevel::Possible
        } else {
            MatchLevel::None
        },
        entry: None,
    }
}

/// Build the "contribute this camera" GitHub issue-form URL. Only short,
/// safe values go in the query string (make/model/firmware); longer details
/// (stream codecs, quirks) are pasted from the console modal, never URL-encoded.
/// Never include IPs, credentials, URLs, or the operator's camera name.
pub fn contribute_url(make: Option<&str>, model: Option<&str>, firmware: Option<&str>) -> String {
    fn enc(s: &str) -> String {
        // Minimal query-component encoding (no external dep): percent-encode
        // everything that isn't an unreserved char.
        let mut out = String::with_capacity(s.len());
        for b in s.bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    out.push(b as char);
                }
                b' ' => out.push_str("%20"),
                _ => out.push_str(&format!("%{b:02X}")),
            }
        }
        out
    }
    let mut url =
        String::from("https://github.com/badbread/crumbvms/issues/new?template=camera-report.yml");
    if let Some(v) = make.filter(|s| !s.is_empty()) {
        url.push_str(&format!("&make={}", enc(v)));
    }
    if let Some(v) = model.filter(|s| !s.is_empty()) {
        url.push_str(&format!("&model={}", enc(v)));
    }
    if let Some(v) = firmware.filter(|s| !s.is_empty()) {
        url.push_str(&format!("&firmware={}", enc(v)));
    }
    // Prefill the issue TITLE too (#60). The camera-report form's template sets a
    // placeholder `title:`, so without an explicit &title the opened issue keeps
    // "[camera] <Make> <Model>" verbatim. Build it from whatever identity we have,
    // matching that template's title shape.
    let title = match (
        make.filter(|s| !s.is_empty()),
        model.filter(|s| !s.is_empty()),
    ) {
        (Some(mk), Some(md)) => Some(format!("[camera] {mk} {md}")),
        (Some(mk), None) => Some(format!("[camera] {mk}")),
        (None, Some(md)) => Some(format!("[camera] {md}")),
        (None, None) => None,
    };
    if let Some(t) = title {
        url.push_str(&format!("&title={}", enc(&t)));
    }
    url
}

// ─── HTTP surface ────────────────────────────────────────────────────────────

use axum::{
    extract::{Path, State},
    routing::{get, post},
    Json, Router,
};
use uuid::Uuid;

use crate::{auth_mw::AuthUser, error::ApiError, state::AppState};
use crumb_common::db;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/cameras/:id/compat", get(get_compat))
        .route("/cameras/:id/compat-report", get(get_compat_report))
        .route("/cameras/:id/identify", post(identify))
}

/// Match result for a camera. Safe for any user who can see the camera: the
/// payload is public documentation content keyed by model.
#[derive(Serialize)]
struct CompatResponse {
    make: Option<String>,
    model: Option<String>,
    firmware: Option<String>,
    level: MatchLevel,
    identified: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    entry: Option<CompatEntry>,
}

fn build_response(
    make: Option<String>,
    model: Option<String>,
    firmware: Option<String>,
) -> CompatResponse {
    let m = match_camera(make.as_deref(), model.as_deref());
    CompatResponse {
        identified: m.level == MatchLevel::Identified,
        level: m.level,
        entry: m.entry.cloned(),
        make,
        model,
        firmware,
    }
}

/// `GET /cameras/:id/compat` — known quirks / recommended settings for a camera,
/// matched from its stored ONVIF make/model. Visible to any user with access to
/// the camera.
async fn get_compat(
    user: AuthUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
) -> Result<Json<CompatResponse>, ApiError> {
    user.assert_camera_access(camera_id)?;
    let (make, model, firmware) = db::get_camera_device_info(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(build_response(make, model, firmware)))
}

/// `POST /cameras/:id/identify` — probe ONVIF `GetDeviceInformation`, persist the
/// make/model/firmware, and return the fresh match. Admin only (it exercises the
/// camera's stored ONVIF credentials).
async fn identify(
    user: AuthUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
) -> Result<Json<CompatResponse>, ApiError> {
    if !user.is_admin() {
        return Err(ApiError::Forbidden(
            "identifying a camera requires admin".into(),
        ));
    }
    let camera = db::get_camera(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?
        .ok_or_else(|| ApiError::NotFound(format!("camera {camera_id} not found")))?;
    let cfg = crate::ptz::resolve_onvif_config(&state, &camera)?;
    let (make, model, firmware) = crate::ptz::onvif_device_info(&cfg).await.map_err(|e| {
        ApiError::Internal(anyhow::anyhow!("ONVIF GetDeviceInformation failed: {e}"))
    })?;
    db::set_camera_device_info(
        state.pool(),
        camera_id,
        make.as_deref(),
        model.as_deref(),
        firmware.as_deref(),
    )
    .await
    .map_err(ApiError::Internal)?;
    // Re-read: COALESCE means a partial probe keeps prior values for None fields.
    let (make, model, firmware) = db::get_camera_device_info(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?;
    Ok(Json(build_response(make, model, firmware)))
}

/// Whitelisted "contribute this camera" payload. Admin only. Contains ONLY
/// make/model/firmware + a prefilled issue-form URL, never IPs, credentials,
/// stream URLs, or the operator's camera name.
#[derive(Serialize)]
struct CompatReport {
    make: Option<String>,
    model: Option<String>,
    firmware: Option<String>,
    identified: bool,
    contribute_url: String,
}

/// `GET /cameras/:id/compat-report` — the safe contribute payload for the admin
/// "Contribute this camera" modal.
async fn get_compat_report(
    user: AuthUser,
    State(state): State<AppState>,
    Path(camera_id): Path<Uuid>,
) -> Result<Json<CompatReport>, ApiError> {
    if !user.is_admin() {
        return Err(ApiError::Forbidden(
            "contributing a camera requires admin".into(),
        ));
    }
    let (make, model, firmware) = db::get_camera_device_info(state.pool(), camera_id)
        .await
        .map_err(ApiError::Internal)?;
    let identified = matches!(
        match_camera(make.as_deref(), model.as_deref()).level,
        MatchLevel::Identified
    );
    let url = contribute_url(make.as_deref(), model.as_deref(), firmware.as_deref());
    Ok(Json(CompatReport {
        make,
        model,
        firmware,
        identified,
        contribute_url: url,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Guards against shipping an image whose bundled DB is malformed or whose
    // match blocks are unusable (CI fails here instead of the server no-op'ing).
    #[test]
    fn bundled_db_is_valid() {
        let f: CompatFile =
            serde_json::from_str(RAW_DB).expect("bundled camera-compatibility.json must parse");
        assert!(!f.cameras.is_empty(), "expected at least one camera entry");
        for e in &f.cameras {
            assert!(!e.make.is_empty(), "entry missing make");
            if let Some(m) = &e.match_block {
                assert!(
                    !m.make.is_empty(),
                    "{} {}: match block requires a normalized make",
                    e.make,
                    e.model
                );
                // A match block with a make but no models/globs can only ever
                // yield "possible"; allow it, but flag the likely mistake of an
                // empty make.
                assert!(
                    !normalize(&m.make).is_empty(),
                    "{} {}: match.make normalizes to empty",
                    e.make,
                    e.model
                );
            }
        }
    }

    #[test]
    fn normalize_strips_noise() {
        assert_eq!(normalize("IPC6322SR-X22P-D"), "ipc6322srx22pd");
        assert_eq!(normalize("UNIVIEW"), "uniview");
        assert_eq!(normalize("DS-2CD2387G2-LU(2.8mm)(C)"), "ds2cd2387g2lu28mmc");
    }

    #[test]
    fn identifies_the_uniview_lpr() {
        let m = match_camera(Some("UNIVIEW"), Some("IPC6322SR-X22P-D"));
        assert_eq!(m.level, MatchLevel::Identified);
        let e = m.entry.expect("identified match carries an entry");
        assert_eq!(e.make, "Uniview");
        assert!(!e.quirks.is_empty());
    }

    #[test]
    fn make_alias_without_model_is_possible_and_carries_no_entry() {
        let m = match_camera(Some("UNV"), Some("some-unknown-model"));
        assert_eq!(m.level, MatchLevel::Possible);
        assert!(
            m.entry.is_none(),
            "possible matches must not assert a specific model's quirks"
        );
    }

    #[test]
    fn unknown_make_is_none() {
        let m = match_camera(Some("Hikvision"), Some("DS-2CD2087"));
        assert_eq!(m.level, MatchLevel::None);
        assert!(m.entry.is_none());
    }

    #[test]
    fn empty_make_is_none() {
        assert_eq!(match_camera(None, Some("x")).level, MatchLevel::None);
        assert_eq!(match_camera(Some(""), Some("x")).level, MatchLevel::None);
    }

    #[test]
    fn glob_matching() {
        assert!(glob_matches("ds2cd2387*", "ds2cd2387g2lu28mmc"));
        assert!(glob_matches("*2387*", "ds2cd2387g2lu28mmc"));
        assert!(!glob_matches("ds2cd2388*", "ds2cd2387g2lu28mmc"));
        assert!(glob_matches("abc", "abc"));
        assert!(!glob_matches("abc", "abd"));
    }

    #[test]
    fn contribute_url_encodes_and_omits_empties() {
        let u = contribute_url(Some("Uniview"), Some("IPC6322SR-X22P-D"), None);
        assert!(u.contains("template=camera-report.yml"));
        assert!(u.contains("make=Uniview"));
        assert!(u.contains("model=IPC6322SR-X22P-D"));
        assert!(!u.contains("firmware="));
        // #60: the title is prefilled (URL-encoded) from make + model, so the
        // opened issue isn't left on the template placeholder.
        assert!(
            u.contains("&title=%5Bcamera%5D%20Uniview%20IPC6322SR-X22P-D"),
            "expected an encoded [camera] make model title, got: {u}"
        );
    }

    /// With no make/model there's nothing to build a meaningful title from, so
    /// no `&title=` is appended (the form falls back to its own placeholder).
    #[test]
    fn contribute_url_omits_title_when_unidentified() {
        let u = contribute_url(None, None, Some("1.2.3"));
        assert!(!u.contains("&title="));
        assert!(u.contains("firmware=1.2.3"));
    }
}
