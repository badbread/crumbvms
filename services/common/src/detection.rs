// SPDX-License-Identifier: AGPL-3.0-or-later

//! Detection-event plugin framework for Crumb NVR.
//!
//! This module defines the [`DetectionSource`] trait and the canonical
//! [`NormalizedEvent`] type that all providers emit.  The first concrete
//! implementation is [`FrigateProvider`] (in `services/api/src/detection/`),
//! but the trait boundary lives here in `crumb-common` so downstream crates
//! can implement additional providers without depending on the API crate.
//!
//! # Design
//!
//! * [`DetectionSource`] is an `async_trait` — each provider owns its own
//!   reconnection loop and pushes events onto an `mpsc::Sender<NormalizedEvent>`.
//! * [`NormalizedEvent`] is the canonical envelope; all provider-specific fields
//!   are captured verbatim in `raw` (`serde_json::Value`).
//! * [`DetectionLabel`] is a closed enum for well-known object classes with an
//!   `Other(String)` variant for everything the enum does not cover.
//! * [`EventLifecycle`] mirrors Frigate's `"new" | "update" | "end"` but is
//!   source-agnostic.
//! * [`BoundingBox`] carries normalised `[0, 1]` coordinates (future Phase 2).
//!
//! # Runtime gate
//!
//! The API binary gates all detection code behind a check for `FRIGATE_MQTT_URL`.
//! When that variable is absent **nothing in this module is instantiated**; the
//! events table stays empty and the build is identical.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use uuid::Uuid;

// ── trait ─────────────────────────────────────────────────────────────────────

/// A pluggable detection-event source.
///
/// Implementors subscribe to an upstream event stream (MQTT, HTTP long-poll,
/// WebSocket, …) and push normalised events onto the provided channel.
/// Internal reconnection and backoff are the implementor's responsibility;
/// `start` should only return `Err` on a fatal, unrecoverable startup failure.
///
/// Graceful teardown via `stop` must complete within 5 s.
#[async_trait::async_trait]
pub trait DetectionSource: Send + Sync {
    /// Stable identifier used in logs and metrics, e.g. `"frigate"`.
    fn id(&self) -> &'static str;

    /// Start consuming events and forward [`NormalizedEvent`]s onto `tx`.
    ///
    /// This method drives an internal loop; it should only return when the
    /// source has been asked to stop (via [`Self::stop`]) or encounters a
    /// fatal error.  Transient failures (network drops, broker restarts) must
    /// be handled internally with exponential back-off.
    ///
    /// # Errors
    ///
    /// Returns [`anyhow::Error`] only on fatal startup failures that prevent
    /// even the first connection attempt.
    async fn start(&self, tx: mpsc::Sender<NormalizedEvent>) -> anyhow::Result<()>;

    /// Request graceful shutdown.  Must complete within 5 seconds.
    ///
    /// # Errors
    ///
    /// Returns [`anyhow::Error`] if the stop signal could not be delivered.
    async fn stop(&self) -> anyhow::Result<()>;

    /// Return `true` when the upstream connection is healthy.
    ///
    /// Used by `/status` to expose detection-provider health alongside the
    /// recorder heartbeat.  May return `false` transiently during reconnection.
    fn is_healthy(&self) -> bool;
}

// ── NormalizedEvent ───────────────────────────────────────────────────────────

/// Canonical detection event envelope emitted by every [`DetectionSource`].
///
/// Instances are pushed onto the `mpsc` channel by a provider and consumed by
/// the `detection_ingester` background task in `services/api`.
#[derive(Debug, Clone)]
pub struct NormalizedEvent {
    /// Source identifier matching the provider's [`DetectionSource::id`],
    /// e.g. `"frigate"`.
    pub source_id: String,

    /// Crumb camera UUID resolved by the provider from `source_camera_name`.
    pub camera_id: Uuid,

    /// The provider's own stable event ID used for deduplication.
    ///
    /// The upsert uses `(source_id, provider_event_id)` as the unique key, so
    /// replaying the same event is idempotent.
    pub provider_event_id: String,

    /// Phase of the event in the object's tracking lifecycle.
    pub lifecycle: EventLifecycle,

    /// Classified object type.
    pub label: DetectionLabel,

    /// Provider-supplied sub-label (e.g. plate number or person name).
    pub sub_label: Option<String>,

    /// Detection confidence at the moment this event was emitted (`0.0..=1.0`).
    pub score: f32,

    /// Highest confidence score observed over this object's lifetime.
    pub top_score: f32,

