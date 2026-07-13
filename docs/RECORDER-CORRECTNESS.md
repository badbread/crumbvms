# Recorder correctness checklist

Distilled from the adversarial review of the first (Python) recorder implementation.
Every item below is a **real defect that was found**. Any implementation (the Rust
recorder, and later the API) must satisfy these *by construction*.

## ffmpeg / segmenting
1. **fMP4 flags must reach the inner mp4 muxer.** With `-f segment -segment_format mp4`,
   pass `-segment_format_options movflags=+frag_keyframe+empty_moov+default_base_moof`.
   A top-level `-movflags` is applied to the *segment* muxer and silently ignored →
   non-fragmented MP4s (moov written at close) that are unplayable if the process is
   killed mid-segment.
2. **Segments start on keyframes and are independently seekable:** `-c copy` (zero
   re-encode), `-segment_atclocktime 1`, `-reset_timestamps 1`.
3. **Precise timestamps:** derive `start_ts` from the strftime-encoded filename
   (clock-aligned; container runs in UTC), set `end_ts` = next segment's `start_ts`
   (contiguous), `duration = end - start`. Do **not** use wall-clock at the moment a log
   line is observed. Final segment at shutdown: use file mtime (or start + segment_seconds).
4. **Don't depend on log verbosity for segment detection.** Prefer `-segment_list pipe:`
   / a segment-list file (muxer-reported boundaries). If scraping stderr, note the
   "Opening … for writing" line is emitted at *verbose* level, log-scraping is fragile.

## subprocess safety
5. **Never deadlock on child pipes.** Any ffmpeg child whose stdout you read for frames
   MUST have its stderr drained concurrently (or routed to null). A full ~64 KB stderr
   pipe blocks ffmpeg → blocks your reader forever → the NVDEC session + VRAM leak
   indefinitely (and starve the shared GPU). In tokio: read stdout and stderr in separate
   tasks, or send the unused stream to null.
6. **Clean shutdown actively kills the child** (SIGTERM/kill), don't wait for it to emit
   output. A `-c copy` stream on a quiet camera emits nothing for long stretches; relying
   on log cadence to notice a stop request makes shutdown hang. Use task cancellation +
   child.kill(); target a few seconds, ideally instant.

## storage lifecycle (data-loss class)
7. **Live-retention deletion MUST skip archive-enabled cameras/segments.** The archiver
   owns deletion of those (after a verified copy). Otherwise the frequent retention tick
   deletes aged segments before the (cron) archive job runs → **permanent data loss**.
8. **Archive move ordering (crash-safe):** copy → verify (size/checksum) → update index row
   (`storage_id`, `stage='archive'`, `path`) → delete source. A reader always sees
   old-or-new, never half-moved.
9. **Startup reconciliation scans BOTH live AND archive storage.** An interrupted archive
   move leaves a verified copy in archive with no row (orphan), only an archive scan
   reclaims it. Also delete dangling rows (row → missing file).
10. **Retention deletes file THEN row**, so a crash never leaves a row pointing at a
    missing file.

## GPU / isolation (must not break the shared host)
11. **Cap concurrent NVDEC decode sessions** with a global semaphore (env-configurable,
    e.g. `MAX_GPU_DECODE_SESSIONS`). When exhausted, fall back to CPU decode. Prevents VRAM
    exhaustion that would starve other GPU workloads sharing the host.
12. **Recording is `-c copy` (zero decode). Motion runs on the SUB stream only.** Streams
    come from Crumb's own embedded go2rtc restreamer (run by the recorder), not an external one.

## DB / seed
13. **Seed is idempotent.** `storages` needs `UNIQUE(name)` (+ `ON CONFLICT`) or a
    query-first guard; otherwise re-running seed (entrypoint runs it every start) inserts
    duplicate storage rows → nondeterministic storage selection.
14. **Config reload fires only on actual change** (compare a version/hash) and must not
    needlessly rebuild the motion ring buffer (which drops buffered pre-motion segments).

## motion
15. Frame-diff pipeline: downscale → grayscale → blur → absdiff vs previous → threshold →
    count changed pixels. Dynamic sensitivity (default) auto-calibrates from recent stats;
    manual uses a fixed threshold. Apply `motion_mask` polygons. Emit
    `MotionSignal(camera_id, started_at, stopped_at, peak_score)`. Keep the motion-source
    interface generic (Frigate-MQTT seam later, do not build it).
16. In Rust, do the frame-diff **natively** on the grayscale bytes ffmpeg emits
    (`-vf scale=…,format=gray` → operate on `&[u8]`). No OpenCV dependency.

