# Crumb-Native LPR Engine (fast-alpr) — Design & Build Plan

**Status:** In progress (`feat/lpr-native`) · **Started:** 2026-07-17

## 1. Goal

Give Crumb its own license-plate OCR engine so LPR is **free, 100% local, AGPL-clean,
and better than Frigate 0.18's native LPR** — without the paid OpenALPR/Rekor engine,
whose Basic license provably hard-blocks any local data path (the agent's own log refuses
non-cloud destinations; Pro is too expensive).

**Engine: `fast-alpr`** (YOLOv9-t ONNX detector + CCT-xs ONNX OCR). Benchmarked on real
frames from an LPR overview camera, CPU-only on a 6-core desktop CPU: **24/25 frames read the
same plate at ~0.99 char-confidence** on a wide 7× overview (plate ~59 px wide), **~37 ms/frame**
ungated → **~7 % of one core** at a 2 fps motion-gated rate. No GPU. Comparable power draw to
OpenALPR's single-camera footprint.

## 2. Chosen approach (decisions taken)

- **Worker = Python `fast-alpr` sidecar** (reuses its CCTV tuning). Rust-native `ort` port is a
  documented future option, not now.
- **Opt-in container** (`crumb-alpr`, compose profile) that needs only LAN + the ingest token —
  runs on the Crumb host by default, or can be moved onto a dedicated mini-PC.
- **Per-camera engine select** (`frigate | crumb-alpr | both`); default the LPR camera to `crumb-alpr`,
  Frigate stays for object detection.
- **Ingest via HTTP→channel bridge** (see §4) so all existing plate logic is reused verbatim.

## 3. What already exists on `main` (reuse, do not rebuild)

`plate_reads` (incl. `crop bytea`, confidence, region, vehicle jsonb, normalized bbox, dedup,
`event_id`, `alerted`) · `lpr_config` (enabled default-off, **`ingest_token`**, retention, `watchlist_fuzz`) ·
`lpr_watchlist` (watch/ignore kinds) · pg_trgm fuzzy match · `plate_watchlist_hit` alerts fanned out by
`notifications.rs` (crop attached, alert-on-transition) · ignore-list (fail-closed) · `view_plates` RBAC ·
`GET /plates` (exact/prefix/contains/fuzzy) + `GET/POST/DELETE /lpr/watchlist` + `GET/PUT /config/lpr` ·
Frigate→`plate_reads` ingest · Plates UI (desktop/android/iOS) + PDF report.
Files: `db/migrations/0051_lpr.sql`–`0054`, `services/api/src/plates.rs`,
`services/api/src/detection_ingester.rs`, `services/common/src/db.rs` (`upsert_plate_read` @8330,
`UpsertPlateReadParams` @8279), `services/common/src/detection.rs` (`NormalizedEvent` @83).

## 4. Architecture — HTTP→channel bridge

The existing `detection_ingester` already does: upsert `plate_reads` + ignore-list (fail-closed) +
watchlist match + `plate_watchlist_hit` alert + `events` timeline mirror — all off a
`NormalizedEvent` from the shared mpsc channel (`main.rs:381`). So the worker becomes just another
detection source whose transport is HTTP instead of MQTT:

```
go2rtc restream ──frames@gated fps──► crumb-alpr worker (Python)
                                        • motion gate  • ZONE filter  • fast-alpr detect+OCR
                                        • multi-frame vote → one read/pass
                                        │ POST /lpr/reads (ingest_token, crop jpeg b64)
                                        ▼
                              api: build NormalizedEvent(source="crumb-alpr")
                                        │ event_tx.send()
                                        ▼
                              detection_ingester (UNCHANGED) → plate_reads + watchlist + alerts + event mirror
```

Only genuinely-new backend plumbing: carry the **crop JPEG bytes** end-to-end (fast-alpr gives real
crops; the Frigate path only proxies a snapshot URL).

## 5. Backend changes

1. `NormalizedEvent` (`detection.rs:83`): add `plate_crop: Option<Vec<u8>>` (consistent with the
   existing `plate_confidence`/`plate_box` plate fields).
2. `UpsertPlateReadParams` (`db.rs:8279`) + `upsert_plate_read` (`@8330`): add `crop: Option<Vec<u8>>`,
   write the `plate_reads.crop` column.
