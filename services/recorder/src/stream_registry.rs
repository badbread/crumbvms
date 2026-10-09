// SPDX-License-Identifier: AGPL-3.0-or-later

//! Recording streams the recorder registers in its OWN embedded go2rtc (R10).
//!
//! go2rtc keeps its streams in memory only (its config is mounted read-only and
//! lists none), and the api's reconcile loop (`services/api/src/go2rtc.rs`) used
//! to be their only writer. So any go2rtc or recorder restart while the api was
//! down, crash-looping or still booting left go2rtc with zero streams, and every
//! Crumb-served camera stopped recording until the api came back.
//!
//! When go2rtc is embedded (this process spawned it, see `go2rtc_embed.rs`),
//! the recorder now makes sure each camera's recording streams (main and
//! `<name>_sub`, built by `crumb_common::go2rtc_streams`, the same builder the
//! api uses, so the definitions are byte-identical) EXIST:
//!
//! * once before the camera workers start, bounded by [`STARTUP_WAIT`] so a
//!   go2rtc that never answers cannot hold recording startup hostage;
//! * then every [`CHECK_INTERVAL`] while the recorder runs, which covers a
//!   go2rtc child crash and respawn.
//!
//! # It never fights the api
//!
//! This is a create-if-missing fallback, nothing more:
//!
//! * It only ever `PUT`s a name go2rtc does NOT have. An existing stream is
//!   never re-`PUT` (that would replace the live object and orphan its
//!   consumers) and never `PATCH`ed: source edits, the derived client streams
//!   (`_subv`, `_mainv`, `_mobile`), rejection alerts and removals all stay with
//!   the api.
//! * A name must be missing on two reads [`CONFIRM_DELAY`] apart (and the camera
//!   rows are re-read in between), so while the api is healthy it nearly always
//!   wins the race: its reconcile notices a short go2rtc within ~5 s, and its
//!   source-edit path re-creates a stream within a few hundred ms of deleting
//!   it. If both do create the same name, they send the same definition.
//! * It never deletes anything it did not create in the same pass. The single
//!   exception guards the api's camera-delete path: if a stream this pass just
//!   created no longer matches any camera row on a re-read, it is removed again
//!   so a deleted camera's stream is not resurrected.
//!
//! `GO2RTC_EMBEDDED=false` (an external restreamer) means this never runs: the
//! recorder has no business writing to someone else's go2rtc.

use std::collections::HashSet;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use crumb_common::db::CameraStream;
use crumb_common::go2rtc_streams::{recording_streams, StreamSpec};
use deadpool_postgres::Pool;
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

/// The embedded go2rtc's REST API, as seen from inside the recorder (go2rtc
/// listens on `:1984` per `go2rtc/go2rtc.yaml`; the port is never published).
const LOCAL_API_BASE: &str = "http://127.0.0.1:1984";

/// How often the running recorder checks for missing recording streams.
const CHECK_INTERVAL: Duration = Duration::from_secs(5);

/// A stream must still be missing this long after first seen missing before the
/// recorder creates it (see the module doc: gives the api the first chance).
const CONFIRM_DELAY: Duration = Duration::from_secs(2);

/// Longest the startup pass waits for the freshly spawned go2rtc to answer.
const STARTUP_WAIT: Duration = Duration::from_secs(10);

/// Per-request timeout against the local go2rtc.
const HTTP_TIMEOUT: Duration = Duration::from_secs(5);

/// go2rtc's stream table, as far as this module needs it.
pub(crate) trait StreamTable {
    /// Names of every stream go2rtc currently has.
    async fn names(&self) -> Result<HashSet<String>>;
    /// Create `spec` (only ever called for a name that was missing).
    async fn create(&self, spec: &StreamSpec) -> Result<()>;
    /// Remove `name` (only ever called for a stream this pass created).
    async fn delete(&self, name: &str) -> Result<()>;
}

