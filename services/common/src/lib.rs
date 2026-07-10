// SPDX-License-Identifier: AGPL-3.0-or-later

//! `crumb-common` — shared types, configuration, database access, and
//! logging for the Crumb NVR recorder service.
//!
//! # Crate layout
//!
//! | Module | Contents |
//! |---|---|
//! | [`types`] | Domain types mirroring the PostgreSQL schema exactly. |
//! | [`config`] | Environment-variable driven [`Config`](config::Config). |
//! | [`db`] | deadpool-postgres pool creation and typed query accessors. |
//! | [`icons`] | Shared storage/camera glyph resolution (override → name/type). |
//! | [`logging`] | Global tracing subscriber initialisation. |
//! | [`detection`] | Pluggable detection-event framework ([`DetectionSource`] trait + types). |

// Several enums expose an inherent `from_str(&str) -> Option<Self>` that parses a
// wire/DB token into the enum. This is a deliberate, readable convention (it
// returns Option, not the trait's Result, and needs no `use std::str::FromStr`),
// so silence clippy's suggestion to implement the FromStr trait instead.
#![allow(clippy::should_implement_trait)]

pub mod config;
pub mod db;
pub mod detection;
pub mod ha;
pub mod icons;
pub mod logging;
pub mod redact;
pub mod types;

// ── flat re-exports for ergonomic use in services/recorder ───────────────────

pub use config::Config;
pub use types::{
    Camera, FrigateSettings, MotionSensitivity, MotionSignal, RecordStream, RecordingMode,
    RecordingPolicy, Segment, SegmentStage, SegmentStream, ServerSettings, Storage,
    StorageMigration, User, UserRole,
};

// ── detection re-exports ──────────────────────────────────────────────────────

pub use detection::{
    icon_key_for_label, BoundingBox, DetectionLabel, DetectionSource, EventLifecycle,
    NormalizedEvent,
};
