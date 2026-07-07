-- Migration 0003: add record_audio to recording_policies
--
-- Adds a boolean flag controlling whether the recorder includes the audio
-- track in recorded segments.  Defaults to TRUE (existing behaviour
-- preserved — audio was always passed through via -c copy).
--
-- IF NOT EXISTS makes this idempotent so the orchestrator can apply it
-- safely on every container startup.

ALTER TABLE recording_policies
    ADD COLUMN IF NOT EXISTS record_audio boolean NOT NULL DEFAULT true;
