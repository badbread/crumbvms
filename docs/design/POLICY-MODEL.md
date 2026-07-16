# Recording-policy model redesign: every camera belongs to a named policy

Status: **design only** (nothing here is implemented). Ground truth verified
against the code on 2026-07-16; all citations are `file:line` in this tree.

North star (ratified by the maintainer): **"A camera belongs to a policy. Full
stop. If it deviates from the policy it's on, it should create a new policy."**
Every camera points at exactly one **named, operator-visible** recording policy
— the way Milestone recording profiles work. The invisible machinery
(NULL-`policy_id` inherit, anonymous copy-on-write forks, the group resolution
layer) goes away.

---

## DECISIONS.md entry (draft)

Paste at the TOP of `docs/DECISIONS.md` (newest-first format) with the
landing-PR date:

> ## 2026-MM-DD, Recording policies: explicit named membership replaces NULL-inherit + anonymous COW forks
>
> **Context.** A camera's effective recording policy resolved through a
> three-leg COALESCE (`v_camera_effective_policy`: own `policy_id` → group's
> `policy_id` → the `is_default` row), and three code paths minted **anonymous
> (`name IS NULL`) copy-on-write policy rows**: every `POST /config/cameras`
> cloned the Default into a fresh fork (`config_routes.rs` `create_camera` →
> `clone_default_policy`), every save from the admin Motion tab PUT
> `/config/cameras/{id}/policy` (the COW fork path) even with unchanged values,
> and the desktop Motion Tuner used the same endpoint. Result in prod: unnamed
> policies byte-identical to Default that no UI could see or manage ("ghosts"),
> exposed when the Storage Advisor started labelling them "Custom — \<camera\>".
> The NULL-inherit state also carried a real recorder hazard: an inheriting
> camera resolves through `(SELECT id FROM recording_policies WHERE
> is_default)`, so a missing/duplicated default row silently drops the camera
> from the recorder's inner JOIN — it just stops recording, no error.
>
> **Decision.** Every camera holds a NOT NULL `policy_id` to a **named** policy.
> (1) *Deviation auto-creates*: a camera-scoped settings edit on a shared policy
> mints a new policy auto-named after the camera (renameable), joins it — no
> naming dialog. (2) *De-dup on create*: if the edited field-set exactly matches
> an existing policy (all behavior columns, `IS NOT DISTINCT FROM`), the camera
> **joins** that policy instead; reverting to Default's values rejoins Default.
> (3) *Reap empties, keep templates*: a new `origin` column
> (`'operator'`|`'deviation'`) distinguishes auto-created deviation policies
> (reaped when memberless) from operator-created templates (kept at zero
> members); renaming a deviation policy promotes it to `'operator'`.
> (4) *Default is first-class*: new cameras join the Default **row** (no clone,
> no NULL); `is_default` keeps meaning "the policy new cameras join" and stays
> undeletable. (5) *Camera groups retire*: a policy's member list **is** the
> group; group tables/endpoints are dissolved into direct assignment + a bulk
> "assign policy to cameras" action (the 0020/0021 triggers already made a
> group nothing more than an indirection naming one policy assignment).
> One-shot migration collapses byte-identical forks into Default, names
> genuinely-distinct ones after their camera, and pins every camera, under the
> invariant that **no camera's effective policy field-values change** and no
> merge may make footage immediately eviction-eligible (byte-cap pools are
> compared before collapsing; unsafe merges keep the fork as a named policy
> instead).
>
> **Rejected.**
> - *Keep NULL-inherit + fix the fork leak*: keeps the invisible state and the
>   0-defaults-silently-stops-recording hazard; the DB cannot enforce "every
>   camera has a policy" while NULL means something.
> - *Interrogate on deviation* (naming dialog before every edit): friction on
>   the most common tuning action; auto-name + rename-later matches VMS
>   convention.
> - *Per-camera overlay/deltas on top of a policy* (Milestone-style "override
>   flags"): more faithful to "tweak one camera" but reintroduces two sources of
>   truth per knob; revisit if policy-count explosion materializes.
> - *Keep groups as a separate assignment layer*: a group was already
>   policy-exclusive and authoritative (migrations 0020/0021); two mechanisms
>   for one job is where the confusion came from.
>
> **Trade-offs accepted.** Collapsing/joining policies pools the shared
> `live_max_bytes`/`archive_max_bytes` budget across the merged membership
> (that is the intended meaning of "same policy"); a one-time worker respawn
> per repointed camera (the effective-policy id is in the recorder's change
> fingerprint); the policy list can grow with one policy per deviating camera
> (visible and manageable, unlike the ghosts).
>
> **Revisit triggers.** Operators with large fleets report the policy list
> becoming noise from many single-camera deviation policies (→ revisit the
> overlay model). A need re-emerges for camera grouping *unrelated to
> recording* (bulk ops, UI folders) (→ reintroduce groups as pure tags with no
> policy pointer). The recorder gains per-camera knobs that don't belong on a
> policy (→ keep them on `cameras`, as motion sources already are).

---

## 1. The model today (verified)

### Schema
- `recording_policies` (`db/migrations/0001_initial_schema.sql:20-42`):
  `is_default` + partial unique index `one_default_policy` (0001:42). `name`
  was added later, nullable (`0018_consolidate_runtime_ensure_ddl.sql:51-52`;
  Default backfilled to `'Default'`). No `created_at`, **no uniqueness on
  `name`**.
- `cameras.policy_id` was `NOT NULL` in 0001 (0001:52) and was made nullable to
  mean "inherit" (0018:56).
- `camera_groups` (+ optional `policy_id`) and `camera_group_members`
  (0018:59-75), with `one_group_per_camera` (0018:74-75).
- Resolution: `v_camera_effective_policy`
  (`db/migrations/0019_camera_effective_policy_view.sql:84-88`), re-declared
  append-only in 0042 and 0049: `COALESCE(c.policy_id, g.policy_id, (SELECT id
  FROM recording_policies WHERE is_default LIMIT 1))`. Every camera read goes
  through it (`CAMERA_SELECT_SQL`, `services/common/src/db.rs:354-397`).
- Groups are **authoritative and exclusive**: migration 0020 cleared direct
  overrides on grouped cameras; migration 0021 installed triggers that reject a
  non-NULL `policy_id` on a grouped camera and clear it on group join
  (`0021_grouped_camera_no_override_trigger.sql:26-57`).

### The three ghost factories
1. **Every camera create.** `POST /config/cameras` clones the Default into a
   fresh anonymous row and pins the camera to it
   (`services/api/src/config_routes.rs:780-783` →
   `db::clone_default_policy`, `services/common/src/db.rs:3085-3124`). Every
   camera added through the API is *born* on a ghost byte-identical to Default.
2. **Admin Motion tab.** Saving a camera from the Motion tab always PUTs
   `/config/cameras/{id}/policy` with `motion_sensitivity` (+ optional
   threshold/pre/post) — even when nothing changed
   (`services/api/src/admin.html:6869-6881`). That endpoint is the COW path:
   if the camera doesn't already own an anonymous fork it clones the effective
   policy and pins the clone
   (`config_routes.rs:1344-1395`, `update_camera_policy_locked`; fork =
   `clone_policy`, db.rs:3136-3175).
3. **Desktop Motion Tuner.** The Flutter client wraps the same endpoint
   (`apps/desktop-flutter/lib/api/motion_tuner_api.dart:13-14`).

The admin UI already removed its third "custom" radio and added "Save current
settings as a new policy…" (`admin.html:6519-6526`, `ceSaveAsNewPolicy`
6724-6752), but the Motion tab and the desktop tuner still fork silently.

