-- Platform-wide toggle to hide the bookmarks UI across all clients. When false,
-- clients hide the bookmark button(s). Admin-editable; default true. Idempotent.
ALTER TABLE server_settings
    ADD COLUMN IF NOT EXISTS bookmarks_enabled boolean NOT NULL DEFAULT true;
