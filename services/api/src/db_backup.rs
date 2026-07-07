// SPDX-License-Identifier: AGPL-3.0-or-later

//! Built-in nightly Postgres backup job.
//!
//! Replaces the former `db-backup` compose sidecar
//! (`prodrigestivill/postgres-backup-local`): the API now owns the daily
//! `pg_dump` + tiered rotation itself, against the same `DATABASE_URL` it
//! already holds. One less image, and failures are reported *directly* into
//! the `backup_failed` system-alert pipeline instead of only being inferred
//! from dump staleness (the staleness watchdog in `alerts.rs` stays as a
//! backstop).
//!
//! ## On-disk layout (sidecar-compatible)
//!
//! Written under `BACKUP_DIR` (default `/backups`, the same bind mount the
//! staleness watchdog reads — now mounted read-write):
//!
//! ```text
//! daily/<db>-YYYYMMDD-HHMMSS.sql.gz      # one per run (gzipped plain pg_dump)
//! daily/<db>-latest.sql.gz               # symlink -> newest daily dump
//! weekly/<db>-<ISOyear><ISOweek>.sql.gz  # hard link, refreshed each run (keep_weeks > 0)
//! monthly/<db>-YYYYMM.sql.gz             # hard link, refreshed each run (keep_months > 0)
//! last/<db>-latest.sql.gz                # symlink -> newest daily dump
//! ```
//!
//! Dumps use `pg_dump -Z1 --no-owner --no-privileges` (identical flags to the
//! sidecar), written atomically (`.partial` temp file + rename). Rotation
//! keeps the newest `DB_BACKUP_KEEP_DAYS` / `_WEEKS` / `_MONTHS` files per
//! tier, never deletes the newest file of a tier, and only ever touches files
//! matching our own naming pattern — an operator's manual dumps (e.g. from
//! `scripts/backup-db.sh`) are left alone.
//!
//! ## Schedule
//!
//! Daily at `DB_BACKUP_SCHEDULE` (a local wall-clock `HH:MM`, default
//! `03:15`) in the `TZ` timezone (IANA name, default `America/Los_Angeles`).
//! Legacy sidecar values are tolerated: `@daily` maps to the default, and a
//! simple 5-field daily cron (`M H * * *`) is read as `H:M`. On boot, if the
//! newest dump is missing or older than ~25 h, a catch-up dump runs
//! immediately (fresh installs get a first dump right away; missed windows
//! self-heal).
//!
//! ## Feature gate
//!
//! `DB_BACKUP_ENABLED=false` opts out entirely. An absent `BACKUP_DIR` (env
//! unset) disables with an info log; an unwritable dir disables with a loud
//! warning **plus one `backup_failed` system event** (a misconfiguration
//! worth paging on) — but the API itself stays healthy either way: backups
//! being disabled must never take the API down.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Datelike, TimeZone, Utc};
use chrono_tz::Tz;
use deadpool_postgres::Pool;

use crumb_common::db;

/// Default schedule (local wall clock) when `DB_BACKUP_SCHEDULE` is
/// unset/unparseable: 03:15 — the time the manual-cron docs have always used.
const DEFAULT_HOUR: u32 = 3;
const DEFAULT_MINUTE: u32 = 15;

/// Boot catch-up threshold: dump immediately at startup when the newest dump
/// is missing or older than this (~25 h — one daily period plus slack,
/// mirroring `DEFAULT_BACKUP_STALE_SECS` in `alerts.rs`).
const BOOT_CATCHUP_SECS: i64 = 25 * 3600;

/// Fixed `pg_dump` flags — identical to the retired sidecar's
/// `POSTGRES_EXTRA_OPTS` (`-Z1 --no-owner --no-privileges`): gzip level 1,
/// and no owner/privilege statements so a dump restores cleanly onto a
/// differently-named role.
const PG_DUMP_ARGS: [&str; 3] = ["-Z1", "--no-owner", "--no-privileges"];

// ─── env / config ─────────────────────────────────────────────────────────────

