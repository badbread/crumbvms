// SPDX-License-Identifier: AGPL-3.0-or-later

//! Admin-only diagnostics bundle: a scrubbed, downloadable snapshot of the
//! server's version, effective config, key environment, and schema state, so a
//! maintainer can triage a tester's server-side issue without a shell on the box.
//!
//! Secure by default: the route is admin-only, and EVERYTHING it emits is run
//! through [`redact`] before it leaves the box (a recursive pass that masks any
//! value under a secret-shaped key AND any URL userinfo). A leak would require
//! both an unexpected field name and a non-URL secret shape.
//!
//! Out of scope for now (issue #180): live logs and runtime health. Logs are
//! stdout-only, so shipping them needs an in-process ring buffer (and the
//! recorder's logs live in a separate process); that is a follow-up.

use axum::{
    extract::State,
    http::header,
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use serde_json::{json, Value};

use crate::auth_mw::AdminUser;
use crate::error::ApiError;
use crate::state::AppState;
use crumb_common::db;

// Version stamps, mirrored from `main.rs` via the same `include_str!`/`option_env!`
// so this module stays self-contained (the test harness re-includes it into a
// crate that has no `crate::VERSION`). Paths resolve relative to THIS file.
const VERSION: &str = include_str!("../../../VERSION");
const GIT_SHA: Option<&str> = option_env!("CRUMB_GIT_SHA");
const BUILD_TIME: Option<&str> = option_env!("CRUMB_BUILD_TIME");

/// Mount the diagnostics routes onto the root router.
pub fn routes() -> Router<AppState> {
    Router::new().route("/diagnostics/bundle", get(diagnostics_bundle))
}

/// `GET /diagnostics/bundle` — admin only. Returns a scrubbed JSON diagnostics
/// snapshot as a file attachment.
async fn diagnostics_bundle(
    _admin: AdminUser,
    State(state): State<AppState>,
) -> Result<Response, ApiError> {
    let pool = state.pool();

    // Effective server settings (DB row; absent on a brand-new pre-wizard install).
    let config = match db::get_server_settings(pool)
        .await
        .map_err(ApiError::Internal)?
    {
        Some(s) => serde_json::to_value(&s).unwrap_or(Value::Null),
        None => Value::Null,
    };

    // Applied schema migrations — tells whether the DB is at the expected version.
    // Non-fatal if the table is unreadable (report "unknown" rather than 500).
    let database = match db::list_applied_migrations(pool).await {
        Ok(rows) => {
            let latest: Vec<String> = rows
                .iter()
                .rev()
                .take(5)
                .map(|(filename, _)| filename.clone())
                .collect();
            json!({
                "applied_migration_count": rows.len(),
                "latest_migrations": latest,
            })
        }
        Err(_) => json!({ "applied_migration_count": null, "latest_migrations": [] }),
    };

    let mut bundle = json!({
        "generated_at": chrono::Utc::now().to_rfc3339(),
        "version": {
            "service": "crumb-api",
            "version": VERSION.trim(),
            "git_sha": GIT_SHA.unwrap_or("unknown"),
            "built_at": BUILD_TIME.unwrap_or("unknown"),
        },
        "config": config,
        "env": safe_env(),
        "database": database,
        "notes": "Redacted: values under secret-shaped keys and any URL credentials. \
                  Live logs and runtime health are not yet included (issue #180).",
    });

    // Belt-and-suspenders: scrub the ENTIRE bundle before it leaves the box.
    redact(&mut bundle);

    let body = serde_json::to_vec_pretty(&bundle).map_err(|e| ApiError::Internal(e.into()))?;
    let ts = chrono::Utc::now().format("%Y%m%d-%H%M%S");
    let filename = format!("crumb-diagnostics-{ts}.json");
    Ok((
        [
            (header::CONTENT_TYPE, "application/json".to_owned()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{filename}\""),
            ),
        ],
        body,
    )
        .into_response())
}

/// A curated, NON-secret subset of the environment. Deliberately a whitelist:
/// never dump `std::env::vars()`, which would sweep up `DATABASE_URL`, the seed
/// admin password hash, and any tokens. [`redact`] still runs over the result as
/// a backstop.
fn safe_env() -> Value {
    const SAFE_KEYS: &[&str] = &[
        "LOG_FORMAT",
        "LOG_LEVEL",
        "RUST_LOG",
        "TZ",
        "CRUMB_VERSION",
        "CRUMB_IMAGE_PREFIX",
        "MOTION_HWACCEL",
        "SEGMENT_SECONDS",
    ];
    let mut map = serde_json::Map::new();
    for key in SAFE_KEYS {
        if let Ok(value) = std::env::var(key) {
            map.insert((*key).to_owned(), Value::String(value));
        }
    }
    Value::Object(map)
}