/// Where the wanted recording streams come from (the `cameras` table).
pub(crate) trait DesiredStreams {
    async fn desired(&self) -> Result<Vec<StreamSpec>>;
}

/// Every recording stream for these camera rows, in the api's order.
pub(crate) fn desired_specs(rows: &[CameraStream]) -> Vec<StreamSpec> {
    rows.iter()
        .flat_map(|r| recording_streams(r).into_specs())
        .collect()
}

/// What one [`ensure_once`] pass did. Names only, never sources (a source can
/// carry camera credentials).
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct EnsureOutcome {
    /// Streams this pass created.
    pub created: Vec<String>,
    /// Streams this pass created and then removed again because their camera
    /// row was gone on the re-read.
    pub pruned: Vec<String>,
    /// Streams this pass tried to create but go2rtc did not accept (the api's
    /// reconcile reports the reason to the operator).
    pub failed: Vec<String>,
}

/// One create-if-missing pass. See the module doc for the rules; `confirm` is
/// [`CONFIRM_DELAY`] in production and zero in tests and at startup.
pub(crate) async fn ensure_once<T: StreamTable, D: DesiredStreams>(
    table: &T,
    desired: &D,
    confirm: Duration,
) -> Result<EnsureOutcome> {
    let mut out = EnsureOutcome::default();

    let first_seen = table.names().await?;
    let first_missing: HashSet<String> = desired
        .desired()
        .await?
        .into_iter()
        .map(|s| s.name)
        .filter(|n| !first_seen.contains(n))
        .collect();
    if first_missing.is_empty() {
        return Ok(out);
    }

    if !confirm.is_zero() {
        tokio::time::sleep(confirm).await;
    }

    // Re-read go2rtc first, then the rows, then create straight away: the rows
    // are as fresh as possible when the PUT lands.
    let seen = table.names().await?;
    let wanted = desired.desired().await?;
    for spec in &wanted {
        if seen.contains(&spec.name) || !first_missing.contains(&spec.name) {
            continue;
        }
        match table.create(spec).await {
            Ok(()) => out.created.push(spec.name.clone()),
            Err(e) => {
                debug!(stream = %spec.name, error = %format!("{e:#}"), "go2rtc stream create failed");
                out.failed.push(spec.name.clone());
            }
        }
    }

    if !out.created.is_empty() {
        // A camera deleted between our read and our PUT must not get its
        // stream back (the api's delete path removes it once, it does not
        // re-check). Only names this pass created are candidates.
        let still: HashSet<String> = desired
            .desired()
            .await?
            .into_iter()
            .map(|s| s.name)
            .collect();
        for name in out.created.clone() {
            if still.contains(&name) {
                continue;
            }
            if table.delete(&name).await.is_ok() {
                out.created.retain(|n| n != &name);
                out.pruned.push(name);
            }
        }
    }
    Ok(out)
}

/// [`DesiredStreams`] backed by the `cameras` table.
struct DbDesired<'a>(&'a Pool);

impl DesiredStreams for DbDesired<'_> {
    async fn desired(&self) -> Result<Vec<StreamSpec>> {
        let rows = crumb_common::db::list_camera_streams(self.0).await?;
        Ok(desired_specs(&rows))
    }
}

/// [`StreamTable`] backed by the embedded go2rtc's REST API.
struct LocalGo2rtc {
    client: reqwest::Client,
    base: String,
    user: String,
    pass: String,
}

impl LocalGo2rtc {
    fn new(user: String, pass: String) -> Result<Self> {
        let client = reqwest::Client::builder()
            .timeout(HTTP_TIMEOUT)
            // Loopback only: never route this through an operator's proxy.
            .no_proxy()
            .build()
            .context("build local go2rtc client")?;
        Ok(Self {
            client,
            base: LOCAL_API_BASE.to_owned(),
            user,
            pass,
        })
    }

    fn url(&self) -> String {
        format!("{}/api/streams", self.base)
    }
}