### Cleanup today
`db::reap_orphan_policy_forks` (db.rs:3187-3203) deletes anonymous rows **only
when no camera/group references them**, run hourly by the recorder
(`services/recorder/src/main.rs:879`, `950-965`). A referenced ghost —
i.e. every ghost — is never reaped. The Storage Advisor papers over them with
"Custom — \<camera\>" labels (`services/api/src/stats.rs:179`, `268-271`,
`425-428`); storage-delete guards render them as "\<camera\>'s custom settings"
(`config_routes.rs:1905`).

### What consumes the effective policy
- Recorder worker config + change detection: `CameraFingerprint` includes the
  **effective policy id** plus behavior fields (`recorder/src/main.rs:122-156`);
  the poll loop diffs it every `config_poll_seconds` and respawns the worker on
  change.
- Retention/eviction: time sweeps are per camera; **size caps are a shared
  budget per DISTINCT effective policy id** — the sweep runs once per distinct
  `camera.policy.id` (`recorder/src/archive.rs:311-353`) and measures usage by
  summing segments of *all cameras resolving to that policy id*
  (`db::policy_stage_bytes`, db.rs:1851-1881;
  `list_policy_segments_oldest_first` honors bookmark protection,
  db.rs:1901-1929).
- `storage_migrations.policy_id` (0018:125) has **no FK** to policies.
- Latent hazard: with NULL-inherit, an inheriting camera resolves through the
  `is_default` subquery; if that row is missing or duplicated the view's inner
  JOIN **silently drops the camera** — recorder stops recording it with no
  error (the runtime shim documents exactly this, db.rs:5580-5599).

---

## 2. The new model

```
recording_policies                       cameras
  id                                       id
  name        text NOT NULL, UNIQUE        policy_id uuid NOT NULL ──► recording_policies.id
  is_default  bool  (unchanged: the        …
              policy new cameras join;
              exactly one, undeletable)
  origin      text NOT NULL DEFAULT 'operator'
              CHECK (origin IN ('operator','deviation'))
  …all existing behavior columns unchanged…
```