// ── redaction ────────────────────────────────────────────────────────────────

/// Recursively scrub a JSON value in place: any value under a secret-shaped key
/// (see [`is_secret_key`]) becomes `"***REDACTED***"`, and any string carrying
/// URL userinfo (`scheme://user:pass@host`) has that userinfo masked. Two
/// independent nets so a leak needs both a surprising field name and a non-URL
/// secret shape.
pub(crate) fn redact(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, val) in map.iter_mut() {
                if is_secret_key(key) {
                    *val = Value::String("***REDACTED***".to_owned());
                } else {
                    redact(val);
                }
            }
        }
        Value::Array(items) => {
            for item in items.iter_mut() {
                redact(item);
            }
        }
        Value::String(s) => {
            if let Some(masked) = mask_url_userinfo(s) {
                *s = masked;
            }
        }
        _ => {}
    }
}

/// A key whose value must never be emitted.
fn is_secret_key(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    [
        "token",
        "password",
        "passwd",
        "secret",
        "hash",
        "apikey",
        "api_key",
        "credential",
        "private",
    ]
    .iter()
    .any(|needle| k.contains(needle))
}

/// If `s` contains a `scheme://userinfo@host...` URL, return it with the userinfo
/// masked (`scheme://***@host...`); otherwise `None`. Dependency-free: no regex,
/// so it never pulls a crate in for one pattern.
fn mask_url_userinfo(s: &str) -> Option<String> {
    let scheme_end = s.find("://")?;
    // The bit before "://" must look like a URL scheme (letters/digits/+-.).
    let scheme = &s[..scheme_end];
    if scheme.is_empty()
        || !scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    {
        return None;
    }
    let after_scheme = scheme_end + 3;
    let rest = &s[after_scheme..];
    // Authority ends at the first '/', '?', or '#'.
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    // No '@' in the authority => no userinfo to mask.
    let at = authority.find('@')?;
    // Rebuild: "<scheme>://" + "***@" + "<host + remainder>".
    Some(format!("{}***@{}", &s[..after_scheme], &rest[at + 1..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_secret_shaped_keys_anywhere_in_the_tree() {
        let mut v = json!({
            "version": "0.1.1",
            "config": {
                "frigate_api_base": "http://frigate:1984",
                "ha_token": "super-secret-token",
                "nested": { "password": "hunter2", "note": "keep" }
            },
            "list": [ { "api_key": "abc123" } ]
        });
        redact(&mut v);
        assert_eq!(v["version"], "0.1.1");
        assert_eq!(v["config"]["frigate_api_base"], "http://frigate:1984");
        assert_eq!(v["config"]["ha_token"], "***REDACTED***");
        assert_eq!(v["config"]["nested"]["password"], "***REDACTED***");
        assert_eq!(v["config"]["nested"]["note"], "keep");
        assert_eq!(v["list"][0]["api_key"], "***REDACTED***");
    }

    #[test]
    fn masks_url_userinfo_but_keeps_the_host() {
        // Documentation-range address, not a real camera (gitleaks:allow).
        let masked = mask_url_userinfo("rtsp://admin:p%40ss@192.0.2.10:554/Streaming").unwrap();
        assert_eq!(masked, "rtsp://***@192.0.2.10:554/Streaming");
        // No userinfo => untouched.
        assert!(mask_url_userinfo("http://frigate:1984/api").is_none());
        // Not a URL => untouched.
        assert!(mask_url_userinfo("just a plain string").is_none());
        // '@' only in the path, not the authority => untouched.
        assert!(mask_url_userinfo("https://host/path@thing").is_none());
    }

    #[test]
    fn redact_masks_credential_urls_in_string_values() {
        // A URL sitting under a NON-secret key must still have creds masked.
        let mut v = json!({ "source_url": "rtsp://u:pw@192.0.2.10/s" }); // gitleaks:allow
        redact(&mut v);
        assert_eq!(v["source_url"], "rtsp://***@192.0.2.10/s");
    }
}