/// `DB_BACKUP_ENABLED` — default true; only an explicit falsy value opts out.
fn env_enabled() -> bool {
    std::env::var("DB_BACKUP_ENABLED").map_or(true, |v| {
        !matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "false" | "0" | "no" | "off"
        )
    })
}

/// Read a keep-count env var, falling back to `default` when unset/invalid.
fn env_keep(key: &str, default: usize) -> usize {
    let Ok(v) = std::env::var(key) else {
        return default;
    };
    v.trim().parse::<usize>().unwrap_or_else(|_| {
        tracing::warn!("{key}='{v}' is not a non-negative integer — using {default}");
        default
    })
}

/// Timezone the schedule is evaluated in: `TZ` env (IANA name), default
/// `America/Los_Angeles`. `chrono-tz` embeds the IANA db, so no system tzdata
/// is needed in the image.
fn schedule_tz() -> Tz {
    let Ok(v) = std::env::var("TZ") else {
        return Tz::America__Los_Angeles;
    };
    v.trim().parse::<Tz>().unwrap_or_else(|_| {
        tracing::warn!("TZ='{v}' is not a recognized IANA timezone — using America/Los_Angeles");
        Tz::America__Los_Angeles
    })
}

/// Parse `DB_BACKUP_SCHEDULE` into a local `(hour, minute)`.
///
/// Accepted forms:
/// - `"HH:MM"` (canonical, e.g. `"03:15"`)
/// - `"@daily"` / `"@midnight"` — legacy sidecar shorthand, mapped to the
///   documented default 03:15
/// - `"M H * * *"` — a simple 5-field daily cron (the only cron shape the old
///   sidecar docs suggested), read as `H:M`
///
/// Anything else yields `None` (caller falls back to the default with a
/// warning).
fn parse_schedule(raw: &str) -> Option<(u32, u32)> {
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    if s.eq_ignore_ascii_case("@daily") || s.eq_ignore_ascii_case("@midnight") {
        return Some((DEFAULT_HOUR, DEFAULT_MINUTE));
    }
    if let Some((h, m)) = s.split_once(':') {
        if let (Ok(h), Ok(m)) = (h.trim().parse::<u32>(), m.trim().parse::<u32>()) {
            if h < 24 && m < 60 {
                return Some((h, m));
            }
        }
        return None;
    }
    let fields: Vec<&str> = s.split_whitespace().collect();
    if fields.len() == 5 && fields[2..] == ["*", "*", "*"] {
        if let (Ok(m), Ok(h)) = (fields[0].parse::<u32>(), fields[1].parse::<u32>()) {
            if h < 24 && m < 60 {
                return Some((h, m));
            }
        }
    }
    None
}

/// Database name for dump filenames, parsed from the connection URL's path.
/// Falls back to `"crumb"` if the URL doesn't parse (the pool already
/// connected with it, so this is theoretical).
fn db_name_from_url(database_url: &str) -> String {
    url::Url::parse(database_url)
        .ok()
        .map(|u| u.path().trim_start_matches('/').to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "crumb".to_owned())
}

// ─── scheduling (pure) ────────────────────────────────────────────────────────

/// Next UTC instant strictly after `now` at which local wall-clock
/// `hour:minute` occurs in `tz`. DST-aware: an ambiguous local time
/// (fall-back) uses the earlier occurrence; a nonexistent one (spring-forward
/// gap) skips to the next day.
fn next_run_after(now: DateTime<Utc>, hour: u32, minute: u32, tz: Tz) -> DateTime<Utc> {
    let local_date = now.with_timezone(&tz).date_naive();
    for day_offset in 0..3 {
        let date = local_date + chrono::Duration::days(day_offset);
        let Some(naive) = date.and_hms_opt(hour, minute, 0) else {
            continue;
        };
        let cand = match tz.from_local_datetime(&naive) {
            chrono::LocalResult::Single(dt) | chrono::LocalResult::Ambiguous(dt, _) => dt,
            chrono::LocalResult::None => continue, // DST gap — this wall time doesn't exist today
        };
        let cand_utc = cand.with_timezone(&Utc);
        if cand_utc > now {
            return cand_utc;
        }
    }
    // Unreachable in practice (a valid HH:MM occurs within 3 days); safe fallback.
    now + chrono::Duration::hours(24)
}