- A policy's **member list** = the cameras whose `policy_id` points at it.
- "On Default" = `policy_id = <Default row's id>`. No NULL state exists.
- No anonymous rows: `name` becomes NOT NULL (Phase 2, after all writers stop
  producing NULL — see rolling-upgrade note in §7).
- `camera_groups` / `camera_group_members` retire (Decision 4).
- `v_camera_effective_policy` **needs no redefinition**: with `c.policy_id`
  always non-NULL the COALESCE always takes leg 1 and the group legs are dead.
  This sidesteps the append-only-view trap entirely (the 0049 DECISIONS note).

### Behavior columns (the policy's identity for de-dup)

Everything except `id`, `name`, `is_default`, `origin` — i.e. exactly the set
`clone_policy` copies (db.rs:3141-3152) plus `max_retention_days`:

`mode, live_storage_id, live_retention_hours, archive_enabled,
archive_storage_id, archive_schedule, archive_retention_hours, live_max_bytes,
archive_max_bytes, live_min_free_pct, live_min_free_bytes,
live_spill_low_water_bytes, max_retention_days, motion_pre_seconds,
motion_post_seconds, motion_sensitivity, motion_threshold,
motion_keyframes_only, record_stream, record_audio` — **20 columns**.

Keep this list next to `POLICY_COLUMNS` (db.rs:3295-3307) with the same
"update me when the schema grows" warning `clone_policy` already carries
(db.rs:3134-3135); a `#[test]` should assert the de-dup column list and
`POLICY_COLUMNS` cover the same set minus identity columns, so a future
`ALTER TABLE` can't silently make two distinct policies "equal".

---

## 3. The five decisions

### Decision 1 — on deviation, auto-create; never interrogate

**Recommendation.** `PUT /config/cameras/{id}/policy` (kept, same request
shape — the admin Motion tab and the desktop Motion Tuner depend on it)
becomes the *deviation edit*:

1. Resolve the camera's current policy `P` and the would-be field-set `W`
   (patch of the request over `P`), under the existing
   `CAMERA_POLICY_COW_LOCK` advisory lock (`config_routes.rs:1283`,
   1310-1330 — the read-decide-write race it serializes still exists).
2. **No-op guard:** if `W` equals `P`'s fields, return `P` unchanged. (This
   alone stops the Motion-tab ghost factory: today an unchanged save still
   forks.)
3. **De-dup:** if `W` exactly matches another policy `Q` (Decision 2), repoint
   the camera to `Q`; inline-reap `P` if it is now a memberless deviation
   policy.
4. **In-place edit:** if `P` is `origin='deviation'`, not the Default, and the
   camera is its **sole** member (`count_cameras_for_policy == 1`,
   db.rs:3209-3219) — mutate `P` in place (today's `owns_anonymous_fork`
   branch, config_routes.rs:1362-1375, but the row is named). Then re-run the
   de-dup check on the result: an edit that lands exactly on Default's values
   rejoins Default and reaps `P`.
5. **Mint:** otherwise create a new policy from `W` with
   `origin='deviation'`, `name = <camera name>` (collision → `"<camera name>
   2"`, `3`, …), pin the camera to it.

Operator templates are never mutated by camera-scoped edits: editing a camera
that sits on a shared *or* sole-member `origin='operator'` policy forks. The
one canonical way to change a template is `PUT /config/policies/{id}`, which
affects all members — that split is what makes templates trustworthy.

**Auto-naming + rename flow.** Auto-name = the camera's name verbatim (the
maintainer's example: editing "Front Yard" mints policy "Front Yard"). The UI
toasts: *“Front Yard now uses its own policy ‘Front Yard’ (was ‘Default’)”*
with a **Rename** affordance; rename is the existing
`PUT /config/policies/{id}` (config_routes.rs:1496-1527). **Renaming a
deviation policy promotes it to `origin='operator'`** — an operator who named
a thing has declared it a keeper (Decision 3).

**Rejected.**
- *Inline naming dialog on every deviation*: friction on the highest-frequency
  tuning action (motion threshold nudges); operators would cancel out or
  accumulate junk names. Auto-name + rename-later is the commercial-VMS norm.
- *Silent per-camera overlay (delta columns on `cameras`)*: keeps the policy
  list small but recreates two sources of truth per knob and an invisible
  state — the disease being cured. Revisit trigger recorded.
- *Refuse camera-scoped edits entirely ("edit the policy or make one first")*:
  purest model, but breaks the desktop Motion Tuner UX and turns a
  ten-second tweak into a three-step ceremony.

**Trade-off accepted.** A fleet where many cameras each deviate slightly grows
one policy per camera. That is the *honest* representation of that fleet's
configuration; it is visible and mergeable (de-dup collapses them the moment
they re-converge), unlike today's ghosts.

### Decision 2 — de-dup on create (the anti-ghost rule)

