-- Per-view icon, synced server-side so a custom quick-switch icon follows the
-- operator to any client instead of living only in one desktop's localStorage.
--
-- Nullable: legacy views (created before this migration) or views a client
-- hasn't set an icon for yet have icon = NULL, and clients fall back to their
-- own default (currently the desktop's 'crumb_view_icons' localStorage cache,
-- then a hardcoded default glyph).

ALTER TABLE views ADD COLUMN IF NOT EXISTS icon text;
