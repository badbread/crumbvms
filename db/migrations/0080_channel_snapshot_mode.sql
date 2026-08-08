-- 0080_channel_snapshot_mode.sql
--
-- Per-channel SNAPSHOT attachment MODE for notification channels.
--
-- Historically a channel carried a single `include_snapshot bool` that meant
-- "attach the full vehicle frame" (and only three providers actually sent an
-- image). This replaces that binary with a four-way choice, capability-gated
-- per provider by the dispatch layer:
--
--   'none'    — never attach an image (even when one is available).
--   'plate'   — attach the tight plate crop only.
--   'vehicle' — attach the full vehicle/detection frame (the legacy behaviour).
--   'both'    — attach both, where the provider can carry two images; where it
--               can only carry one, the plate crop wins (more informative).
--
-- `snapshot_mode` is the single source of truth read by the engine from now on.
-- `include_snapshot` is KEPT as a synced legacy mirror (create/update write it
-- from the mode: `mode <> 'none'`) so an older reader or a rollback still sees a
-- consistent value; the engine no longer reads it. The backfill below derives
-- the initial mode from the existing bool so an upgrade preserves behaviour
-- exactly: a channel that attached the frame keeps attaching it ('vehicle'),
-- one that did not stays silent ('none').
--
-- Idempotent by construction:
--   * `ADD COLUMN IF NOT EXISTS` (no-op on re-apply);
--   * the backfill is guarded by `WHERE snapshot_mode IS NULL`, so a re-apply
--     after an interrupted boot can NEVER clobber an operator's chosen mode
--     (every row created after this migration always writes the column);
--   * `SET DEFAULT` / `SET NOT NULL` are no-ops when already in that state;
--   * the CHECK constraint uses the DROP-then-ADD pattern (Postgres has no
--     `ADD CONSTRAINT IF NOT EXISTS`), matching the 0071 pattern and the
--     `migrations_guard_add_constraint_for_reapply` tripwire.

ALTER TABLE notification_channels
    ADD COLUMN IF NOT EXISTS snapshot_mode text;

UPDATE notification_channels
    SET snapshot_mode = CASE WHEN include_snapshot THEN 'vehicle' ELSE 'none' END
    WHERE snapshot_mode IS NULL;

ALTER TABLE notification_channels
    ALTER COLUMN snapshot_mode SET DEFAULT 'vehicle';

ALTER TABLE notification_channels
    ALTER COLUMN snapshot_mode SET NOT NULL;

ALTER TABLE notification_channels
    DROP CONSTRAINT IF EXISTS notification_channels_snapshot_mode_chk;
ALTER TABLE notification_channels
    ADD CONSTRAINT notification_channels_snapshot_mode_chk
    CHECK (snapshot_mode IN ('none', 'plate', 'vehicle', 'both'));
