-- 0079_alert_templates.sql
--
-- Customizable notification alert TEXT across all system-alert types.
--
-- Two additive, nullable surfaces:
--
--   1. `system_events.meta` (jsonb) — the structured, event-scoped tokens each
--      emit site can offer (plate/name/confidence/zone for a watchlist hit,
--      free_pct/path for low disk, etc.). Historically these facts were baked
--      into the free-text `detail` string only; carrying them structured lets a
--      template reference them by name (`%plate%`, `%free_pct%`). `detail`
--      stays as the `%detail%` fallback token and for back-compat.
--
--   2. `system_alert_rules.message_template` / `title_template` (text) — the
--      per-`event_key` operator overrides. NULL means "use the built-in default
--      template for this event_key" (so clearing the column back to NULL is a
--      one-click "Restore default"). The rendered text substitutes `%token%`
--      placeholders only; it never carries anything executable, and it is always
--      JSON-escaped by the provider dispatch layer before it enters a payload.
--
-- Fully idempotent (ADD COLUMN IF NOT EXISTS) so re-applying on a long-lived
-- database is a no-op, matching every other migration here.

ALTER TABLE system_events
    ADD COLUMN IF NOT EXISTS meta jsonb;

ALTER TABLE system_alert_rules
    ADD COLUMN IF NOT EXISTS message_template text,
    ADD COLUMN IF NOT EXISTS title_template   text;
