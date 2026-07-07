-- 0037_segment_motion_shadow.sql
--
-- commercial-VMS-style motion recording (RAM pre-buffer + persist-on-motion):
-- SHADOW MODE validation column. When `MOTION_RECORDING_SHADOW=1`, a
-- Motion-mode camera keeps recording + indexing every segment exactly as
-- today (byte-for-byte unchanged file operations), but the recorder ALSO
-- runs the MotionBuffer decision in parallel and stamps the verdict here:
--
--   * `true`  — the buffer would have PERSISTED this segment (pre-roll /
--                active motion / post-roll window).
--   * `false` — the buffer would have DISCARDED this segment (idle ring
--                buffer, aged out, superseded).
--   * `NULL`  — no shadow verdict recorded (continuous-mode cameras, or
--                shadow mode was off at index time).
--
-- This lets an operator compare "what shadow mode would have kept" against
-- disk usage / footage before flipping MOTION_RECORDING_SHADOW off and
-- letting Motion mode actually skip writing discarded segments to storage.
--
-- Idempotent (IF NOT EXISTS), matching every other migration here.

ALTER TABLE segments
    ADD COLUMN IF NOT EXISTS motion_shadow_keep boolean;