/// Pure boot-catch-up decision: dump now when there is no previous dump, or
/// the newest is older than [`BOOT_CATCHUP_SECS`].
fn needs_boot_dump(newest_age_secs: Option<i64>) -> bool {
    newest_age_secs.is_none_or(|a| a > BOOT_CATCHUP_SECS)
}

// ─── filenames + rotation (pure) ──────────────────────────────────────────────

/// Extract the timestamp key from one of OUR dump filenames, or `None` for
/// anything else (manual dumps, `-latest` symlinks, stray files — all sacred).
///
/// Recognized keys after the `<db>-` prefix and before `.sql.gz`:
/// - daily: `YYYYMMDD-HHMMSS` (8 digits, `-`, 6 digits)
/// - weekly/monthly: 6 digits (`<ISOyear><ISOweek>` / `YYYYMM`)
fn parse_dump_key<'a>(file_name: &'a str, db: &str) -> Option<&'a str> {
    let key = file_name
        .strip_prefix(db)?
        .strip_prefix('-')?
        .strip_suffix(".sql.gz")?;
    let all_digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let ok = match key.len() {
        6 => all_digits(key),
        15 => all_digits(&key[..8]) && key.as_bytes()[8] == b'-' && all_digits(&key[9..]),
        _ => false,
    };
    ok.then_some(key)
}

/// Pure rotation: given the file names present in ONE tier directory, return
/// the names to delete so that only the newest `keep` of OUR dumps remain.
///
/// Guarantees:
/// - never deletes the newest matching file (`keep` is clamped to ≥ 1);
/// - never returns a name that doesn't match [`parse_dump_key`] — operators'
///   manual dumps and the `-latest` symlinks are untouchable.
///
/// Keys are zero-padded timestamps, so sorting by key is chronological.
fn rotation_deletions(names: &[String], db: &str, keep: usize) -> Vec<String> {
    let mut matching: Vec<String> = names
        .iter()
        .filter(|n| parse_dump_key(n, db).is_some())
        .cloned()
        .collect();
    matching.sort_by(|a, b| parse_dump_key(a, db).cmp(&parse_dump_key(b, db)));
    let keep = keep.max(1); // the newest dump is never rotation-deleted
    if matching.len() <= keep {
        return Vec::new();
    }
    let delete_count = matching.len() - keep;
    matching.truncate(delete_count); // ascending sort → the front is the oldest
    matching
}

// ─── filesystem helpers ───────────────────────────────────────────────────────

/// Age (seconds) of the newest of OUR daily dumps (by mtime), or `None` when
/// there are none. Only pattern-matching files count, so a manual dump doesn't
/// suppress the boot catch-up.
fn newest_own_dump_age_secs(daily_dir: &Path, db: &str) -> Option<i64> {
    let rd = std::fs::read_dir(daily_dir).ok()?;
    let mut best: Option<std::time::SystemTime> = None;
    for entry in rd.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if parse_dump_key(name, db).is_none() {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        if let Ok(mtime) = meta.modified() {
            if best.is_none_or(|b| mtime > b) {
                best = Some(mtime);
            }
        }
    }
    best.map(|t| {
        std::time::SystemTime::now()
            .duration_since(t)
            .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
    })
}

/// Create the tier subdirectories and probe writability (create + remove a
/// probe file in `daily/`). Errors here mean "backups can't work" — the
/// caller logs and disables the job without affecting API health.
fn prepare_layout(root: &Path, keep_weeks: usize, keep_months: usize) -> std::io::Result<()> {
    if !root.is_dir() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("{} does not exist (is the volume mounted?)", root.display()),
        ));
    }
    std::fs::create_dir_all(root.join("daily"))?;
    std::fs::create_dir_all(root.join("last"))?;
    if keep_weeks > 0 {
        std::fs::create_dir_all(root.join("weekly"))?;
    }
    if keep_months > 0 {
        std::fs::create_dir_all(root.join("monthly"))?;
    }
    let probe = root.join("daily").join(".crumb-write-probe");
    std::fs::write(&probe, b"probe")?;
    std::fs::remove_file(&probe)?;
    Ok(())
}

