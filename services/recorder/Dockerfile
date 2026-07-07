# Crumb NVR — recorder service
#
# Build context: REPO ROOT (not this directory).
# docker-compose.yml must set:
#   build:
#     context: .
#     dockerfile: services/recorder/Dockerfile
#
# This is required because the Cargo workspace root (Cargo.toml + Cargo.lock)
# lives at the repo root, and services/common is a workspace member that
# services/recorder depends on.
#
# Two-stage build:
#   builder — compiles the Rust workspace in release mode on bookworm.
#   runtime — minimal bookworm-slim image with jellyfin-ffmpeg + the binary.
#
# GPU is OPT-IN: the base docker-compose.yml boots this image GPU-free
# (MOTION_HWACCEL=auto → CPU when no GPU). NVDEC is enabled by the GPU overlay
# docker-compose.gpu.example.yml, which re-adds the nvidia device reservation +
# 'video' capability + NVIDIA_DRIVER_CAPABILITIES=video,compute,utility.

# ─── stage 1: build ──────────────────────────────────────────────────────────

FROM rust:1-bookworm AS builder

WORKDIR /build

# Install build dependencies (openssl headers are needed by some transitive
# deps; pkg-config lets the build scripts find them).
RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy workspace manifests first for layer caching.
# The workspace Cargo.toml + Cargo.lock resolve all dependency versions.
# Member Cargo.toml files are needed so `cargo build` resolves the workspace.
COPY Cargo.toml Cargo.lock ./
COPY services/common/Cargo.toml  services/common/Cargo.toml
COPY services/recorder/Cargo.toml services/recorder/Cargo.toml
# The api member must exist for the workspace to resolve, even though this image
# builds ONLY the recorder (-p crumb-recorder, not --workspace) so it never
# compiles axum etc. into the recorder image.
COPY services/api/Cargo.toml      services/api/Cargo.toml

# Create stub lib/main so cargo can build the dependency graph without the real
# source (maximises cache hit on dep changes). The api stub stays in place so
# the workspace remains valid; -p crumb-recorder never compiles it.
RUN mkdir -p services/common/src services/recorder/src/bin services/api/src \
    && echo 'pub fn _stub() {}' > services/common/src/lib.rs \
    && echo 'fn main() {}' > services/recorder/src/main.rs \
    && echo 'fn main() {}' > services/recorder/src/bin/seed.rs \
    && echo 'fn main() {}' > services/api/src/main.rs

RUN cargo build --release -p crumb-recorder \
    && rm -rf services/common/src services/recorder/src

# Copy real source and rebuild (only changed crates recompile).
COPY services/common/src  services/common/src
COPY services/recorder/src services/recorder/src

# db/migrations/*.sql is embedded into the binary at compile time via
# include_str!("../../../db/migrations/…") in crumb-common's run_migrations.
# It MUST be in the build context or the crumb-common compile fails.
COPY db/migrations ./db/migrations

# Touch source files so cargo detects the change vs the stub build above.
RUN touch services/common/src/lib.rs services/recorder/src/main.rs \
         services/recorder/src/bin/seed.rs

RUN cargo build --release -p crumb-recorder

# ─── stage 2: runtime ────────────────────────────────────────────────────────

FROM debian:bookworm-slim AS runtime

# Install jellyfin-ffmpeg (ships modern ffmpeg with NVDEC support built-in).
# The jellyfin apt repo provides the package.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
    && curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/jellyfin.gpg] \
        https://repo.jellyfin.org/debian bookworm main" \
        > /etc/apt/sources.list.d/jellyfin.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        jellyfin-ffmpeg7 \
    && rm -rf /var/lib/apt/lists/*

# Symlink jellyfin-ffmpeg into PATH so the recorder can call `ffmpeg` directly.
RUN ln -sf /usr/lib/jellyfin-ffmpeg/ffmpeg /usr/local/bin/ffmpeg \
    && ln -sf /usr/lib/jellyfin-ffmpeg/ffprobe /usr/local/bin/ffprobe

# Copy the compiled binaries from the builder stage.
COPY --from=builder /build/target/release/crumb-recorder /usr/local/bin/crumb-recorder
COPY --from=builder /build/target/release/seed              /usr/local/bin/seed

# Embedded go2rtc restreamer (see services/recorder/src/go2rtc_embed.rs). The
# recorder process spawns + supervises it as a child, replacing the former
# standalone `go2rtc` compose service. Copied straight from the SAME pinned
# upstream image the old service ran (alexxit/go2rtc:1.9.14) — no network
# download, no checksum management; bump the tag deliberately and re-test.
# The binary is a static musl build, so it runs fine on bookworm-slim. Config
# comes from the compose mount ./go2rtc/go2rtc.yaml:/config/go2rtc.yaml:ro.
COPY --from=alexxit/go2rtc:1.9.14 /usr/local/bin/go2rtc /usr/local/bin/go2rtc

# Copy the entrypoint script.
COPY services/recorder/entrypoint.sh /usr/local/bin/entrypoint.sh

# Create default data mount points (compose mounts override these).
RUN mkdir -p /data/live /data/archive

# Container runs as non-root where possible.
# The NVIDIA 'video' capability does NOT require root — only the nvidia runtime.
RUN groupadd --gid 1001 crumb \
    && useradd --uid 1001 --gid 1001 --no-create-home crumb \
    && chown -R crumb:crumb /data \
    && chmod +x /usr/local/bin/entrypoint.sh

USER crumb

# Default environment (overridden by docker-compose.yml / .env).
# MOTION_HWACCEL defaults to 'auto': the recorder probes for NVDEC and falls back
# to CPU when no GPU is present, so this image boots GPU-free. Force NVDEC with the
# GPU overlay (docker-compose.gpu.example.yml) or MOTION_HWACCEL=cuda.
ENV LOG_FORMAT=json \
    RUST_LOG=info \
    SEGMENT_SECONDS=4 \
    MOTION_HWACCEL=auto \
    MAX_GPU_DECODE_SESSIONS=4 \
    CONFIG_POLL_SECONDS=30 \
    MEDIA_ROOT=/data \
    LIVE_STORAGE_PATH=/data/live \
    ARCHIVE_STORAGE_PATH=/data/archive \
    LIVE_STORAGE_NAME=Live \
    ARCHIVE_STORAGE_NAME=Archive

# The entrypoint runs `seed` (idempotent) then launches the supervisor.
# This satisfies the correctness requirement that seed runs on every container
# start without the operator having to orchestrate it separately.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["crumb-recorder"]
