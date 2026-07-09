# Scrub-preview runtime tunables in the admin console (issue #10) — design plan

Status: **RATIFIED** — the maintainer confirmed decisions D1–D5 in §9 (all
recommended options accepted as-is). Implemented on `feat/scrub-pregen-tunables`.
Architect: Fable session 2026-07-09. Implementers: Sonnet agents per the task
breakdown in §8. Tracked under `docs/ROADMAP.md` initiative 8, Phase 1
follow-up item ("expose the runtime-safe tunables … in the admin console").

Issue #10 scope, verbatim anchors:

> Move the runtime tunables to `server_settings` with env fallback (admin
> value wins), following the existing precedence pattern (cf. `clip_preroll`).
> Consumers must read **live** from `server_settings`, not the startup
> `ApiConfig` snapshot: the pre-gen worker (`thumb_pregen.rs`) and the cache
> sweeper. … **Out of scope:** `THUMB_CACHE_DIR` stays env/compose-only.

The fresh precedent to mirror is the update-check work (#7 / PR #31):
`update_check_enabled` is a **nullable** `server_settings` column (migration
`0045_update_check.sql`), resolved by
`services/api/src/updates.rs::resolve_enabled` as
`db_value.unwrap_or(cfg.update_check_enabled)` — DB wins, `NULL` (never
touched) falls back to env. This plan applies exactly that shape to five
scrub knobs, plus the one thing update-check did not need: background
consumers that re-read the values **while running**.

---

## 1. Which knobs move, which stay env-only

Current env snapshot (all in `services/api/src/config.rs`, read once at boot
into the immutable `ApiConfig` held by `AppState`):

| Env key | `ApiConfig` field | Default | Boot clamp |
|---|---|---|---|
| `THUMB_PREGEN_ENABLED` | `thumb_pregen_enabled: bool` | `false` | — |
| `THUMB_PREGEN_LOOKBACK_HOURS` | `thumb_pregen_lookback_hours: i64` | `2` | `.max(0)` |
| `THUMB_PREGEN_SCAN_SECS` | `thumb_pregen_scan_secs: u64` | `60` | `.max(5)` |
| `THUMB_PREGEN_WIDTH` | `thumb_pregen_width: u32` | `480` | — (request path clamps 48..=640) |
| `THUMB_CACHE_MAX_BYTES` | `thumb_cache_max_bytes: u64` | `21_474_836_480` (20 GiB) | — |
| `THUMB_CACHE_TTL_SECONDS` | `thumb_cache_ttl_seconds: u64` | `2_592_000` (30 d) | — |
| `THUMB_CACHE_DIR` | `thumb_cache_dir: String` | `""` (= `EXPORT_DIR`) | — |

### Moves to `server_settings` (nullable columns, DB-wins/NULL→env)

| Column (matches env key, lowercased — same convention as `update_check_enabled`) | SQL type | Validation (server-side clamp in the db setter, mirroring `set_clip_pre_roll_seconds`) |
|---|---|---|
| `thumb_pregen_enabled` | `boolean` | — |
| `thumb_pregen_lookback_hours` | `integer` | clamp `0..=168` (a week; larger backfills belong in env where the operator has read the cost note) |
| `thumb_pregen_scan_secs` | `integer` | clamp `5..=3600` (5 s floor matches the existing env clamp) |
| `thumb_cache_max_bytes` | `bigint` | clamp `104_857_600..` (100 MiB floor — a 0/near-0 budget would make the sweeper delete every thumbnail every minute, silently defeating the feature) |
| `thumb_cache_ttl_seconds` | `bigint` | clamp `3600..=31_536_000` (1 h .. 1 y) |

### Stays env-only

- **`THUMB_CACHE_DIR`** — per issue #10, out of scope: it is a filesystem
  mount (compose volume), not a preference. Changing it live could not work
  anyway (the path must exist inside the container).
- **`THUMB_PREGEN_WIDTH`** — **RATIFIED env-only for v1** (D1). The admin
  console shows it read-only.
- **`THUMB_EXTRACT_MAX_CONCURRENCY`** — not in issue scope; it sizes a
  `Semaphore` created once in `AppState::new` (not live-reloadable without
  semaphore surgery). Explicitly deferred.

---

## 2. Migration 0046

`db/migrations/` currently ends at `0045_update_check.sql`, and the
`MIGRATIONS` array in `services/common/src/db.rs` (~line 7611) ends with the
same entry — **0046 is the next free number.**

**File:** `db/migrations/0046_scrub_pregen_settings.sql`

```sql
-- Admin-console overrides for the scrub-preview runtime tunables (issue #10).
-- NULL means "the operator has never touched this in the console" -> the
-- consumers fall back to the THUMB_* env defaults (services/api/src/config.rs).
-- Nullable + no DEFAULT, matching update_check_enabled (migration 0045):
-- NULL must be distinguishable from an explicit value, per the house
-- server_settings precedence rule (admin-set DB value wins over env).
--
-- Additive + nullable, so it is safe on an already-running install.
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS thumb_pregen_enabled        boolean,
    ADD COLUMN IF NOT EXISTS thumb_pregen_lookback_hours integer,
    ADD COLUMN IF NOT EXISTS thumb_pregen_scan_secs      integer,
    ADD COLUMN IF NOT EXISTS thumb_cache_max_bytes       bigint,
    ADD COLUMN IF NOT EXISTS thumb_cache_ttl_seconds     bigint;
```

**Registration (golden rule 4):** append the pair to the `MIGRATIONS` array in
`services/common/src/db.rs` — an unregistered file silently never runs.

**db.rs accessors** (in `services/common/src/db.rs`, next to
`get_update_check_enabled` / `set_update_check_enabled`):

- `get_scrub_pregen_settings(pool) -> Result<ScrubPregenOverrides>` — one
  `query_opt` of all five columns from the single `server_settings` row;
  returns a struct of `Option<T>`s (each `None` = never set → env fallback).
- One setter per field (`set_thumb_pregen_enabled`, …), each a single-column
  `UPDATE server_settings SET <col> = $1`, clamping per the table in §1
  before writing (same pattern as `set_clip_pre_roll_seconds`). Per-field
  setters — not one multi-column UPDATE — because the house rule is "console
  writes ONLY the field it edits", and the PUT handler (§5) forwards only the
  fields present in the request body.

---

## 3. THE CRUX — live-reload mechanism

### The problem

Both consumers currently read the boot-time `ApiConfig` snapshot:

- `services/api/src/thumb_pregen.rs::run` reads
  `enabled/width/lookback_hours/scan_secs` **once** before its loop and
  `return`s immediately when disabled (line 39-42) — so even a restart-free
  "enable" is impossible today, let alone a live change.
- The thumbnail cache sweeper is the tail of
  `export_ttl_sweeper` in `services/api/src/main.rs` (line ~803):
  `sweep_thumbs_cache(state.config().thumb_cache_base(), ttl, max_bytes)`
  with ttl/budget pulled from `state.config()` every 1-minute tick — already
  structurally "per tick", just from the frozen snapshot.

### Options evaluated

**(a) Re-query `server_settings` at the top of each consumer cycle.**
A single-row, single-`query_opt` SELECT per tick.
- DB load: worker = 1 query per `scan_secs` (default 60 s); sweeper = 1 query
  per minute. **~2 tiny queries/min total** against a pool that serves every
  API request — unmeasurable.
- Staleness: bounded by one tick (≤ 60 s at defaults), plus the mid-backfill
  re-check below.
- Complexity: one shared resolver function; no shared mutable state, no
  invalidation, no new `AppState` field. Mirrors the existing
  `updates.rs::resolve_enabled` call-per-use pattern exactly.

**(b) Shared cached-settings struct** (`AppState` field, TTL-refresh à la
`revoked_jtis`, or PUT-handler invalidation à la `roles_cache`).
- Saves DB load only where reads are hot-path. These reads are 1-2/min
  background loops — there is nothing to save.
- Costs: new `AppState` plumbing, an invalidation seam that can silently
  break (PUT handler forgets to invalidate → stale forever), and it still
  needs the TTL fallback for a second API replica sharing the DB.

**Chosen: (a), direct re-query per cycle (D2, ratified).** (b) is machinery
without a payoff at this read rate; the precedent (`resolve_enabled` queries
the DB on every `/updates/latest` request) already accepts far more query
traffic for the same freshness guarantee. Revisit trigger: a future hot-path
consumer (e.g. per-request settings reads) or measured pool pressure.

### The resolver

New module `services/api/src/scrub_settings.rs`:

```rust
/// Effective scrub-preview settings: admin-set server_settings values win,
/// NULL falls back to the THUMB_* env defaults (house precedence rule).
pub struct ScrubSettings {
    pub pregen_enabled: bool,
    pub pregen_lookback_hours: i64,
    pub pregen_scan_secs: u64,
    pub cache_max_bytes: u64,
    pub cache_ttl_seconds: u64,
    // width stays ApiConfig-only under D1 option A
}

pub async fn resolve(pool: &Pool, cfg: &ApiConfig) -> anyhow::Result<ScrubSettings>
```

`resolve` = `get_scrub_pregen_settings` + per-field `unwrap_or(cfg.…)` +
the same clamps as the setters (defense in depth against a hand-edited row).
**Failure policy:** consumers treat a resolve error as "keep last-known
values" (first iteration: env snapshot), log a `warn!`, and continue — a
transient DB blip must never kill the worker or the sweeper (both are
best-effort background loops; same ethos as `refresh_revoked_jtis`).

### Worker rework (`thumb_pregen.rs`)

The loop becomes settings-driven instead of snapshot-driven:

1. **Always loop** — never `return` on disabled. Each cycle starts with
   `scrub_settings::resolve(...)`; when `pregen_enabled` is false, sleep
   `scan_secs` and `continue` (an idle poll costs one SELECT/min). This is
   what makes a console "enable" take effect without a restart.
2. **Log transitions, not every idle tick**: one `info!` when the effective
   state flips (disabled→enabled with the effective knob values, and back).
   The current boot message ("disabled (THUMB_PREGEN_ENABLED unset)") becomes
   "disabled (env default / admin setting); will start if enabled in the
   admin console".
3. **Mid-backfill kill switch.** The initial backfill (lookback default 2 h =
   1,800 grid slots per camera at the 4-second grid) can run for minutes
   inside one "cycle". Re-check `pregen_enabled` (a fresh 1-row SELECT)
   **between cameras and every 256 slots** within a camera (piggybacking the
   existing `steps.is_multiple_of(64)` yield cadence at a 4× multiple); on
   false, abandon the pass immediately. Worst-case latency for "toggle off"
   is then a few in-flight extractions, not hours.
4. **Watermark semantics across a disable window:** on an enabled→disabled
   transition, **clear the per-camera watermark map.** Re-enabling then
   behaves exactly like a fresh start (backfill `lookback_hours` from now)
   instead of grinding through the entire disabled gap — the operator asked
   for pregen *now*, not a surprise multi-day backfill. (The on-demand path
   self-heals the gap if anyone scrubs it, as today.)
5. **Per-cycle values:** `lookback_hours` affects only the
   `unwrap_or(now_ms - lookback_ms)` default for newly-seen cameras — takes
   effect naturally. `scan_secs` is read fresh each cycle, so the *next*
   sleep uses the new value. `width` stays the boot `cfg.thumb_pregen_width`
   under D1 option A.

### Sweeper rework (`main.rs::export_ttl_sweeper`)

Minimal: at the top of each 1-minute tick, resolve once and pass
`cache_ttl_seconds` / `cache_max_bytes` into the existing
`sweep_thumbs_cache(...)` call instead of `state.config().…`. A lowered
budget is therefore enforced within ≤ 1 minute: `sweep_thumbs_cache` already
does a full recount + oldest-first eviction every pass, so no extra
invalidation is needed — the next pass simply evicts down to the new number.
(The clips-cache sweep and export TTL are untouched; only the two thumbnail
arguments change source.)

### Mid-run change matrix (what the operator observes)

| Change | Takes effect | Mechanism |
|---|---|---|
| Pregen off | seconds (≤ 256 slots / 1 camera of in-flight backfill) | mid-backfill re-check + per-cycle resolve |
| Pregen on | ≤ `scan_secs` (≤ 60 s default) | idle loop polls instead of exiting |
| Lookback ± | next newly-seen camera / next post-clear backfill | watermark default |
| Scan interval ± | next wake | sleep duration re-read per cycle |
| Cache budget lowered | ≤ 1 min | sweeper full recount per tick |
| TTL lowered | ≤ 1 min | same |

---

## 4. The WIDTH cache-coherence nuance (decision point D1 — RATIFIED: option A, env-only)

Facts that bound the decision:

- Width is **part of the cache key**:
  `{thumb_cache_base}/.thumbs/{camera}/{ts_ms}_w{width}.jpg`
  (`filmstrip.rs` line ~284). A mixed-width cache is therefore *structurally
  safe* — no file is ever wrong, corrupted, or served at the wrong size, and
  no invalidation is *required* on a width change. Stale-width files age out
  via the TTL sweeper.
- But the clients **pin their requested width**: `THUMB_PREGEN_WIDTH` was
  raised from 160 to 480 specifically to equal the clients' scrub-still
  width (`config.rs` doc comment: "Kept equal to the playback clients' scrub
  width … so the wall and single-camera scrub preview hit the pre-generated
  cache"). A pregen width ≠ client width means every pregenerated file is a
  key nobody ever requests: **100% of pregen CPU + storage becomes silent
  waste**, while scrubbing quietly degrades to on-demand extraction. Nothing
  breaks loudly; the feature just stops paying for itself.
- Changing width also does not retro-generate: watermarks track *time*, so
  history stays at the old width and only new slots use the new one.

**RATIFIED (Option A): `THUMB_PREGEN_WIDTH` stays env-only in v1.**
A console knob whose wrong value silently defeats the feature it sits next
to is a foot-gun, and the legitimate use cases (shrink pregen storage on a
tiny box; a future client with a different tile size) are exactly the
"read the doc comment first" cases env config is for. The admin console
*displays* the effective width read-only ("Preview width: 480 px, set
via `THUMB_PREGEN_WIDTH`") so the operator sees the whole picture.

(Option B — a sixth nullable `thumb_pregen_width` column, exposed with a
warning — was considered and rejected; see `docs/DECISIONS.md`.)

---

## 5. HTTP surface

One grouped admin-only endpoint (COMPONENT-MAP row A applies), added to the
router in `services/api/src/config_routes.rs` next to
`/config/update-check-enabled`:

```
GET /config/scrub-preview   (AdminUser)
PUT /config/scrub-preview   (AdminUser)
```

Grouped rather than five single-field routes (the update-check precedent is
single-field, but it is a single field; five knobs in one panel warrant one
round-trip). The doc-comment route table at the top of `config_routes.rs` —
currently the API reference of record per COMPONENT-MAP row A — gains both
rows.

**GET response** — effective values plus provenance, so the console can
annotate "(env default)" vs "(set here)", plus the bounds so the UI clamps
match the server:

```json
{
  "pregen_enabled":       { "value": false,        "source": "env" },
  "pregen_lookback_hours":{ "value": 2,            "source": "env", "min": 0,         "max": 168 },
  "pregen_scan_secs":     { "value": 60,           "source": "db",  "min": 5,         "max": 3600 },
  "cache_max_bytes":      { "value": 21474836480,  "source": "env", "min": 104857600 },
  "cache_ttl_seconds":    { "value": 2592000,      "source": "db",  "min": 3600,      "max": 31536000 },
  "pregen_width":         { "value": 480,          "source": "env-only" }
}
```

**PUT request** — all fields `Option<…>`; the handler calls the per-field
db setter **only for fields present** (house rule: write only what was
edited). Values outside bounds are clamped by the setter (the
`clip_preroll` precedent clamps rather than rejects; the UI clamps first so
this is belt-and-braces). Response `204 No Content`.

**Deliberately deferred (D4, ratified):** "clear back to env default"
(writing SQL `NULL` via JSON `null`) — plain serde cannot distinguish absent
from `null` without a double-`Option` helper, and update-check shipped
without a clear either. Once touched, the DB value wins for good; revisit if
operators ask.

Security posture (golden rule 1): `AdminUser` extractor, JSON router side
(gzip + timeout + rate limit), no new ports/binds, no secrets involved.

---

## 6. Admin console (`services/api/src/admin.html`)

New "Scrub previews" card in the server-settings section, adjacent to the
clip pre-roll / bookmarks / update-check controls (same visual family).
House conventions checklist (from AGENTS.md + COMPONENT-MAP row H):

- Plain functions wired by `on*=` attributes; **every referenced handler
  must exist**: `loadScrubPreview()`, `saveScrubPreview(field, value)`
  (or per-control `saveScrubEnabled(checked)` etc. — implementer's choice,
  the constraint is defined-before-referenced).
- `api('/config/scrub-preview')` for reads; `api(..., { method:'PUT',
  body: JSON.stringify({ <only the edited field> }) })` for writes —
  one field per PUT, matching "console writes ONLY this field".
- On save failure: message in `var(--danger)` + re-`load…()` to revert the
  control to server truth (the `saveBookmarksEnabled` pattern, admin.html
  ~line 5929); on success `var(--ok)` message auto-cleared after 3 s.
- `esc()` for any interpolated text.
- Controls: pregen checkbox; lookback `number` input (0–168 h); scan-interval
  `number` (5–3600 s, labelled "advanced"); cache budget presented in **GiB**
  (converted to bytes for the API, min 0.1); TTL presented in **days**
  (converted to seconds, min 1 h). Each control shows the `source`
  annotation from GET ("env default" in `var(--dim)` until first save).
- Read-only line for width per §4 option A.
- Copy must state the cost honestly, mirroring the config.rs doc comment:
  pregen trades continuous decode CPU + cache storage for instant
  first-touch scrubbing.
- Verify: `node --check` on the extracted script block; rebuild the api to
  see changes (`include_str!`).

Not added to the first-run wizard: pregen is a deliberate opt-in with an
ongoing CPU cost, not an onboarding decision (COMPONENT-MAP row B "if the
setting belongs in onboarding" — it does not; stated here as the explicit
deferral the map requires).

---

## 7. Docs, COMPONENT-MAP walk, DECISIONS entry

### COMPONENT-MAP row B (server setting) + row A (endpoint) walk

| Surface | Action |
|---|---|
| `services/api/src/config.rs` | Doc comments on the five fields gain "admin-console override: `server_settings.<col>` wins when set (issue #10)" — the code-side truth stays honest |
| `.env.example` / `scripts/setup-env.sh` / `docker-compose*.yml` | **No change needed — verified**: the `THUMB_*` keys are not present in any of them today (they are optional tuning keys documented only in the environment reference). State this in the PR |
| `services/api/src/admin.html` | §6 |
| First-run wizard | Explicitly deferred (§6) |
| `docs/AI-INSTALL.md` | **No step changes** (no new required key, port, volume, or secret). Add is NOT required; if the runbook's scrubbing mention exists it gets one line: runtime tunables are console-editable post-install. Implementer verifies with a grep |
| `docs-site/docs/configuration/environment-reference.md` | Mark the five keys "console-editable (admin console › Scrub previews); the env value is the default until set there, then the console value wins". Mark `THUMB_CACHE_DIR` (+ `THUMB_PREGEN_WIDTH` under D1-A) "env-only". **Fix the stale `THUMB_PREGEN_WIDTH` default: the table says `160`, the code default is `480`** (config.rs line ~357) |
| `docs-site/docs/playback/scrubbing.md` | New short operator section: enabling/tuning pre-generation from the console, no restart needed; user-facing per the docs rule (plain language, what it costs, what changes when) |
| `docs/ROADMAP.md` initiative 8 | Tick the follow-up checkbox when shipped |
| `config_routes.rs` doc-comment route table | Two new rows (row A: the reference of record until OpenAPI exists) |
| Desktop / Android / iOS | No client work: clients consume `/filmstrip` unchanged. Desktop's embedded `/admin` picks the new card up for free |

### Required `docs/DECISIONS.md` entry (same change as the implementation)

`## 2026-07-XX, Scrub-preview tunables: per-tick server_settings re-query;
width stays env-only` — recording:

- **Chosen:** nullable `server_settings` columns (DB wins, NULL→env, the
  0045 pattern); consumers re-resolve from the DB once per cycle plus a
  mid-backfill enabled re-check; watermarks cleared on disable.
- **Rejected:** shared cached-settings struct with TTL/invalidation (no
  hot-path reader to justify it; invalidation is a new failure seam);
  config-file reload/SIGHUP (no precedent in Crumb, DB is the settings
  plane); forced cache regeneration on width change (can't safely delete
  mid-serve; mixed-width keys are already coherent).
- **Width decision** per D1 outcome, with the "pregen width must equal
  client scrub width or pregen is silent waste" reasoning.
- **Revisit triggers:** a hot-path consumer of these settings appears
  (→ option b caching); a client ships a different scrub width (→ expose
  width + per-client negotiation); operators request "reset to env default"
  (→ double-Option clear support); multi-replica API deployments make
  per-tick staleness visible.

---

## 8. Phased task breakdown (Sonnet-sized; gate green per task)

**Gate for every task** (AGENTS golden rule 3): `cargo fmt --all -- --check`
&& `cargo clippy --all-targets -- -D warnings` && `cargo test --workspace`
against the throwaway Postgres (`crumb-test-pg` recipe in AGENTS.md).
Branch: single feature branch for #10; one reviewable commit per task is
fine. DCO sign-off on every commit.

**Sequencing constraint (do first):** issue **#9** (coverage-aware
`list_thumbnail_times`, ~2-3% gap-slot 404s) also edits `thumb_pregen.rs`
and `services/common/src/db.rs`. **Land #9 first and rebase this branch on
it** before starting T3 — both touch the worker loop body, and #9 is the
smaller, independent change. T1/T2 may proceed in parallel with #9 (they
touch disjoint code), but T3 must start from the post-#9 tree.

(#9 merged 2026-07-09 as PR #38 — this branch is based on that merge commit.)

| # | Task | Files | Acceptance | Model |
|---|---|---|---|---|
| T1 | Migration 0046 + db accessors: SQL file, `MIGRATIONS` registration, `ScrubPregenOverrides` struct, `get_scrub_pregen_settings`, five clamping setters | `db/migrations/0046_scrub_pregen_settings.sql`, `services/common/src/db.rs` | Migration listed in `MIGRATIONS` (rule 4); integration tests: fresh-DB columns exist; get→all-`None`; set/get roundtrip per field; out-of-bounds input stored clamped | Sonnet |
| T2 | Resolver: `scrub_settings.rs` with `ScrubSettings` + `resolve(pool, cfg)` (unwrap_or env, re-clamp, documented failure policy) | `services/api/src/scrub_settings.rs`, `mod` in `main.rs` | Tests: NULL→env fallback per field; DB-set wins; hand-edited out-of-bounds row comes back clamped | Sonnet |
| T3 | Worker live-reload per §3: always-loop, per-cycle resolve, transition logging, 256-slot/per-camera enabled re-check, watermark clear on disable, resolve-failure = keep-last + warn | `services/api/src/thumb_pregen.rs` | **Starts after #9 is merged/rebased.** Extract the per-cycle decision logic into pure helper(s) with unit tests (enable/disable transitions, watermark clearing); manual smoke: toggle via SQL on a dev stack, observe start/stop in logs within one interval | Sonnet (high effort — the one task touching worker control flow) |
| T4 | Sweeper live values: resolve at tick top, feed `sweep_thumbs_cache` ttl/budget | `services/api/src/main.rs` (`export_ttl_sweeper`) | Existing `thumb_sweep_tests` still green (function signature unchanged); clips sweep + export TTL untouched | Sonnet |
| T5 | Endpoint: GET/PUT `/config/scrub-preview` per §5, DTOs, router wiring, route-table doc comment | `services/api/src/config_routes.rs` (+ `dto.rs` if house style puts DTOs there — mirror update-check placement) | Admin-only (auth test); GET reflects env then DB after PUT; PUT with one field leaves others untouched; PUT clamps | Sonnet |
| T6 | Admin console card per §6 | `services/api/src/admin.html` | `node --check` on extracted script; every `on*=` handler exists; save-failure revert path; source annotations; verified against a rebuilt api on the dev stack | Sonnet |
| T7 | Docs + decision log per §7: environment-reference (incl. the stale 160→480 width default), scrubbing page, ROADMAP checkbox, config.rs doc comments, DECISIONS entry, AI-INSTALL grep-verify | `docs-site/docs/configuration/environment-reference.md`, `docs-site/docs/playback/scrubbing.md`, `docs/ROADMAP.md`, `docs/DECISIONS.md`, `services/api/src/config.rs` | Every §7 row done or its deferral stated in the PR body; DECISIONS entry present (rule 7); no em-dashes in docs-site copy (house style) | Sonnet |

No task needs Opus: no crypto/authz surface beyond reusing `AdminUser`, no
recorder-path code (golden rule 2 untouched — this is all API read-side).
T3 is the correctness-sensitive one; its reviewer should check the
worst case "disabled mid-backfill" and "resolve error" paths specifically.

---

## 9. Ratified maintainer decisions

- **D1 — WIDTH at runtime: env-only v1** with a read-only console display
  (§4 option A). **RATIFIED.**
- **D2 — Live-reload approach: per-tick direct re-query** (§3 option a) over
  a cached-settings struct. **RATIFIED.**
- **D3 — Watermark clear on disable→enable** (re-enable = fresh
  `lookback_hours` backfill, never a surprise multi-day catch-up).
  **RATIFIED.**
- **D4 — No "reset to env default"** in v1 (once set in the console, the DB
  value wins for good, as with `update_check_enabled`). **RATIFIED.**
- **D5 — Cache-budget floor 100 MiB** (blocks the 0-byte "sweeper deletes
  everything every minute" foot-gun). **RATIFIED**, floor = 104,857,600 bytes.