/// Point symlink `link` at `target` (remove + recreate).
fn replace_symlink(link: &Path, target: &str) -> std::io::Result<()> {
    match std::fs::remove_file(link) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    std::os::unix::fs::symlink(target, link)
}

/// Refresh a weekly/monthly tier file as a hard link to the newest daily dump
/// (same behavior as the sidecar: the tier file is always that period's most
/// recent dump; hard links cost no extra bytes and survive daily rotation).
fn refresh_tier_link(daily_file: &Path, tier_file: &Path) -> std::io::Result<()> {
    match std::fs::remove_file(tier_file) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    std::fs::hard_link(daily_file, tier_file)
}

/// Redact secrets (the full connection URL and its password, if any) from
/// `pg_dump` stderr before it reaches logs or system events.
fn scrub_secrets(text: &str, database_url: &str) -> String {
    let mut out = text.replace(database_url, "<database-url>");
    if let Ok(u) = url::Url::parse(database_url) {
        if let Some(pass) = u.password() {
            if !pass.is_empty() {
                out = out.replace(pass, "<redacted>");
            }
        }
    }
    out
}

fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_owned()
    } else {
        let cut: String = s.chars().take(max).collect();
        format!("{cut}…")
    }
}

// ─── the job ──────────────────────────────────────────────────────────────────

/// Everything one backup run needs — bundled so the run path doesn't juggle
/// eight loose parameters.
struct BackupJob {
    pool: Pool,
    database_url: String,
    /// Database name (for dump filenames), parsed from the URL.
    db: String,
    /// `BACKUP_DIR` root (the `/backups` mount).
    root: PathBuf,
    tz: Tz,
    keep_days: usize,
    keep_weeks: usize,
    keep_months: usize,
}

impl BackupJob {
    /// Run one `pg_dump` into `daily/`, atomically (temp `.partial` + rename),
    /// verifying the output is a non-trivial gzip file before promoting it.
    /// Returns the final path + size in bytes.
    async fn perform_dump(&self, stamp: &str) -> anyhow::Result<(PathBuf, u64)> {
        let daily = self.root.join("daily");
        let final_path = daily.join(format!("{}-{stamp}.sql.gz", self.db));
        let tmp_path = daily.join(format!("{}-{stamp}.sql.gz.partial", self.db));

        let output = tokio::process::Command::new("pg_dump")
            .args(PG_DUMP_ARGS)
            .arg("--dbname")
            .arg(&self.database_url)
            .arg("-f")
            .arg(&tmp_path)
            .kill_on_drop(true)
            .output()
            .await
            .map_err(|e| {
                anyhow::anyhow!(
                    "failed to spawn pg_dump (postgresql-client missing from image?): {e}"
                )
            })?;

        if !output.status.success() {
            let stderr =
                scrub_secrets(&String::from_utf8_lossy(&output.stderr), &self.database_url);
            let _ = std::fs::remove_file(&tmp_path);
            anyhow::bail!(
                "pg_dump exited with {}: {}",
                output.status,
                truncate_chars(stderr.trim(), 400)
            );
        }

        // Integrity: non-trivial size + gzip magic bytes, before promoting.
        let meta = std::fs::metadata(&tmp_path)?;
        let magic_ok = std::fs::File::open(&tmp_path).is_ok_and(|mut f| {
            use std::io::Read;
            let mut magic = [0u8; 2];
            f.read_exact(&mut magic).is_ok() && magic == [0x1f, 0x8b]
        });
        if meta.len() < 64 || !magic_ok {
            let _ = std::fs::remove_file(&tmp_path);
            anyhow::bail!(
                "dump output failed integrity check (size {} bytes, gzip magic {}) — not promoting partial file",
                meta.len(),
                if magic_ok { "ok" } else { "MISSING" }
            );
        }

        std::fs::rename(&tmp_path, &final_path)?;
        Ok((final_path, meta.len()))
    }

