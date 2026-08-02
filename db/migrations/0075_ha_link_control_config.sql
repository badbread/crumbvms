-- Per-link control config (Tier 2 of the HA management overhaul, epic #445,
-- issue #440). Two additive, optional knobs an operator (via the future console
-- editor, issue #439) can set on a camera<->HA link to constrain how its device
-- may be actuated from a camera view. Both default to today's behavior, so this
-- migration changes nothing until #439 lets an admin set them.
--
-- require_confirm: a client-side UX gate. When true, EVERY action on this link
-- prompts a confirmation first, on top of the existing hardcoded cover/lock
-- safety confirm. It is NOT enforced server-side (a confirm is a UI affordance);
-- the action endpoint honors allowed_actions, not this flag.
--
-- allowed_actions: a server-ENFORCED restriction. NULL = every action in the
-- link's domain allowlist is permitted (today's behavior). A non-null array
-- restricts POST /cameras/:id/ha/action to exactly these action words; anything
-- else is refused (see post_action in services/api/src/ha.rs). Entries are
-- validated at write time against the entity domain's allowlist, so a DB CHECK
-- (which would drift from the code-owned allowlist) is deliberately not used.

ALTER TABLE camera_ha_links
    ADD COLUMN IF NOT EXISTS require_confirm boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS allowed_actions text[];
