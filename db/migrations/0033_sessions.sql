-- 0033_sessions.sql
--
-- P0-SESSIONS: revocable authentication sessions.
--
-- Before this, a minted JWT (especially the ~10-year "remember me" token the
-- mobile app opts into) could not be revoked before its `exp`: the `AuthUser`
-- extractor validated only the HMAC signature + expiry, with no server-side
-- record of the token. A stolen phone meant permanent access until a global
-- `JWT_SECRET` rotation (which logs EVERYONE out). This migration introduces a
-- server-side session record keyed by a per-token `jti` (JWT ID) claim, so an
-- individual token — or every token for a user ("sign out all devices") — can
-- be revoked immediately while leaving all other sessions intact.
--
-- Design:
--   * One row per issued access token (login mints a `jti`; `/auth/refresh`
--     mints a fresh `jti` and a new row, so refresh rotates the session id).
--   * `revoked_at IS NOT NULL` ⇒ the token is dead, and so is a token whose row
--     is ABSENT (deleting a user cascades their rows away). The `AuthUser`
--     extractor consults small in-memory caches (see `state.rs`) so neither
--     check is a per-request DB round-trip; they are refreshed on any revoke or
--     user change, and an unknown `jti` is resolved against the DB on the spot
--     so a token minted a moment ago is never spuriously rejected.
--   * `expires_at` lets a housekeeping sweep prune long-dead rows (the table is
--     otherwise unbounded for the 10-year tokens). Pruning is best-effort and
--     NOT required for correctness — an expired token is already rejected by the
--     JWT `exp` check regardless of whether its row still exists.
--   * `last_seen_at` is updated opportunistically (best-effort, throttled) so the
--     "your sessions" UI can show device activity; it is not on the hot auth path.
--
-- Back-compat: this table predates the first public release, so every token any
-- released client has ever held carries a `jti` and has a row here. The
-- extractor therefore REQUIRES both: a token with no `jti`, or one whose row is
-- gone, is refused. (The originally-planned opt-in "reject legacy tokens" switch
-- was dropped as unnecessary — there are no legacy tokens to keep working, and a
-- token that can never be signed out is exactly what this table exists to
-- prevent.)
--
-- Fully idempotent (IF NOT EXISTS) so it is safe to (re-)apply on a long-lived
-- database, matching every other migration here.

CREATE TABLE IF NOT EXISTS sessions (
    -- The token's `jti` claim (a UUID minted at token-issue time). PRIMARY KEY so
    -- a token maps to exactly one session row.
    jti           uuid        PRIMARY KEY,
    -- Owning user. ON DELETE CASCADE so deleting a user drops their sessions.
    user_id       uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Human-friendly device/client label for the "your sessions" UI, e.g.
    -- "Android app" or a truncated User-Agent. Advisory only; never trusted.
    label         text,
    -- Best-effort client IP captured at issue time (advisory; may be a proxy).
    ip            text,
    -- Whether this session was minted as a long-lived "remember me" token.
    -- Surfaced in the UI so the user can tell a 10-year phone token from a
    -- short-lived desktop session.
    long_lived    boolean     NOT NULL DEFAULT false,
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    -- The token's `exp`, mirrored here so a housekeeping sweep can prune rows
    -- whose token has already expired.
    expires_at    timestamptz NOT NULL,
    -- NULL ⇒ active. Non-NULL ⇒ revoked at this instant; the extractor rejects it.
    revoked_at    timestamptz
);

-- Fast lookup of all of a user's sessions (the "your sessions" list and the
-- "sign out all devices" bulk-revoke), newest first.
CREATE INDEX IF NOT EXISTS sessions_user_idx
    ON sessions (user_id, created_at DESC);

-- Supports the housekeeping prune of expired/dead rows.
CREATE INDEX IF NOT EXISTS sessions_expiry_idx
    ON sessions (expires_at);