## motion-mode RAM cache (persist-on-motion; docs/MOTION-RECORDING.md)
17. **Persist ordering is copy → fsync file → fsync containing dir → index row →
    delete cache file**, the same crash-safe shape as the archive move (#8), applied to
    the tmpfs-cache→disk path instead of the live→archive path. A reader (including
    reconcile) must always see old-or-new, never a segment that's "moved" but unindexed.
18. **A crash between copy and index is an ORPHAN, not a loss.** The persisted `.mp4`
    exists on disk with no `segments` row yet, reconcile's existing orphan-adoption scan
    (the same one that adopts a live-write orphan today) must pick these up on the next
    pass, same as any other unindexed file under the media root. Do not add a second,
    parallel "recover motion-persisted orphans" path, one reconciler, one set of rules.
19. **Fail-open is an invariant, not a fallback heuristic.** The instant a camera's motion
    detector is judged unhealthy (stalled sub-stream, dead decoder, any state where the
    recorder can no longer produce a trustworthy keep/discard verdict), that camera MUST
    persist every segment to disk, same as Continuous mode, until detection is verified
    healthy again, and a health alert must fire for the duration. "Detector state unknown"
    always resolves to "keep everything," never to "keep nothing" or "keep last-known verdict."
    The same invariant applies one level below the detector: if the tmpfs RAM cache itself
    can't be used (cache dir path rejected, or `create_dir_all` fails, e.g. the tmpfs
    mounted root-owned instead of `mode: 01777`, so the recorder's non-root uid 1001 gets
    `EACCES`; a real prod incident, see `docs/MOTION-RECORDING.md`), the camera falls back
    to direct-to-storage the same way and now ALSO raises a health alert
    (`motion_cache_unavailable`, migration `0040_motion_cache_unavailable_alert.sql`) so the
    condition is loud instead of a silent 11-hour "why is this camera recording everything"
    surprise. The fallback itself is unchanged and safe, footage is never lost, only the
    disk-saving benefit of Motion mode is temporarily suspended, this item only requires
    that it also be *visible*.
20. **Spill never drops a buffered segment.** If the tmpfs cache nears its configured size
    (`MOTION_CACHE_TMPFS_BYTES`), the correct response is to persist the OLDEST buffered
    segments to disk (freeing cache space the same way a normal keep-verdict would), never
    to evict/delete a cached segment that hasn't been through a keep/discard decision.
    Cache pressure is allowed to change *when* a segment is written; it must never change
    *whether* it survives.
21. **The RAM cache is not a durability boundary for anything already persisted.** Once a
    segment has cleared the ordering in #17 it is on disk and indexed, a crash, container
    restart, or tmpfs wipe afterward must not be able to touch it. Only segments still
    sitting in the ring buffer (not yet triggered into a keep verdict) are at risk on an
    unclean shutdown, and that risk is bounded by `motion_pre_seconds` by construction.

## absolute max-retention cap (data-minimization ceiling)
22. **The per-policy `max_retention_days` cap is a HARD CEILING that deliberately
    overrides item 7's stage/archive scoping, and that is correct, not a bug.** The
    per-tier live sweep skips `archive_enabled` cameras and touches only `stage=live`
    (item 7: the archiver owns their deletion). The absolute cap has the opposite
    requirement: footage older than the operator-configured ceiling must be removed
    whether or not it was archived and regardless of stage, or the operator's stated
    retention limit is violated. So `archive::max_retention_sweep` queries BOTH stages
    and does not exclude archiving cameras. It is still bound by every OTHER
    footage-safety rule: **OFF by default** (`NULL` ⇒ no-op, so an existing install is
    never surprise-pruned); file-then-row deletion (item 10) via the shared
    `NotFound`-tolerant helper; serialized on `ARCHIVE_GUARD` so it can never delete a
    segment mid archive-move (item 8); skips segments under an active protected bookmark
    (a human pin outranks the automatic cap); and batch-limited so first enabling a
    short cap converges over ticks instead of one mass delete. When set it can only
    remove footage *sooner* than the other knobs would, never keep it longer.