    /// Post-dump housekeeping: refresh weekly/monthly hard links + `-latest`
    /// symlinks, then rotate every active tier. Individual failures warn and
    /// continue — housekeeping problems must not fail the backup itself.
    fn update_tiers_and_rotate(&self, daily_path: &Path, today: chrono::NaiveDate) {
        let daily_name = daily_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or_default()
            .to_owned();

        // Weekly / monthly hard links (only for enabled tiers).
        if self.keep_weeks > 0 {
            let iso = today.iso_week();
            let name = format!("{}-{}{:02}.sql.gz", self.db, iso.year(), iso.week());
            let tier_file = self.root.join("weekly").join(name);
            if let Err(e) = refresh_tier_link(daily_path, &tier_file) {
                tracing::warn!(error = %e, path = %tier_file.display(), "weekly backup link failed");
            }
        }
        if self.keep_months > 0 {
            let name = format!("{}-{}{:02}.sql.gz", self.db, today.year(), today.month());
            let tier_file = self.root.join("monthly").join(name);
            if let Err(e) = refresh_tier_link(daily_path, &tier_file) {
                tracing::warn!(error = %e, path = %tier_file.display(), "monthly backup link failed");
            }
        }

        // `-latest` symlinks (daily/ + last/), pointing at the newest daily dump.
        let latest_name = format!("{}-latest.sql.gz", self.db);
        if let Err(e) = replace_symlink(&self.root.join("daily").join(&latest_name), &daily_name) {
            tracing::warn!(error = %e, "daily/{latest_name} symlink update failed");
        }
        let rel_target = format!("../daily/{daily_name}");
        if let Err(e) = replace_symlink(&self.root.join("last").join(&latest_name), &rel_target) {
            tracing::warn!(error = %e, "last/{latest_name} symlink update failed");
        }

        // Rotation, per active tier.
        let tiers: [(&str, usize); 3] = [
            ("daily", self.keep_days),
            ("weekly", self.keep_weeks),
            ("monthly", self.keep_months),
        ];
        for (tier, keep) in tiers {
            if keep == 0 {
                continue; // tier disabled — create nothing, delete nothing
            }
            let dir = self.root.join(tier);
            let names: Vec<String> = match std::fs::read_dir(&dir) {
                Ok(rd) => rd
                    .flatten()
                    .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
                    .filter_map(|e| e.file_name().to_str().map(str::to_owned))
                    .collect(),
                Err(_) => continue,
            };
            for name in rotation_deletions(&names, &self.db, keep) {
                let path = dir.join(&name);
                match std::fs::remove_file(&path) {
                    Ok(()) => tracing::info!(path = %path.display(), "rotated out old backup"),
                    Err(e) => {
                        tracing::warn!(error = %e, path = %path.display(), "backup rotation delete failed");
                    }
                }
            }
        }
    }

    /// One full backup run: dump, housekeep, report. A failure emits a
    /// `backup_failed` system event *directly* (the staleness watchdog in
    /// `alerts.rs` remains as a backstop).
    async fn run_once(&self) {
        let now_local = Utc::now().with_timezone(&self.tz);
        let stamp = now_local.format("%Y%m%d-%H%M%S").to_string();
        match self.perform_dump(&stamp).await {
            Ok((path, size_bytes)) => {
                tracing::info!(path = %path.display(), size_bytes, "database backup written");
                self.update_tiers_and_rotate(&path, now_local.date_naive());
            }
            Err(e) => {
                tracing::error!(error = %e, "database backup FAILED");
                emit_backup_failed(&self.pool, &format!("nightly pg_dump failed: {e}")).await;
            }
        }
    }
}

/// Emit a `backup_failed` system event (same pipeline the staleness watchdog
/// feeds — routed to the operator's notification channels).
async fn emit_backup_failed(pool: &Pool, detail: &str) {
    if let Err(e) = db::insert_system_event(pool, "backup_failed", None, Some(detail)).await {
        tracing::warn!(error = %e, "db-backup: insert_system_event(backup_failed) failed");
    }
}

// ─── entry point ──────────────────────────────────────────────────────────────