/// Error text for a failed request WITHOUT its URL: the query string of a
/// create carries the camera source, which can embed credentials.
fn req_err(what: &str, e: reqwest::Error) -> anyhow::Error {
    anyhow!("{what}: {}", e.without_url())
}

impl StreamTable for LocalGo2rtc {
    async fn names(&self) -> Result<HashSet<String>> {
        let resp = self
            .client
            .get(self.url())
            .basic_auth(&self.user, Some(&self.pass))
            .send()
            .await
            .map_err(|e| req_err("GET go2rtc streams", e))?;
        if !resp.status().is_success() {
            anyhow::bail!("go2rtc GET /api/streams -> HTTP {}", resp.status());
        }
        let body: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| req_err("parse go2rtc streams", e))?;
        match body {
            serde_json::Value::Object(map) => Ok(map.keys().cloned().collect()),
            serde_json::Value::Null => Ok(HashSet::new()),
            _ => anyhow::bail!("go2rtc /api/streams did not return a JSON object"),
        }
    }

    async fn create(&self, spec: &StreamSpec) -> Result<()> {
        let resp = self
            .client
            .put(self.url())
            .basic_auth(&self.user, Some(&self.pass))
            .query(&[("name", spec.name.as_str()), ("src", spec.src.as_str())])
            .send()
            .await
            .map_err(|e| req_err("PUT go2rtc stream", e))?;
        let status = resp.status();
        if status.is_success() {
            return Ok(());
        }
        // go2rtc answers 4xx both when it registered the stream anyway (its
        // read-only config write failed, or the first source probe failed) and
        // when it refused the source; ask it which (same rule as the api).
        if status.is_client_error() && self.names().await?.contains(&spec.name) {
            return Ok(());
        }
        anyhow::bail!("go2rtc PUT {} -> HTTP {status}", spec.name)
    }

    async fn delete(&self, name: &str) -> Result<()> {
        let resp = self
            .client
            .delete(self.url())
            .basic_auth(&self.user, Some(&self.pass))
            .query(&[("src", name)])
            .send()
            .await
            .map_err(|e| req_err("DELETE go2rtc stream", e))?;
        if resp.status().is_server_error() {
            anyhow::bail!("go2rtc DELETE {name} -> HTTP {}", resp.status());
        }
        Ok(())
    }
}

/// Log a pass's outcome. `warned` keeps a rejected source from logging a warn
/// every [`CHECK_INTERVAL`]: it warns once per name until that name succeeds.
fn log_outcome(out: &EnsureOutcome, warned: &mut HashSet<String>) {
    if !out.created.is_empty() {
        info!(
            streams = ?out.created,
            "registered recording streams missing from the embedded go2rtc \
             (the api normally does this; it may be down or still starting)"
        );
    }
    if !out.pruned.is_empty() {
        info!(streams = ?out.pruned, "removed just-registered streams whose camera was deleted");
    }
    for name in &out.created {
        warned.remove(name);
    }
    for name in &out.failed {
        if warned.insert(name.clone()) {
            warn!(
                stream = %name,
                "embedded go2rtc did not accept a recording stream; that camera cannot \
                 record until its source is fixed (the api reports the reason)"
            );
        }
    }
}