    /// Wall-clock UTC when the object was first detected.
    pub start_ts: DateTime<Utc>,

    /// Wall-clock UTC when tracking ended.  `None` while still in progress.
    pub end_ts: Option<DateTime<Utc>>,

    /// Normalised bounding box in `[0, 1]` frame coordinates.
    ///
    /// `None` in Phase 1 (pixel coordinates require frame-dimension lookup for
    /// normalisation; deferred to Phase 2).
    pub bounding_box: Option<BoundingBox>,

    /// Zone names the object occupied at detection time.
    pub zones: Vec<String>,

    /// Provider URL for the detection snapshot JPEG, proxied by the API.
    ///
    /// Clients never talk to the provider directly; they fetch
    /// `GET /events/{id}/snapshot` which proxies this URL.
    pub snapshot_url: Option<String>,

    /// Full vendor payload preserved verbatim as JSONB.
    ///
    /// Used for debugging and future provider-specific feature extraction
    /// without requiring a schema migration.
    pub raw: serde_json::Value,
}

// ── EventLifecycle ────────────────────────────────────────────────────────────

/// Tracking-lifecycle phase of a detection event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EventLifecycle {
    /// Object first detected.
    Start,
    /// Tracking updated (e.g. snapshot became available).
    Update,
    /// Tracking ended.
    End,
}

impl EventLifecycle {
    /// Serialise to the `text` value stored in the `lifecycle` column.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Start => "start",
            Self::Update => "update",
            Self::End => "end",
        }
    }
}

// ── DetectionLabel ────────────────────────────────────────────────────────────

/// Canonical object-class labels understood by Crumb.
///
/// The `Other(String)` variant captures any label not in the closed set so
/// new Frigate classes (or classes from future providers) are preserved rather
/// than dropped.
///
/// # `icon_key` mapping (CONTRACT)
///
/// Clients use `icon_key` to select the glyph and colour to draw on the
/// timeline.  As of the per-label icon set, `icon_key` is **per-label** — it is
/// identical to [`DetectionLabel::as_str`] for the named variants and the held
/// slug for `Other(_)`.  The method is retained for contract stability and so
/// downstream code keeps a single, named entry point for "the client glyph key".
///
/// | label | icon_key |
/// |---|---|
/// | `Person` | `"person"` |
/// | `Car` | `"car"` |
/// | `Truck` | `"truck"` |
/// | `Bus` | `"bus"` |
/// | `Bicycle` | `"bicycle"` |
/// | `Motorcycle` | `"motorcycle"` |
/// | `Cat` | `"cat"` |
/// | `Dog` | `"dog"` |
/// | `Bird` | `"bird"` |
/// | `Horse` | `"horse"` |
/// | `LicensePlate` | `"license_plate"` |
/// | `Face` | `"face"` |
/// | `Package` | `"package"` |
/// | `Other(s)` | `s` (the held slug, e.g. `"ufo"`) |
///
/// Clients map each `icon_key` to a designed glyph; an unknown key falls back
/// to a generic marker.  The canonical key for a number plate is
/// `"license_plate"` (the `licence_plate` / `plate` aliases all normalise to it
/// in [`DetectionLabel::from_str`] and [`icon_key_for_label`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DetectionLabel {
    Person,
    Car,
    Truck,
    Bus,
    Bicycle,
    Motorcycle,
    Cat,
    Dog,
    Bird,
    Horse,
    LicensePlate,
    Face,
    Package,
    Other(String),
}

impl DetectionLabel {
    /// Parse a label string from the provider (case-insensitive).
    ///
    /// Unknown strings are wrapped in [`DetectionLabel::Other`].
    #[must_use]
    pub fn from_str(s: &str) -> Self {
        match s.to_ascii_lowercase().as_str() {
            "person" => Self::Person,
            "car" => Self::Car,
            "truck" => Self::Truck,
            "bus" => Self::Bus,
            "bicycle" => Self::Bicycle,
            "motorcycle" | "motorbike" => Self::Motorcycle,
            "cat" => Self::Cat,
            "dog" => Self::Dog,
            "bird" => Self::Bird,
            "horse" => Self::Horse,
            "license_plate" | "licence_plate" | "plate" => Self::LicensePlate,
            "face" => Self::Face,
            "package" => Self::Package,
            other => Self::Other(other.to_owned()),
        }
    }