3. `maybe_record_plate` (`detection_ingester.rs:159`): pass `ev.plate_crop`.
4. **`POST /lpr/reads`** (new, in `plates.rs`): `ingest_token` auth (constant-time; reject if
   `lpr_config.enabled=false`); body `{camera_id, plate, plate_raw?, confidence?, region?, vehicle?,
   bbox?(0..1), crop?(b64 jpeg), ts, provider_event_id, source_id="crumb-alpr"}`; build a
   `NormalizedEvent` and `event_tx.send()`.
5. Wire `event_tx` into `AppState` (move channel creation ahead of `AppState::new`, `main.rs:328/381`).
6. **`GET /plates/:id/crop`** (new): serve `plate_reads.crop` bytea; `view_plates` + camera-scoped
   (mirror `events.rs` snapshot auth: Bearer or `?token=`).
7. Ingest-token generate/rotate: extend `PUT /config/lpr` (or a `POST /config/lpr/rotate-token`) —
   `update_lpr_settings` already accepts a token arg.
8. Per-camera columns (new migration 0056): `cameras.lpr_enabled bool`, `lpr_engine text`,
   `lpr_min_confidence real`, `lpr_zones jsonb` (§6). Register in `MIGRATIONS` (`db.rs`).

## 6. Detection zones (operator-requested)

Both **inclusion** ("read only here") and **exclusion** (ignore regions). `cameras.lpr_zones jsonb`
= `{include:[poly...], exclude:[poly...]}`, polygons as normalized `[[x,y]...]` (0..1), mirroring the
existing `motion_mask jsonb` convention. Worker keeps a plate iff its bbox centroid is inside an
include polygon (or none defined) AND not inside any exclude polygon. **Editor:** greenfield polygon
editor over a live snapshot in the admin console (canvas over `/cameras/:id/snapshot`), reusable later
for motion masks; desktop/android follow.

## 7. The worker (`crumb-alpr`, Python)

Pulls frames from the go2rtc restream (published RTSP port), motion-gates (Crumb motion signal or cheap
frame-diff; low floor ~1–2 fps), runs fast-alpr, votes across frames per vehicle pass, applies the
zone filter, and POSTs one read/pass to `/lpr/reads` with the crop. Config via env: API base, ingest
token, camera→stream map, min-confidence, fps floor. Ships as an opt-in compose profile; models
fetched at first-run (not vendored — see §9).

## 8. Setup wizard + admin panel

- Wizard: add an **LPR step** to `admin.html` `WIZARD_ALL_STEPS` (after `frigate`, ~line 1094):
  enable, pick camera(s), engine, optional read-zone, seed watchlist. Copy: plate DB is opt-in/off-default.
- Admin: an **LPR panel** (enable, per-camera engine + zones + min-conf, watchlist, ingest-token
  reveal/rotate), mirroring the Frigate/HA panels.

## 9. Licensing (cleared)

Wrappers MIT; detector weights YOLOv9-derived → treat as GPL-3.0 (**AGPL-compatible**); OCR
MIT/permissive. **Do not vendor weights** — fetch at first-run so Crumb never redistributes them
(air-gapped installs get a documented pre-fetch). Add `NOTICES` + `docs/DECISIONS.md` entry.

## 10. Engine comparison (DEFERRED — operator-requested for later)

Not now (Frigate has heavy object masks that make it apples-to-oranges). But `plate_reads.source_id`
already tags every read by engine, so a later **three-way** panel — `crumb-alpr` vs `frigate` vs
`openalpr` — can diff reads/hour, unique plates, confidence, and misses per camera with `lpr_engine=both`
(and OpenALPR reads pulled via its cloud API if the operator wants it in the mix). Backlog item.

## 11. Phases (each gated: fmt/clippy/`cargo test --workspace` on a CI-parity host)

- **P1 — engine + ingest:** `NormalizedEvent.plate_crop`, crop in upsert, `POST /lpr/reads`, `event_tx`
  in AppState, `GET /plates/:id/crop`, token rotate. → reads flow, watchlist/alerts work.
- **P2 — worker:** `crumb-alpr` Python sidecar + compose profile; verify real plates land.
- **P3 — zones:** `lpr_zones` schema + worker filter + admin polygon editor.
- **P4 — config + wizard:** per-camera engine/min-conf columns, LPR admin panel, wizard step.
- **P5 — docs/tests:** DECISIONS, COMPONENT-MAP, AI-INSTALL, NOTICES, ingest/zone tests.

## 12. Still open

- **Where the worker runs** — Crumb host (default) vs a dedicated mini-PC. (Config-only; doesn't block P1.)
