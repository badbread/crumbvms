# Crumb NVR — API service
#
# Build context: REPO ROOT (not this directory).
# docker-compose.yml must set:
#   build:
#     context: .
#     dockerfile: services/api/Dockerfile
#
# The Cargo workspace root (Cargo.toml + Cargo.lock) lives at the repo root;
# services/common is a shared workspace member that services/api depends on.
#
# Two-stage build:
#   builder  — compiles the Rust workspace in release mode on bookworm.
#   runtime  — minimal bookworm-slim image + jellyfin-ffmpeg (for export transcoding).
#
# The API container mounts the SAME broad media root (/data) as the recorder, but
# READ-ONLY.  It never writes to the recording directories. Export output is
# written to a separate /data/exports volume (rw).

# ─── stage 1: build ──────────────────────────────────────────────────────────

FROM rust:1-bookworm AS builder

WORKDIR /build

# Build dependencies (openssl needed by some transitive deps).
RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy workspace manifests for layer caching.
COPY Cargo.toml Cargo.lock ./
COPY services/common/Cargo.toml  services/common/Cargo.toml
COPY services/recorder/Cargo.toml services/recorder/Cargo.toml
COPY services/api/Cargo.toml      services/api/Cargo.toml

# Create stub sources so cargo can resolve the dependency graph without
# the real source files (maximises cache hit on dep-only changes).
RUN mkdir -p \
        services/common/src \
        services/recorder/src/bin \
        services/api/src \
    && echo 'pub fn _stub() {}' > services/common/src/lib.rs \
    && echo 'fn main() {}' > services/recorder/src/main.rs \
    && echo 'fn main() {}' > services/recorder/src/bin/seed.rs \
    && echo 'fn main() {}' > services/api/src/main.rs

RUN cargo build --release --workspace \
    && rm -rf services/common/src services/recorder/src services/api/src

# Copy real source and rebuild (only changed crates recompile).
COPY services/common/src  services/common/src
COPY services/recorder/src services/recorder/src
COPY services/api/src      services/api/src

# The API embeds the product version at compile time via
# include_str!("../../../VERSION"); the file must exist in the build context.
COPY VERSION ./

# crumb-common's run_migrations embeds db/migrations/*.sql at compile time via
# include_str!("../../../db/migrations/…"); the dir must be in the build context
# (the workspace build below compiles crumb-common).
COPY db/migrations ./db/migrations

# Touch source files so cargo detects the change vs the stub build above.
RUN touch services/common/src/lib.rs \
          services/recorder/src/main.rs \
          services/recorder/src/bin/seed.rs \
          services/api/src/main.rs

RUN cargo build --release --workspace

# ─── stage 2: runtime ────────────────────────────────────────────────────────

FROM debian:bookworm-slim AS runtime

# Install jellyfin-ffmpeg (ships modern ffmpeg with NVENC/NVDEC + libx264 etc.).
# The API uses ffmpeg only for export transcoding (not live recording decode).
# postgresql-client-16 comes from the PGDG repo (bookworm ships client 15, and
# pg_dump refuses to dump a NEWER server major, so the client must match the
# bundled postgres:16). Used by the built-in nightly DB backup (db_backup.rs).
# ~15 MB installed — much smaller than the separate sidecar image it replaces.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
    && curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/jellyfin.gpg] \
        https://repo.jellyfin.org/debian bookworm main" \
        > /etc/apt/sources.list.d/jellyfin.list \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] \
        http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        jellyfin-ffmpeg7 \
        postgresql-client-16 \
    && rm -rf /var/lib/apt/lists/*

# Symlink jellyfin-ffmpeg into PATH so the export handler can call `ffmpeg`.
RUN ln -sf /usr/lib/jellyfin-ffmpeg/ffmpeg  /usr/local/bin/ffmpeg \
    && ln -sf /usr/lib/jellyfin-ffmpeg/ffprobe /usr/local/bin/ffprobe

# Copy the compiled binary from the builder stage.
COPY --from=builder /build/target/release/crumb-api /usr/local/bin/crumb-api

# Create mount points and export output directory.
# Compose mounts the broad media root /data READ-ONLY (same bind as recorder).
# /data/exports is an API-owned rw volume.
RUN mkdir -p /data/live /data/archive /data/exports

# Run as a non-root crumb user.
RUN groupadd --gid 1001 crumb \
    && useradd --uid 1001 --gid 1001 --no-create-home crumb \
    && chown -R crumb:crumb /data

USER crumb

# Default environment (overridden by docker-compose.yml / .env).
# Streaming bases are intentionally NOT defaulted here (no host IPs baked into the
# image). They come from the admin "Server & streaming" settings, falling back to
# the compose env (internal docker service names) — see docker-compose.yml.
ENV LOG_FORMAT=json \
    RUST_LOG=info \
    API_BIND=0.0.0.0:8080 \
    MEDIA_ROOT=/data \
    LIVE_STORAGE_PATH=/data/live \
    ARCHIVE_STORAGE_PATH=/data/archive \
    EXPORT_DIR=/data/exports \
    EXPORT_TTL_SECONDS=86400 \
    JWT_EXPIRY_SECONDS=86400

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/crumb-api"]