**Recommendation.** "Exactly match" = the 20 behavior columns of §2, compared
**in SQL** with `IS NOT DISTINCT FROM` (NULL-safe, exact) against the stored
rows:

```sql
SELECT id FROM recording_policies
WHERE mode IS NOT DISTINCT FROM $1
  AND live_storage_id IS NOT DISTINCT FROM $2
  … (all 20) …
ORDER BY is_default DESC,          -- prefer Default
         (origin = 'operator') DESC, -- then operator templates
         name ASC                    -- deterministic tiebreak
LIMIT 1
```

- Compare in SQL, not in Rust: `motion_threshold` and `live_min_free_pct` are
  `real`; comparing stored value against the bound parameter the API would
  write avoids any float round-trip asymmetry. A revert writes back the exact
  value it read, so exact equality is the correct predicate (no epsilon).
- Preference order matters: when a camera's settings equal Default, it must
  rejoin **Default** even if some template happens to coincide.
- Runs only on the **automatic** paths (deviation edit step 3/4, and the
  migration's collapse). `POST /config/policies` (operator template create,
  config_routes.rs:1465-1490) is deliberately **not** de-duped: an operator
  may create "Indoor" and "Outdoor" that coincide today and diverge later.

**Semantic consequence to own explicitly:** the byte caps are a *pooled*
budget per policy (archive.rs:311-353, db.rs:1851-1881). Joining Default pools
the camera's segments into Default's `live_max_bytes` accounting. That is the
*meaning* of being on the same policy and is the intended semantics — but the
**migration** must not let a collapse trigger immediate eviction (§5 guard).
At runtime, a deliberate operator edit that lands on another policy's values is
consenting to that policy's pooling; the UI banner already shows the target
policy's cap (`bannerHTML`, admin.html:6690-6712).

**Rejected.**
- *Hash/fingerprint column for matching*: cheaper lookups, but a derived value
  that can drift from the row (and 20-column `IS NOT DISTINCT FROM` over a
  table with tens of rows is free).
- *Fuzzy match (ignore "cosmetic" columns like `archive_schedule`)*: any column
  the recorder reads is behavior; two policies differing only in schedule are
  different policies.
- *De-dup by periodic sweep instead of at write time*: leaves windows where
  duplicates exist and cameras get repointed asynchronously — an invisible
  background mutation of assignments; the write path is the only race-free
  place.

### Decision 3 — reap empties, keep templates: an explicit `origin` flag

**Recommendation.** New column `origin text NOT NULL DEFAULT 'operator' CHECK
(origin IN ('operator','deviation'))`.

- `'deviation'`: minted by the deviation-edit path (and by the migration for
  genuinely-distinct forks). **Reaped when memberless**: replace
  `reap_orphan_policy_forks`'s predicate (db.rs:3192-3196) with
  `origin = 'deviation' AND NOT is_default AND` no camera references it (the
  group leg disappears with Decision 4). Also reap **inline** at the moment a
  reassignment/de-dup empties one (so the UI never shows a dead policy for up
  to an hour); the hourly reaper (main.rs:950-965) stays as the backstop for
  camera-delete orphans (delete_camera intentionally leaves the policy behind,
  config_routes.rs:1248-1255).
- `'operator'`: created via `POST /config/policies` (incl. the console's "Save
  current settings as a new policy…", admin.html:6724-6752) or promoted by
  rename. **Never auto-deleted**; zero-member templates are the point.
  Explicit `DELETE /config/policies/{id}` keeps today's guards (default
  undeletable, 409 while referenced — config_routes.rs:1530-1605).

**Rejected.**
- *Heuristic (NULL name = auto)*: names become NOT NULL, and inferring intent
  from a name pattern ("looks like a camera name") is exactly the invisible
  heuristic state this redesign removes.
- *`kind` with more values* (`'default'|'template'|'deviation'`): `is_default`
  already exists with a partial unique index (0001:42); duplicating it invites
  disagreement between the two markers.
- *TTL-based reaping* ("delete after N days empty"): time-based magic
  deletion of operator-visible objects; either it's a keeper (flagged) or
  garbage (reap now).

### Decision 4 — Default is a first-class policy; camera groups retire