    /// Serialise to the lowercase string stored in the `label` column.
    #[must_use]
    pub fn as_str(&self) -> &str {
        match self {
            Self::Person => "person",
            Self::Car => "car",
            Self::Truck => "truck",
            Self::Bus => "bus",
            Self::Bicycle => "bicycle",
            Self::Motorcycle => "motorcycle",
            Self::Cat => "cat",
            Self::Dog => "dog",
            Self::Bird => "bird",
            Self::Horse => "horse",
            Self::LicensePlate => "license_plate",
            Self::Face => "face",
            Self::Package => "package",
            Self::Other(s) => s.as_str(),
        }
    }

    /// The icon key used by all three clients to look up glyph + colour.
    ///
    /// This is the CONTRACT value included in every `/events` response.  It is
    /// **per-label**: identical to [`Self::as_str`] for the named variants, and
    /// the held slug for [`Self::Other`].  The method is kept distinct from
    /// `as_str` for contract clarity — callers that mean "client glyph key"
    /// should use `icon_key`.
    ///
    /// Because [`Self::Other`] borrows its slug from `self`, the return type is
    /// `&str` (a borrow into `self`), not `&'static str`.
    ///
    /// ```
    /// use crumb_common::detection::DetectionLabel;
    ///
    /// assert_eq!(DetectionLabel::Person.icon_key(), "person");
    /// assert_eq!(DetectionLabel::Car.icon_key(), "car");
    /// assert_eq!(DetectionLabel::Truck.icon_key(), "truck");
    /// assert_eq!(DetectionLabel::Bus.icon_key(), "bus");
    /// assert_eq!(DetectionLabel::Bicycle.icon_key(), "bicycle");
    /// assert_eq!(DetectionLabel::Motorcycle.icon_key(), "motorcycle");
    /// assert_eq!(DetectionLabel::Cat.icon_key(), "cat");
    /// assert_eq!(DetectionLabel::Dog.icon_key(), "dog");
    /// assert_eq!(DetectionLabel::Bird.icon_key(), "bird");
    /// assert_eq!(DetectionLabel::Horse.icon_key(), "horse");
    /// assert_eq!(DetectionLabel::LicensePlate.icon_key(), "license_plate");
    /// assert_eq!(DetectionLabel::Face.icon_key(), "face");
    /// assert_eq!(DetectionLabel::Package.icon_key(), "package");
    /// assert_eq!(DetectionLabel::Other("ufo".to_owned()).icon_key(), "ufo");
    /// ```
    #[must_use]
    pub fn icon_key(&self) -> &str {
        // Per-label contract: the glyph key is the label slug itself.
        self.as_str()
    }
}

/// Derive the per-label `icon_key` from a raw label string (convenience wrapper
/// used by the DB query layer where we have the raw text column value, not a
/// typed enum).
///
/// The input is normalised (trimmed + ASCII-lowercased) and the
/// `licence_plate` / `plate` aliases are folded onto the canonical
/// `"license_plate"` slug, consistent with [`DetectionLabel::from_str`].  An
/// unrecognised label returns its own normalised slug (the `Other` slug), so
/// every distinct label yields a distinct key.
///
/// Returns an owned [`String`] because, under the per-label contract, the key
/// for an `Other` label is the (owned, normalised) label text and is not
/// `'static`.
///
/// ```
/// use crumb_common::detection::icon_key_for_label;
///
/// assert_eq!(icon_key_for_label("person"), "person");
/// assert_eq!(icon_key_for_label("truck"), "truck");
/// assert_eq!(icon_key_for_label("dog"), "dog");
/// assert_eq!(icon_key_for_label("bicycle"), "bicycle");
/// assert_eq!(icon_key_for_label("license_plate"), "license_plate");
/// assert_eq!(icon_key_for_label("plate"), "license_plate");
/// assert_eq!(icon_key_for_label("  Face  "), "face");
/// assert_eq!(icon_key_for_label("unknown_thing"), "unknown_thing");
/// ```
#[must_use]
pub fn icon_key_for_label(label: &str) -> String {
    DetectionLabel::from_str(label.trim()).icon_key().to_owned()
}

// ── BoundingBox ───────────────────────────────────────────────────────────────

/// Normalised bounding box in `[0, 1]` frame coordinates.
///
/// `x1, y1` is the top-left corner; `x2, y2` is the bottom-right corner.
/// All values are in the range `[0.0, 1.0]` where `(0, 0)` is the top-left
/// of the frame and `(1, 1)` is the bottom-right.
///
/// Phase 1 note: Frigate provides pixel coordinates `(x, y, w, h)`.
/// Normalisation requires the frame dimensions which are not yet available in
/// the ingester.  This type is reserved for Phase 2 when frame-dimension lookup
/// is added.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct BoundingBox {
    pub x1: f32,
    pub y1: f32,
    pub x2: f32,
    pub y2: f32,
}

// ── unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn label_from_str_known() {
        assert_eq!(DetectionLabel::from_str("person"), DetectionLabel::Person);
        assert_eq!(DetectionLabel::from_str("PERSON"), DetectionLabel::Person);
        assert_eq!(DetectionLabel::from_str("car"), DetectionLabel::Car);
        assert_eq!(DetectionLabel::from_str("truck"), DetectionLabel::Truck);
        assert_eq!(DetectionLabel::from_str("bus"), DetectionLabel::Bus);
        assert_eq!(DetectionLabel::from_str("bicycle"), DetectionLabel::Bicycle);
        assert_eq!(
            DetectionLabel::from_str("motorcycle"),
            DetectionLabel::Motorcycle
        );
        assert_eq!(
            DetectionLabel::from_str("motorbike"),
            DetectionLabel::Motorcycle
        );
        assert_eq!(DetectionLabel::from_str("cat"), DetectionLabel::Cat);
        assert_eq!(DetectionLabel::from_str("dog"), DetectionLabel::Dog);
        assert_eq!(DetectionLabel::from_str("bird"), DetectionLabel::Bird);
        assert_eq!(DetectionLabel::from_str("horse"), DetectionLabel::Horse);
        assert_eq!(
            DetectionLabel::from_str("license_plate"),
            DetectionLabel::LicensePlate
        );
        assert_eq!(
            DetectionLabel::from_str("licence_plate"),
            DetectionLabel::LicensePlate
        );
        assert_eq!(
            DetectionLabel::from_str("plate"),
            DetectionLabel::LicensePlate
        );
        assert_eq!(DetectionLabel::from_str("face"), DetectionLabel::Face);
    }

    #[test]
    fn label_from_str_unknown_becomes_other() {
        assert_eq!(
            DetectionLabel::from_str("ufo"),
            DetectionLabel::Other("ufo".to_owned())
        );
    }

    #[test]
    fn icon_key_mapping_contract() {
        // Per-label: every distinct label gets its own key (== as_str).
        assert_eq!(DetectionLabel::Person.icon_key(), "person");
        assert_eq!(DetectionLabel::Car.icon_key(), "car");
        assert_eq!(DetectionLabel::Truck.icon_key(), "truck");
        assert_eq!(DetectionLabel::Bus.icon_key(), "bus");
        assert_eq!(DetectionLabel::Bicycle.icon_key(), "bicycle");
        assert_eq!(DetectionLabel::Motorcycle.icon_key(), "motorcycle");
        assert_eq!(DetectionLabel::Cat.icon_key(), "cat");
        assert_eq!(DetectionLabel::Dog.icon_key(), "dog");
        assert_eq!(DetectionLabel::Bird.icon_key(), "bird");
        assert_eq!(DetectionLabel::Horse.icon_key(), "horse");
        assert_eq!(DetectionLabel::LicensePlate.icon_key(), "license_plate");
        assert_eq!(DetectionLabel::Face.icon_key(), "face");
        assert_eq!(DetectionLabel::Package.icon_key(), "package");
        assert_eq!(DetectionLabel::Other("ufo".to_owned()).icon_key(), "ufo");
    }

    #[test]
    fn icon_key_for_label_convenience() {
        assert_eq!(icon_key_for_label("person"), "person");
        assert_eq!(icon_key_for_label("truck"), "truck");
        assert_eq!(icon_key_for_label("dog"), "dog");
        assert_eq!(icon_key_for_label("bicycle"), "bicycle");
        assert_eq!(icon_key_for_label("license_plate"), "license_plate");
        // license-plate aliases fold onto the single canonical slug.
        assert_eq!(icon_key_for_label("plate"), "license_plate");
        assert_eq!(icon_key_for_label("licence_plate"), "license_plate");
        assert_eq!(icon_key_for_label("face"), "face");
        // normalisation: trim + lowercase.
        assert_eq!(icon_key_for_label("  Face  "), "face");
        // unknown labels keep their own slug (no longer collapsed to "generic").
        assert_eq!(icon_key_for_label("unknown_thing"), "unknown_thing");
    }

    #[test]
    fn lifecycle_as_str() {
        assert_eq!(EventLifecycle::Start.as_str(), "start");
        assert_eq!(EventLifecycle::Update.as_str(), "update");
        assert_eq!(EventLifecycle::End.as_str(), "end");
    }
}