/// Background task: the API's built-in nightly DB backup. Spawned once from
/// `main.rs`; never returns unless backups are disabled/unconfigurable.
pub async fn run_db_backup_job(pool: Pool, database_url: String) {
    if !env_enabled() {
        tracing::info!("DB_BACKUP_ENABLED=false — built-in DB backup job disabled");
        return;
    }
    let Some(dir) = std::env::var("BACKUP_DIR")
        .ok()
        .map(|d| d.trim().to_owned())
        .filter(|d| !d.is_empty())
    else {
        tracing::info!("BACKUP_DIR unset — built-in DB backup job disabled");
        return;
    };
    let root = PathBuf::from(&dir);

    let keep_days = env_keep("DB_BACKUP_KEEP_DAYS", 7);
    let keep_weeks = env_keep("DB_BACKUP_KEEP_WEEKS", 4);
    let keep_months = env_keep("DB_BACKUP_KEEP_MONTHS", 0);
    let tz = schedule_tz();
    let (hour, minute) = match std::env::var("DB_BACKUP_SCHEDULE") {
        Ok(raw) => parse_schedule(&raw).unwrap_or_else(|| {
            tracing::warn!(
                "DB_BACKUP_SCHEDULE='{raw}' not understood (want local \"HH:MM\") — using {DEFAULT_HOUR:02}:{DEFAULT_MINUTE:02}"
            );
            (DEFAULT_HOUR, DEFAULT_MINUTE)
        }),
        Err(_) => (DEFAULT_HOUR, DEFAULT_MINUTE),
    };
    let db_name = db_name_from_url(&database_url);

    if let Err(e) = prepare_layout(&root, keep_weeks, keep_months) {
        tracing::warn!(
            dir = %root.display(),
            error = %e,
            "backup dir is absent/unwritable — built-in DB backups DISABLED (the API stays up). \
             Fix: make the host dir behind the /backups mount writable by uid 1001 \
             (`chown -R 1001:1001 <DB_BACKUP_HOST_PATH>`), then restart the api container."
        );
        if e.kind() != std::io::ErrorKind::NotFound {
            // Dir exists but can't be written — a misconfiguration worth paging
            // on (the staleness backstop can't catch a fresh install that never
            // produced a first dump).
            emit_backup_failed(
                &pool,
                &format!(
                    "built-in DB backup disabled: backup dir '{dir}' is not writable by the api \
                     (uid 1001): {e}. Run `chown -R 1001:1001` on the host dir and restart the api."
                ),
            )
            .await;
        }
        return;
    }

    let job = BackupJob {
        pool,
        database_url,
        db: db_name,
        root,
        tz,
        keep_days,
        keep_weeks,
        keep_months,
    };

    tracing::info!(
        dir = %job.root.display(),
        schedule = %format!("{hour:02}:{minute:02} {tz}"),
        keep_days,
        keep_weeks,
        keep_months,
        "built-in DB backup job started (replaces the db-backup sidecar)"
    );

    // Boot catch-up: fresh installs get an immediate first dump; a missed
    // nightly window (host powered off at 03:15) self-heals on next boot.
    let newest_age = newest_own_dump_age_secs(&job.root.join("daily"), &job.db);
    if needs_boot_dump(newest_age) {
        tracing::info!(
            newest_age_secs = newest_age,
            "no fresh backup found — running boot catch-up dump"
        );
        job.run_once().await;
    }

    loop {
        let now = Utc::now();
        let next = next_run_after(now, hour, minute, tz);
        let sleep_secs = (next - now).num_seconds().max(1);
        tracing::debug!(next = %next, sleep_secs, "db-backup sleeping until next scheduled run");
        tokio::time::sleep(std::time::Duration::from_secs(
            u64::try_from(sleep_secs).unwrap_or(86_400),
        ))
        .await;
        job.run_once().await;
    }
}