**Recommendation, part A — kill NULL-inherit.** `cameras.policy_id` becomes
`NOT NULL REFERENCES recording_policies(id)` (restoring 0001:52's shape). New
cameras join the Default **row's id** — `create_camera` stops calling
`clone_default_policy` (config_routes.rs:780-783) and simply assigns
`get_default_policy().id`. This single change kills ghost factory #1 and turns
the "0 or 2 defaults silently un-records inheriting cameras" hazard
(db.rs:5580-5599) into a structural impossibility: resolution never consults a
fallback subquery, and the FK means a camera cannot point at nothing. This is
a recorder-correctness win, not just hygiene.

`is_default` keeps exactly two jobs: "the policy new cameras join" and
"undeletable". The wizard keeps writing Default's fields
(`PUT /config/policy/default`, admin.html:2833-2856) unchanged.

**Recommendation, part B — groups dissolve into policies.** Retire
`camera_groups`/`camera_group_members` as a *resolution* mechanism. Migrations
0020/0021 already made groups exclusive and authoritative — a grouped camera
holds no own policy and follows its group's single policy pointer. A group is
therefore nothing but a named indirection to one policy assignment, and in this
codebase groups have **no other job** (permissions use roles — 0028 says so
explicitly, `0028_roles.sql:9`; views/walls have their own tables). Under the
new model, "the set of cameras on policy P" *is* the group. Two mechanisms for
one job is precisely where own→group→default confusion came from.

Concretely:
- The migration pins every grouped camera to its group's effective policy
  (group's `policy_id`, else Default) — effective field-values unchanged.
- Group endpoints (`/config/groups*`, config_routes.rs:1636-1706) enter a
  deprecation window: reads keep working; writes become **write-through**
  (changing a group's policy = bulk-update the members' `policy_id`; adding a
  member = set its `policy_id`), so old admin bundles stay functional until
  the UI ships. Then the endpoints and tables are dropped.
- The UI replaces "Group" with the policy's member list + a bulk "Assign
  policy to cameras…" action (§6) — same operator capability ("set 5 cameras
  to motion-only at once"), one mechanism.

**Rejected.**
- *Keep NULL-inherit*: the DB cannot enforce "every camera has a policy" while
  NULL is meaningful; every consumer keeps a three-way branch; the silent
  un-record hazard stays. There is no capability NULL provides that
  `policy_id = default_id` does not, except "track future changes to *which*
  policy is default" — and re-defaulting is rare, operator-initiated, and
  better handled explicitly ("also move Default's members?" prompt) than by an
  invisible late-binding rule.
- *Groups become policies 1:1 automatically* (auto-create a policy per group):
  groups without a policy would mint N copies of Default — manufacturing the
  very duplicates this design removes. Members pin to the group's *effective*
  policy instead; the group's name survives only if the operator renames that
  policy (offered once in the UI during the transition).
- *Keep groups as a separate assignment layer above policies*: preserves an
  indirection whose only function is already expressible; keeps two write
  paths (`camera.policy_id` and `group.policy_id`) that 0021's triggers exist
  solely to keep from fighting.

### Decision 5 — the migration (design in §5)

One-shot, numbered, **registered in the `MIGRATIONS` array**
(`services/common/src/db.rs:7989` — golden rule 4), split across the two
implementation phases (§8). Full design below.

---

## 4. API changes (all under existing admin RBAC — no new surface)

| Endpoint | Change |
|---|---|
| `POST /config/cameras` (config_routes.rs:721) | Stop cloning Default (:780-783); set `policy_id = Default.id`. |
| `PUT /config/cameras/{id}/policy` (:1285) | Same request/response shape; new deviation-edit semantics (§3.1: no-op guard → de-dup → in-place-if-own-deviation → mint named). Response `name` is now always non-null; additive `origin` field on `RecordingPolicyDto` (`services/api/src/dto.rs:452-456`). |
| `PUT /config/cameras/{id}` `policy_id` assignment (:1204-1229) | `Some(id)` pins (unchanged, `require_assignable_policy` :4008-4018 becomes "must exist" — every policy is named now). `Some(None)` maps to **join Default** (compat: old clients' "clear to inherit" keeps meaning "record like Default"). The grouped-camera rejection (:1209-1221) disappears with groups. |
| `GET /config/policies` (:1435) | Returns all policies (no anonymous rows exist); adds `origin` and `camera_count`. |
| `POST /config/policies` (:1465) | Unchanged (creates `origin='operator'`). Not de-duped (§3.2). |
| `PUT /config/policies/{id}` (:1496) | Unchanged + rename promotes `deviation → operator`. |
| `DELETE /config/policies/{id}` (:1535) | Unchanged guards (default 400, referenced 409). |
| `/config/groups*` (:1636-1706) | Deprecation window: writes become write-through bulk assignment; then removed. |
| New: `POST /config/policies/{id}/assign` `{camera_ids:[…]}` | Bulk pin — the replacement for a group's one useful verb. Admin-only like the rest of `/config`. |
| `GET /stats/policies`, `/stats/storage` (`stats.rs:53`, :170-199, :540+) | `label` falls back to `"Custom — <camera>"` (:270, :427) only during transition; drop after Phase 2 (name is always present). |

---

## 5. The migration

### The invariant (the sacred one)

> **For every camera, the 20 effective-policy behavior field-values resolved by
> `v_camera_effective_policy` immediately after the migration are
> `IS NOT DISTINCT FROM` the values resolved immediately before. Policy *ids*
> may change; field-values may not. Additionally, the migration must not make
> any existing segment immediately eviction-eligible.**

Retention, eviction, motion behavior, record stream/audio, and worker config
are all pure functions of those field-values (plus the id used only for
budget *grouping* — handled by the pool guard below), so holding this
invariant means the recorder's behavior for every camera is unchanged.

Testable form (integration test, same style as
`view_effective_policy_equals_canonical_coalesce`,
`recorder/src/archive.rs:4754-4830`): snapshot
`SELECT c_id, p_mode, …, p_record_audio FROM v_camera_effective_policy ORDER
BY c_id` into a temp table before, run the migration body, assert row-for-row
`IS NOT DISTINCT FROM` equality after.

### Migration A (Phase 1 — kill the ghosts; no model break)

Single file, runs in one implicit transaction (the runner wraps
non-CONCURRENTLY files — 0018:22-23). Steps:

1. `ALTER TABLE recording_policies ADD COLUMN IF NOT EXISTS origin text NOT
   NULL DEFAULT 'operator' CHECK (origin IN ('operator','deviation'));`
2. `UPDATE recording_policies SET origin = 'deviation' WHERE name IS NULL AND
   NOT is_default;` (every anonymous fork is by construction a deviation row).
3. **Collapse identical forks.** For each fork `F` (`name IS NULL`,
   `NOT is_default`) referenced by ≥1 camera — such cameras are ungrouped
   (0021's trigger guarantees grouped ⇒ `policy_id IS NULL`), so the inherit
   target is always **Default `D`**:
   - `F` matches `D` on all 20 behavior columns (`IS NOT DISTINCT FROM`), AND
   - **pool guard:** `D.live_max_bytes IS NULL OR (live bytes of D's current
     effective members + live bytes of F's members) <= D.live_max_bytes`, and
     the same for `archive_max_bytes` (usage via the `policy_stage_bytes`
     rollup semantics, db.rs:1865-1881), AND
   - **drain guard:** no `storage_migrations` row for `F.id` in
     `pending`/`running` (`storage_migrations.policy_id` has no FK, 0018:125;
     an in-flight drain must keep resolving its cameras)
   ⇒ `UPDATE cameras SET policy_id = D.id WHERE policy_id = F.id;` then
   `DELETE FROM recording_policies WHERE id = F.id;` (repoint strictly before
   delete, same transaction — see landmine L2).
4. **Name the survivors.** Any remaining `name IS NULL` row (genuinely
   distinct fork, or a fork the pool/drain guard kept):
   `name = <owning camera's name>`, suffixed `" 2"`, `" 3"` on collision
   (against both policies and other survivors); ownerless ones (unreferenced —
   the reaper's food) are deleted outright. Do **not** bake real deployment
   camera names into the migration file itself — names come from data at run
   time (see the security note in §7: migration 0020's comment already leaked
   a prod camera name once, 0020:13).
5. Fix the ongoing sources in the same PR (code, not SQL): `create_camera`
   joins Default; the deviation-edit endpoint per §3.1; reaper predicate on
   `origin`.

On the operator's prod this collapses the three known ghosts into Default
(step 3) unless Default carries a byte cap that the merged pool would exceed —
in which case they become visible named policies and a system alert tells the
operator why (footage-safe fallback; they can merge manually after freeing
space).

`name` stays nullable in Phase A: during a rolling upgrade an old recorder or
api binary can still execute `clone_policy` (COW) and would violate a NOT NULL
constraint with a 500 on a tuning write. Phase B adds the constraint once all
writers are new.

### Migration B (Phase 2 — explicit membership everywhere)

1. `DROP TRIGGER trg_reject_override_on_grouped_camera` and
   `trg_clear_override_on_group_join` + their functions (0021:40-57) — they
   exist to police the model being removed, and the reject trigger would
   **abort this very migration's pin UPDATE** if left in place (landmine L3).
2. Pin grouped cameras: `UPDATE cameras c SET policy_id = COALESCE(g.policy_id,
   D.id) FROM camera_group_members m JOIN camera_groups g … WHERE m.camera_id
   = c.id AND c.policy_id IS NULL;` — exactly the value the view's leg 2/3
   resolves today, so field-values are unchanged.
3. Pin remaining inheritors: `UPDATE cameras SET policy_id = D.id WHERE
   policy_id IS NULL;`
4. `ALTER TABLE cameras ALTER COLUMN policy_id SET NOT NULL;`
5. `UPDATE recording_policies SET name = …` (defensive backfill for any
   NULL-name row a mixed-version writer created since A, same rule as A step
   4), then `ALTER TABLE recording_policies ALTER COLUMN name SET NOT NULL;`
   and `CREATE UNIQUE INDEX … ON recording_policies (name);` (dedupe-suffix
   collisions first).
6. Groups: keep the tables (dormant) for one release for rollback comfort;
   endpoints go write-through in the same PR; a later cleanup migration drops
   them.
7. **Update the runtime shim in the same PR**: `ensure_named_policies_and_groups`
   (db.rs:5531-5578) executes `ALTER TABLE cameras ALTER COLUMN policy_id DROP
   NOT NULL` on **every boot** (db.rs:5553-5555, mirrored at 0018:54-56). Left
   unedited, the next boot silently un-does step 4. (During a mixed-version
   window an *old* binary's shim will still drop it; harmless — the new code
   never writes NULL — and the next new-binary boot cannot re-add it unless the
   shim is also taught to `SET NOT NULL`, which it should be, guarded on "no
   NULL rows exist".)

`v_camera_effective_policy` is intentionally untouched in both migrations: the
COALESCE degenerates to leg 1, all column names/types/order stay identical (no
append-only-view trap), and the Phase-1 equivalence tests
(archive.rs:4754-5050) keep passing verbatim.

---

## 6. Admin-console UX (`services/api/src/admin.html`)

- **Recording section** becomes the policy manager: one row per policy — name
  (inline-renameable), mode badge, member count + names, live/archive storage,
  retention summary, and for `origin='deviation'` a subtle "auto-created when
  \<camera\> deviated" hint. "New policy" = today's create flow. Member
  management lives on the policy page (add/remove cameras = bulk assign).
- **Camera → Recording tab**: the grouped/ungrouped branch
  (`renderCamStorageTab`, admin.html:6485-6489) collapses to one view: a
  single "Recording policy" select (always a real name — "Custom" never
  appears), an **Edit policy** button, and the existing effective-settings
  banner (`bannerHTML`) unchanged. "Save current settings as a new policy…"
  stays as the *deliberate* template-create path.
- **Deviation feedback**: when a Motion-tab (or tuner) save mints/joins a
  policy, toast the transition — *"Front Yard now uses policy 'Front Yard'"* /
  *"Front Yard settings match 'Default' — rejoined it"* — with Rename/Undo
  (undo = repoint to the previous policy id, which the response can carry).
- **Groups UI** is replaced by the policy member list + a bulk "Assign policy
  to cameras…" dialog; during the transition, the group pane offers a one-time
  "convert this group to a policy assignment" that optionally renames the
  target policy to the group's name.
- **Storage Advisor**: `usage_by_policy` legend (admin.html:4105-4133) and
  `/stats` labels show real names; the `"Custom — <camera>"` fallbacks
  (stats.rs:270, 427) are kept through Phase 1 and deleted in Phase 3.
- Escaping discipline unchanged: policy names are operator data → `esc()` at
  every interpolation (they already are in the banner/legend paths).
- Desktop Flutter: the Motion Tuner needs **no change** (same endpoint, same
  shapes); its "resolved policy" display gets real names for free. Update
  `docs/COMPONENT-MAP.md` Policy-UI row (COMPONENT-MAP.md:145) in the same
  change.

---

## 7. Retention/eviction + recorder interaction, landmines, security

### What must not change
- Time-based retention sweeps (per camera) and the size-cap/max-retention
  sweeps (per distinct effective policy, archive.rs:311-353) read only
  field-values and the id-grouping. The invariant in §5 covers both: values
  identical, and regrouping is only allowed where the pool guard proves it
  cannot trigger eviction at migration time.
- Bookmark protection is enforced inside the eviction candidate query
  (db.rs:1920-1926) and is orthogonal — unchanged.
- Segments never reference policies; footage location is `segments.storage_id`
  (0020's footage note) — no migration touches a segment row.

### Does a reassignment need a recorder restart?
No. The recorder polls `list_enabled_cameras` every `config_poll_seconds` and
diffs `CameraFingerprint` (main.rs:122-156, 573-574). A repoint flips the
effective `policy_id` in the fingerprint → **automatic worker respawn on the
next poll**, exactly as a policy reassignment behaves today. The migrations
themselves run at boot (both api and recorder embed the runner), so the
post-migration recorder starts from clean state anyway. go2rtc is untouched
(policies don't affect streams; no reconcile needed).

### Correctness landmines
- **L1 — pooled byte budgets.** Collapsing/joining changes which segments
  share a `live_max_bytes`/`archive_max_bytes` pool (db.rs:1851-1881). Guarded
  at migration time (pool guard, §5); at runtime it is the semantics the
  operator chose. Never merge without the guard.
- **L2 — repoint before delete, one transaction.** A policy row deleted while
  any camera still resolves to it drops that camera from the view's inner JOIN
  → the recorder silently stops recording it (the db.rs:5580-5586 hazard
  class). Migration A step 3 and every runtime reap must delete only rows with
  zero referents, after the repoint, in the same transaction. The FK (`NO
  ACTION`, db.rs:3508-3510) backstops direct refs; nothing backstops the
  is_default fallback until Phase B removes it.
- **L3 — 0021 triggers vs the pin.** `trg_reject_override_on_grouped_camera`
  raises on setting `policy_id` for grouped cameras (0021:29-35); Migration B
  must drop it *before* its pin UPDATE or the whole migration aborts.
- **L4 — the boot shim un-does NOT NULL.** db.rs:5553-5555 drops the
  constraint every boot; edit the shim in the same PR as Migration B (§5).
- **L5 — one-time worker respawns.** Every repointed camera respawns its
  worker on the next poll (a seconds-long recording restart, same as any
  reassignment today). Fleet-wide, that is N respawns on the first
  post-upgrade poll. Acceptable for the ~handful of affected cameras;
  optional follow-up: fingerprint on policy field-values instead of id so
  identical-value repoints don't respawn (do **not** fold in casually — id
  flips are also how group/policy edits trigger reloads today).
- **L6 — advisory-lock discipline.** The deviation edit keeps
  `CAMERA_POLICY_COW_LOCK` (config_routes.rs:1283, 1310-1330): mint/de-dup/
  in-place is the same read-decide-write shape as today's COW; two concurrent
  edits must not both mint or edit a row that just gained a second member. The
  reaper's guarded DELETE stays safe as-is (unreferenced-only predicate).
- **L7 — de-dup column drift.** A future policy column added to the schema but
  not to the de-dup list makes genuinely different policies "equal" → silent
  behavior merge. The paired test in §2 (POLICY_COLUMNS ↔ de-dup list) is
  mandatory, mirroring `clone_policy`'s existing warning (db.rs:3134-3135).
- **L8 — in-flight storage drains.** `storage_migrations.policy_id` is FK-less
  (0018:125); the drain worker resolves cameras by policy id. Collapsing a
  policy with a pending/running drain would orphan the drain mid-flight —
  hence the drain guard in Migration A and a matching refusal in the runtime
  reap/de-dup path (join is still fine; it's the *delete* that must wait).
- **L9 — exactly-one-default.** Unchanged and load-bearing
  (`one_default_policy`, 0001:42); Migration A/B never insert or flip
  `is_default`.

### Secure-by-default notes
- No new network surface; every touched endpoint already sits behind admin
  RBAC (`AdminUser` extractors throughout config_routes.rs) — keep the new
  bulk-assign endpoint admin-only like its siblings.
- Policy names are operator-controlled strings rendered in the console —
  `esc()` on every interpolation (existing convention), and they flow into
  logs only as structured fields (fine, logs are local).
- **Do not embed deployment-specific data in migration files.** Migration
  0020's comment block hard-coded a prod camera name (0020:13) — that class of
  leak is already on the leak-scan backlog. Migration A derives names from
  data at runtime and its comments must stay generic.
- The migration deletes only *policy rows*; it cannot touch footage
  (`segments` unreferenced), and every destructive statement is guarded by a
  zero-referents predicate — misfiring twice is a no-op (idempotence, like
  0018/0020).

---

## 8. Phased implementation plan

**Phase 1 — kill the ghosts (one PR; Migration A registered in
`MIGRATIONS`, db.rs:7989).** No model break, no UI break: the existing admin
bundle keeps working because endpoint shapes are unchanged.
- Migration A (§5): `origin` column, mark forks, collapse-with-guards, name
  survivors.
- `create_camera` joins Default (config_routes.rs:780-783 goes away).
- `update_camera_policy_locked` → deviation edit (no-op guard, de-dup,
  in-place-own-deviation, mint-named) under the existing advisory lock.
- Reaper predicate → `origin='deviation'` + inline reap on repoint.
- Tests: invariant snapshot test (§5), de-dup join/rejoin-Default, pool-guard
  keeps fork, template survives at zero members, no-op save mints nothing
  (regression for the Motion-tab factory).
- DECISIONS.md entry (above) and COMPONENT-MAP policy rows land here.
- Gate: fmt/clippy/workspace tests per golden rule 3. No `.env`/compose/
  install-flow change ⇒ `docs/AI-INSTALL.md` untouched (stating this
  explicitly per golden rule 5).

**Phase 2 — explicit membership (one PR; Migration B registered).**
- Migration B (§5): drop 0021 triggers, pin grouped + inheriting cameras,
  `policy_id NOT NULL`, `name NOT NULL` + unique, groups dormant.
- Shim edit (L4), assignment `null` ⇒ Default-join, group endpoints
  write-through, `require_assignable_policy` reduced to existence.
- Tests: trigger-drop-then-pin ordering, invariant snapshot across B,
  mixed-version NULL-name backfill.

**Phase 3 — UI + retirement (1-2 PRs, no migration except the final
groups-table drop).**
- Admin Recording section per §6 (policy manager, member lists, deviation
  toasts, bulk assign), remove group UI, drop `"Custom — …"` label fallbacks
  (stats.rs:270/427, config_routes.rs:1905).
- Final cleanup migration dropping `camera_groups`/`camera_group_members` +
  the group legs of any code left, one release later.

Phase 1 alone fixes the operator-visible pain (the three prod ghosts collapse;
no new ones can be minted). Phases 2-3 complete the "camera belongs to a
policy, full stop" model.