/// Start the recording-stream registry. Returns `None`, touching nothing, unless
/// this process is running the embedded go2rtc (`embedded_running` is whether
/// `go2rtc_embed::spawn` started it; `GO2RTC_EMBEDDED=false` or a missing
/// binary means it did not).
///
/// Runs the bounded startup pass before returning, so call it before the camera
/// workers start; then spawns the periodic loop.
pub(crate) async fn start(
    embedded_running: bool,
    pool: Pool,
    go2rtc_user: String,
    go2rtc_pass: String,
    shutdown: CancellationToken,
) -> Option<tokio::task::JoinHandle<()>> {
    if !embedded_running {
        return None;
    }
    let table = match LocalGo2rtc::new(go2rtc_user, go2rtc_pass) {
        Ok(t) => t,
        Err(e) => {
            warn!(error = %format!("{e:#}"), "go2rtc stream registry disabled: cannot build HTTP client");
            return None;
        }
    };
    let mut warned = HashSet::new();

    // Startup: wait (bounded) for the freshly spawned go2rtc to answer, then
    // create whatever is missing with no confirm delay. Nothing is attached to
    // a just-spawned go2rtc yet, and a simultaneous api PUT sends the same
    // definition, so there is nothing to give way to.
    let deadline = tokio::time::Instant::now() + STARTUP_WAIT;
    loop {
        match ensure_once(&table, &DbDesired(&pool), Duration::ZERO).await {
            Ok(out) => {
                log_outcome(&out, &mut warned);
                break;
            }
            Err(e) if tokio::time::Instant::now() >= deadline => {
                warn!(
                    error = %format!("{e:#}"),
                    "embedded go2rtc not ready at startup; recording starts anyway and \
                     streams will be registered once it answers"
                );
                break;
            }
            Err(_) => {}
        }
        tokio::select! {
            () = tokio::time::sleep(Duration::from_millis(500)) => {}
            () = shutdown.cancelled() => return None,
        }
    }

    Some(tokio::spawn(async move {
        let desired = DbDesired(&pool);
        loop {
            tokio::select! {
                () = tokio::time::sleep(CHECK_INTERVAL) => {}
                () = shutdown.cancelled() => return,
            }
            let pass = ensure_once(&table, &desired, CONFIRM_DELAY);
            tokio::select! {
                r = pass => match r {
                    Ok(out) => log_outcome(&out, &mut warned),
                    // go2rtc mid-restart or the DB briefly unreachable: retry
                    // next tick. The go2rtc supervisor logs its own restarts.
                    Err(e) => debug!(error = %format!("{e:#}"), "go2rtc stream check failed (will retry)"),
                },
                () = shutdown.cancelled() => return,
            }
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{BTreeMap, VecDeque};
    use std::sync::Mutex;

    fn spec(name: &str, src: &str) -> StreamSpec {
        StreamSpec {
            name: name.to_owned(),
            src: src.to_owned(),
        }
    }

    /// In-memory go2rtc. `appear_on_recheck` streams are inserted (as if by the
    /// api) right after the FIRST `names()` call, to model the api winning.
    #[derive(Default)]
    struct FakeTable {
        streams: Mutex<BTreeMap<String, String>>,
        appear_on_recheck: Mutex<Vec<(String, String)>>,
        reject: HashSet<String>,
        names_fails: bool,
        creates: Mutex<Vec<String>>,
        deletes: Mutex<Vec<String>>,
    }

    impl FakeTable {
        fn with(streams: &[(&str, &str)]) -> Self {
            let t = Self::default();
            for (n, s) in streams {
                t.streams.lock().unwrap().insert((*n).into(), (*s).into());
            }
            t
        }
        fn snapshot(&self) -> BTreeMap<String, String> {
            self.streams.lock().unwrap().clone()
        }
    }

    impl StreamTable for FakeTable {
        async fn names(&self) -> Result<HashSet<String>> {
            if self.names_fails {
                anyhow::bail!("go2rtc unreachable");
            }
            let names = self.streams.lock().unwrap().keys().cloned().collect();
            for (n, s) in self.appear_on_recheck.lock().unwrap().drain(..) {
                self.streams.lock().unwrap().insert(n, s);
            }
            Ok(names)
        }
        async fn create(&self, spec: &StreamSpec) -> Result<()> {
            self.creates.lock().unwrap().push(spec.name.clone());
            if self.reject.contains(&spec.name) {
                anyhow::bail!("rejected");
            }
            self.streams
                .lock()
                .unwrap()
                .insert(spec.name.clone(), spec.src.clone());
            Ok(())
        }
        async fn delete(&self, name: &str) -> Result<()> {
            self.deletes.lock().unwrap().push(name.to_owned());
            self.streams.lock().unwrap().remove(name);
            Ok(())
        }
    }

    /// Camera rows over time: each `desired()` call pops the next answer; the
    /// last one repeats.
    struct FakeDesired(Mutex<VecDeque<Vec<StreamSpec>>>);

    impl FakeDesired {
        fn fixed(v: Vec<StreamSpec>) -> Self {
            Self(Mutex::new(VecDeque::from([v])))
        }
        fn seq(v: Vec<Vec<StreamSpec>>) -> Self {
            Self(Mutex::new(VecDeque::from(v)))
        }
    }

    impl DesiredStreams for FakeDesired {
        async fn desired(&self) -> Result<Vec<StreamSpec>> {
            let mut q = self.0.lock().unwrap();
            if q.len() > 1 {
                Ok(q.pop_front().unwrap())
            } else {
                Ok(q.front().cloned().unwrap_or_default())
            }
        }
    }

    fn two_cameras() -> Vec<StreamSpec> {
        vec![
            spec("driveway", "rtsp://192.0.2.10/main"),
            spec("driveway_sub", "rtsp://192.0.2.10/sub"),
            spec("porch", "rtsp://192.0.2.11/main"),
        ]
    }

    fn row(name: &str, main: &str, sub: Option<&str>) -> CameraStream {
        CameraStream {
            id: uuid::Uuid::nil(),
            name: name.to_owned(),
            go2rtc_name: name.to_owned(),
            source_url: main.to_owned(),
            source_sub_url: sub.map(str::to_owned),
        }
    }

    /// The SAME rows and literal definitions as the api's
    /// `recording_stream_definitions_match_the_recorder_golden_table`, so the
    /// recorder and the api provably register byte-identical streams.
    #[test]
    fn desired_specs_match_the_api_golden_table() {
        let rows = [
            row(
                "driveway",
                "rtsp://u:p%40ss@192.0.2.10:554/Streaming/Channels/101",
                Some("rtsp://u:p%40ss@192.0.2.10:554/Streaming/Channels/102"),
            ),
            row("porch", "rtsp://192.0.2.11/s0", Some("   ")),
            row("yard", "rtsp://192.0.2.12/main?x=1&y=2", None),
        ];
        let got: Vec<(String, String)> = desired_specs(&rows)
            .into_iter()
            .map(|s| (s.name, s.src))
            .collect();
        let want = [
            (
                "driveway",
                "rtsp://u:p%40ss@192.0.2.10:554/Streaming/Channels/101",
            ),
            (
                "driveway_sub",
                "rtsp://u:p%40ss@192.0.2.10:554/Streaming/Channels/102",
            ),
            ("porch", "rtsp://192.0.2.11/s0"),
            ("yard", "rtsp://192.0.2.12/main?x=1&y=2"),
        ]
        .map(|(n, s)| (n.to_owned(), s.to_owned()));
        assert_eq!(got, want);
    }

    #[tokio::test]
    async fn creates_missing_streams_then_is_idempotent() {
        let table = FakeTable::default();
        let desired = FakeDesired::fixed(two_cameras());

        let first = ensure_once(&table, &desired, Duration::ZERO).await.unwrap();
        assert_eq!(first.created, ["driveway", "driveway_sub", "porch"]);
        let after_first = table.snapshot();
        assert_eq!(after_first.len(), 3);

        for _ in 0..3 {
            let again = ensure_once(&table, &desired, Duration::ZERO).await.unwrap();
            assert_eq!(again, EnsureOutcome::default());
        }
        assert_eq!(table.snapshot(), after_first);
        assert_eq!(table.creates.lock().unwrap().len(), 3, "no re-PUT ever");
        assert!(table.deletes.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn never_touches_streams_go2rtc_already_has() {
        // `driveway` already exists with a DIFFERENT source (the api PATCHed it
        // after an edit the recorder has not read yet), plus an operator's
        // manual stream. Neither may be replaced or removed.
        let table = FakeTable::with(&[
            ("driveway", "rtsp://192.0.2.20/edited"),
            ("manual", "rtsp://192.0.2.30/x"),
        ]);
        let desired = FakeDesired::fixed(two_cameras());
        let out = ensure_once(&table, &desired, Duration::ZERO).await.unwrap();
        assert_eq!(out.created, ["driveway_sub", "porch"]);
        let snap = table.snapshot();
        assert_eq!(snap["driveway"], "rtsp://192.0.2.20/edited");
        assert_eq!(snap["manual"], "rtsp://192.0.2.30/x");
        assert!(table.deletes.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn gives_way_when_the_stream_appears_before_the_recheck() {
        // The api re-created `porch` between our two reads: we must not PUT it.
        let table = FakeTable::with(&[
            ("driveway", "rtsp://192.0.2.10/main"),
            ("driveway_sub", "rtsp://192.0.2.10/sub"),
        ]);
        table
            .appear_on_recheck
            .lock()
            .unwrap()
            .push(("porch".into(), "rtsp://192.0.2.11/main".into()));
        let desired = FakeDesired::fixed(two_cameras());
        let out = ensure_once(&table, &desired, Duration::ZERO).await.unwrap();
        assert_eq!(out, EnsureOutcome::default());
        assert!(table.creates.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_camera_deleted_mid_pass_does_not_keep_its_stream() {
        let table = FakeTable::default();
        let porch = vec![spec("porch", "rtsp://192.0.2.11/main")];
        // first read, recheck read: camera present; post-create read: gone.
        let desired = FakeDesired::seq(vec![porch.clone(), porch, vec![]]);
        let out = ensure_once(&table, &desired, Duration::ZERO).await.unwrap();
        assert!(out.created.is_empty());
        assert_eq!(out.pruned, ["porch"]);
        assert!(table.snapshot().is_empty());
    }

    #[tokio::test]
    async fn go2rtc_unreachable_creates_nothing() {
        let table = FakeTable {
            names_fails: true,
            ..FakeTable::default()
        };
        let desired = FakeDesired::fixed(two_cameras());
        assert!(ensure_once(&table, &desired, Duration::ZERO).await.is_err());
        assert!(table.creates.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn one_rejected_source_does_not_block_the_others() {
        let table = FakeTable {
            reject: HashSet::from(["driveway".to_owned()]),
            ..FakeTable::default()
        };
        let desired = FakeDesired::fixed(two_cameras());
        let out = ensure_once(&table, &desired, Duration::ZERO).await.unwrap();
        assert_eq!(out.created, ["driveway_sub", "porch"]);
        assert_eq!(out.failed, ["driveway"]);
    }

    #[test]
    fn a_rejected_stream_warns_once_until_it_succeeds() {
        let mut warned = HashSet::new();
        let failed = EnsureOutcome {
            failed: vec!["driveway".into()],
            ..EnsureOutcome::default()
        };
        log_outcome(&failed, &mut warned);
        assert!(warned.contains("driveway"));
        let ok = EnsureOutcome {
            created: vec!["driveway".into()],
            ..EnsureOutcome::default()
        };
        log_outcome(&ok, &mut warned);
        assert!(warned.is_empty());
    }

    #[tokio::test]
    async fn not_embedded_registers_nothing() {
        // GO2RTC_EMBEDDED=false (or no binary): `start` must return before it
        // builds a client or touches the DB. The pool points nowhere, so any DB
        // access would fail the test by hanging past the timeout or erroring.
        let pool = crumb_common::db::build_pool("postgres://u:p@192.0.2.1:1/none", 1).unwrap();
        let handle = tokio::time::timeout(
            Duration::from_secs(1),
            start(
                false,
                pool,
                "u".into(),
                "p".into(),
                CancellationToken::new(),
            ),
        )
        .await
        .expect("returns immediately");
        assert!(handle.is_none());
    }
}