// ─── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn v(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn schedule_parses_hh_mm() {
        assert_eq!(parse_schedule("03:15"), Some((3, 15)));
        assert_eq!(parse_schedule(" 23:59 "), Some((23, 59)));
        assert_eq!(parse_schedule("0:00"), Some((0, 0)));
        assert_eq!(parse_schedule("24:00"), None);
        assert_eq!(parse_schedule("12:60"), None);
        assert_eq!(parse_schedule("nonsense"), None);
        assert_eq!(parse_schedule(""), None);
    }

    #[test]
    fn schedule_tolerates_legacy_sidecar_values() {
        // Operators' .env files may still carry the old sidecar syntax.
        assert_eq!(
            parse_schedule("@daily"),
            Some((DEFAULT_HOUR, DEFAULT_MINUTE))
        );
        assert_eq!(parse_schedule("15 3 * * *"), Some((3, 15)));
        assert_eq!(parse_schedule("0 4 * * *"), Some((4, 0)));
        // Non-daily cron shapes are NOT silently reinterpreted.
        assert_eq!(parse_schedule("15 3 * * 1"), None);
        assert_eq!(parse_schedule("*/5 * * * *"), None);
    }

    #[test]
    fn dump_key_matches_only_our_names() {
        // Our daily / weekly / monthly names.
        assert_eq!(
            parse_dump_key("crumb-20260703-031500.sql.gz", "crumb"),
            Some("20260703-031500")
        );
        assert_eq!(
            parse_dump_key("crumb-202627.sql.gz", "crumb"),
            Some("202627")
        );
        assert_eq!(
            parse_dump_key("crumb-202607.sql.gz", "crumb"),
            Some("202607")
        );
        // The -latest symlink name is NOT a rotatable dump.
        assert_eq!(parse_dump_key("crumb-latest.sql.gz", "crumb"), None);
        // scripts/backup-db.sh manual dumps (crumb-<db>-<ts>) are sacred.
        assert_eq!(
            parse_dump_key("crumb-crumb-20260615-031500.sql.gz", "crumb"),
            None
        );
        // Wrong db prefix, stray files, partials — all skipped.
        assert_eq!(
            parse_dump_key("other-20260703-031500.sql.gz", "crumb"),
            None
        );
        assert_eq!(parse_dump_key("notes.txt", "crumb"), None);
        assert_eq!(
            parse_dump_key("crumb-20260703-031500.sql.gz.partial", "crumb"),
            None
        );
    }

    #[test]
    fn rotation_keeps_newest_n_daily() {
        let names = v(&[
            "crumb-20260625-031500.sql.gz",
            "crumb-20260627-031500.sql.gz",
            "crumb-20260626-031500.sql.gz",
            "crumb-20260628-031500.sql.gz",
        ]);
        let del = rotation_deletions(&names, "crumb", 2);
        assert_eq!(
            del,
            v(&[
                "crumb-20260625-031500.sql.gz",
                "crumb-20260626-031500.sql.gz"
            ])
        );
    }

    #[test]
    fn rotation_never_deletes_newest_even_with_keep_zero() {
        let names = v(&[
            "crumb-20260627-031500.sql.gz",
            "crumb-20260628-031500.sql.gz",
        ]);
        // keep=0 clamps to 1: the newest survives, only the older goes.
        let del = rotation_deletions(&names, "crumb", 0);
        assert_eq!(del, v(&["crumb-20260627-031500.sql.gz"]));
        // A single dump is never deleted regardless of keep.
        let one = v(&["crumb-20260628-031500.sql.gz"]);
        assert!(rotation_deletions(&one, "crumb", 0).is_empty());
    }

    #[test]
    fn rotation_skips_manual_dumps_and_latest_symlink() {
        let names = v(&[
            "crumb-20260620-031500.sql.gz",
            "crumb-20260628-031500.sql.gz",
            "crumb-latest.sql.gz",                // symlink name
            "crumb-crumb-20260101-000000.sql.gz", // scripts/backup-db.sh manual dump
            "precious-operator-snapshot.sql.gz",  // arbitrary manual file
        ]);
        let del = rotation_deletions(&names, "crumb", 1);
        // Only OUR older daily dump is deletable; everything else is sacred.
        assert_eq!(del, v(&["crumb-20260620-031500.sql.gz"]));
    }

    #[test]
    fn rotation_no_deletions_when_under_budget() {
        let names = v(&[
            "crumb-20260627-031500.sql.gz",
            "crumb-20260628-031500.sql.gz",
        ]);
        assert!(rotation_deletions(&names, "crumb", 7).is_empty());
        assert!(rotation_deletions(&[], "crumb", 7).is_empty());
    }

    #[test]
    fn rotation_weekly_iso_keys() {
        let names = v(&[
            "crumb-202624.sql.gz",
            "crumb-202627.sql.gz",
            "crumb-202625.sql.gz",
            "crumb-202626.sql.gz",
            "crumb-202623.sql.gz",
        ]);
        let del = rotation_deletions(&names, "crumb", 4);
        assert_eq!(del, v(&["crumb-202623.sql.gz"]));
    }

    #[test]
    fn boot_catchup_decision() {
        assert!(needs_boot_dump(None), "no dumps at all -> dump on boot");
        assert!(
            needs_boot_dump(Some(BOOT_CATCHUP_SECS + 1)),
            "stale dump -> dump on boot"
        );
        assert!(
            !needs_boot_dump(Some(3_600)),
            "fresh dump -> no boot catch-up"
        );
        assert!(
            !needs_boot_dump(Some(BOOT_CATCHUP_SECS)),
            "exactly at threshold -> not yet (strict >)"
        );
    }

    #[test]
    fn next_run_same_day_and_rollover() {
        let tz = Tz::America__Los_Angeles;
        // 2026-07-03 01:00 PDT (= 08:00 UTC): 03:15 local is still ahead today.
        let now = Utc.with_ymd_and_hms(2026, 7, 3, 8, 0, 0).unwrap();
        let next = next_run_after(now, 3, 15, tz);
        assert_eq!(next, Utc.with_ymd_and_hms(2026, 7, 3, 10, 15, 0).unwrap());
        // 2026-07-03 04:00 PDT (= 11:00 UTC): 03:15 already passed -> tomorrow.
        let now = Utc.with_ymd_and_hms(2026, 7, 3, 11, 0, 0).unwrap();
        let next = next_run_after(now, 3, 15, tz);
        assert_eq!(next, Utc.with_ymd_and_hms(2026, 7, 4, 10, 15, 0).unwrap());
        // Exactly at the boundary -> strictly after, so tomorrow.
        let now = Utc.with_ymd_and_hms(2026, 7, 3, 10, 15, 0).unwrap();
        let next = next_run_after(now, 3, 15, tz);
        assert_eq!(next, Utc.with_ymd_and_hms(2026, 7, 4, 10, 15, 0).unwrap());
    }

    #[test]
    fn next_run_handles_dst_spring_forward_gap() {
        let tz = Tz::America__Los_Angeles;
        // 2026-03-08: 02:00–03:00 PST doesn't exist (spring forward). A 02:30
        // schedule must skip to the next day instead of looping/panicking.
        let now = Utc.with_ymd_and_hms(2026, 3, 8, 8, 0, 0).unwrap(); // 00:00 PST
        let next = next_run_after(now, 2, 30, tz);
        // Next valid 02:30 local is Mar 9 PDT (= 09:30 UTC).
        assert_eq!(next, Utc.with_ymd_and_hms(2026, 3, 9, 9, 30, 0).unwrap());
    }

    #[test]
    fn db_name_parsing() {
        assert_eq!(
            db_name_from_url("postgres://crumb:secret@postgres:5432/crumb"),
            "crumb"
        );
        assert_eq!(db_name_from_url("postgres://u:p@h:5/customdb"), "customdb");
        assert_eq!(db_name_from_url("not a url"), "crumb");
    }

    #[test]
    fn stderr_scrubbing_never_leaks_secrets() {
        let url = "postgres://crumb:s3cr3tpw@postgres:5432/crumb";
        let scrubbed = scrub_secrets(
            "connection to \"postgres://crumb:s3cr3tpw@postgres:5432/crumb\" failed: password \"s3cr3tpw\" rejected",
            url,
        );
        assert!(!scrubbed.contains("s3cr3tpw"));
        assert!(scrubbed.contains("<database-url>"));
        assert!(scrubbed.contains("<redacted>"));
    }
}
