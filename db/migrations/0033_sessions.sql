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
--   * `revoked_at IS NOT NULL` ⇒ the token is dead. The `AuthUser` extractor
--     consults a small in-memory revocation cache (see `state.rs`) so the check
--     is not a per-request DB round-trip; the cache is refreshed on any revoke.
--   * `expires_at` lets a housekeeping sweep prune long-dead rows (the table is
--     otherwise unbounded for the 10-year tokens). Pruning is best-effort and
--     NOT required for correctness — an expired token is already rejected by the
--     JWT `exp` check regardless of whether its row still exists.
--   * `last_seen_at` is updated opportunistically (best-effort, throttled) so the
--     "your sessions" UI can show device activity; it is not on the hot auth path.
--
-- Back-compat: tokens issued BEFORE this migration carry no `jti` claim and thus
-- have no session row. The extractor treats a `jti`-less token as "legacy, not
-- revocable" and lets it through on signature+exp alone (unchanged behaviour) —
-- so deploying this does NOT force a global re-login. An OPTIONAL admin action
-- ("revoke all pre-existing sessions") can invalidate those legacy tokens by
-- switching the extractor to reject `jti`-less tokens; that switch is a config
-- flag / server-setting, left to the owner (see RELEASE-PLAN P0-SESSIONS).
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