## declared tracks must carry decodable packets, on every client (audio-integrity)
23. **A recorded segment MUST contain decodable media PACKETS for every track it
    declares — and those packets must be decodable by EVERY client, not just
    desktop.** The recorder picks the audio args per camera from the probed source
    sample rate (`audio_segmenter_args` / `audio_needs_transcode` /
    `probe_audio_sample_rate`; docs/DECISIONS.md 2026-07-12): **≤ 48 kHz → bit-exact
    copy** (`-c:a copy -copyinkf:a`); **> 48 kHz, or an unknown/failed probe →
    transcode to 48 kHz AAC** (`-c:a aac -ar 48000`). This guards two failure modes:
    - **Cross-client playability (the transcode case).** Some cameras stream AAC at
      rates that Android's hardware/`c2` decoders reject outright (a real device
      logs `MediaCodecInfo: NoSupport [sampleRate.support, 64000] [c2.android.aac
      .decoder]` and plays SILENT). A bit-exact copy plays on desktop's software
      ffmpeg decoder but not on Android/web, so any rate > 48 kHz is transcoded down
      to a universally-decodable 48 kHz.
    - **Empty-track copy gate (the copy case still needs `-copyinkf:a`).** Under
      `-c copy`, ffmpeg's CLI silently discards every packet on a stream until the
      first keyframe-flagged one, and the RTP-AAC (MPEG4-GENERIC) depacketizer never
      key-flags audio — so a plain copy yields a declared-but-EMPTY aac track (the
      moov lists it from the SDP; zero samples), silent with no warning at any
      normal log level. The copy path therefore keeps `-copyinkf:a`; the transcode
      path re-encodes from decoded PCM and has no keyframe gate.

    Video always stays a bit-exact copy (the audio args override only audio; they do
    NOT touch the fMP4 crash-safety flags, item 1). **The export path is separate:**
    `services/api/src/export.rs`'s `-c:a copy` still emits `-copyinkf:a` against
    the keyframe gate (the recorded fMP4's `trun` faithfully preserves the missing
    key flag), and it does **not yet** normalize the sample rate — an exported
    clip can still carry a rate a phone won't decode until export is normalized
    too (a known follow-up). Detector: `audio_needs_transcode` is unit-tested (≤ 48 kHz
    → copy, > 48 kHz / unknown → transcode) and `audio_segmenter_args` for both
    branches; any integration check should assert `nb_read_packets > 0` on the audio
    stream, not merely that the stream exists.

## free-space floor (ENOSPC safety valve)
24. **The floor keys off free space AVAILABLE to the recorder, and its response
    must actually FREE bytes.** Read `statvfs` `f_bavail`/`f_frsize`, NOT `f_bfree`
    (which includes the ext4 root reserve the non-root recorder cannot use, so the
    valve would never fire). When the floor is in deficit, an archive-move that
    lands on the SAME filesystem as the deficit disk frees nothing — on the default
    compose layout that let the disk fill to 100% and ENOSPC-halt recording. So the
    deficit path DELETES the oldest live segment (a narrow, loud exception to item
    7, in the spirit of item 22) when — and only when — the segment's storage
    shares the archive filesystem AND the deficit filesystem (`st_dev` identity); a
    segment on any other disk falls through to the normal footage-preserving move.
    Oldest-first, protected bookmarks excluded, file-then-row (10), serialized on
    `ARCHIVE_GUARD` (8), and a `premature_rollover` event fires so the loss is
    visible. See `docs/DECISIONS.md` (2026-07-12).

## fail-open across every seam (extends item 19)
25. **Fail-open state survives reconnect and stays consistent through an unhealthy
    window.** `MotionBuffer`/`MotionUnion`/`pending_signals` are worker-lifetime
    (carried across an ffmpeg reconnect; the R1 cache sweep spares carried pre-roll
    via a keep-set; a flip-guard blocks a cache/storage-flavour self-copy-truncate),
    so a reconnect mid-event never drops the tail. Through a frozen window the union
    is kept in sync — edges fold, the newest is stashed and replayed on thaw, and a
    replayed STOP onto an Idle buffer enters `PostBuffer` so a full event inside the
    window keeps its post-roll. Do NOT add a blind time-based `MotionUnion` expiry:
    it cannot tell a lost STOP from a genuinely-long event and on a multi-source
    camera would discard footage a healthy source is still asserting (the wedge is
    covered footage-safe by the loss-debt fail-open + source supervision instead).
26. **A detector is HEALTHY only when it can produce a keep/discard verdict.** The
    Frigate source reports healthy on a GRANTED MQTT SubAck, never on ConnAck (a
    denied subscription is "healthy forever, zero events"); the pixel detector only
    after warm-up; a panicked source task is supervised and immediately reads
    unhealthy → fail-open; a `MotionSignal` dropped on a full channel flips the
    source to fail-open via an interposed health watch (never silently lost).

## stall watchdog & boot reap
27. **The segment-receipt stall watchdog is anchored to the last received segment,
    not a per-`select!`-iteration timeout.** A co-scheduled telemetry tick shorter
    than the timeout must not be able to rebuild/reset the deadline every loop — that
    left a half-open stream recording nothing indefinitely. It is a dedicated select
    arm on `sleep_until(last_segment_at + timeout)`.
28. **Boot index-reap skips only a GENUINE in-progress build.** An INVALID index is
    dropped so a later `CREATE INDEX IF NOT EXISTS` rebuilds it; on a lock timeout,
    re-check `pg_stat_progress_create_index` for that index — skip a real manual
    `CREATE INDEX CONCURRENTLY`, but RETRY transient/foreign contention rather than
    permanently skipping (which would silently leave a broken catalog entry).
