// SPDX-License-Identifier: AGPL-3.0-or-later

//! Detection-event plugin implementations for the Crumb API.
//!
//! This module is compiled only when the `detection` feature is enabled
//! (the default).  When `FRIGATE_MQTT_URL` is unset at runtime, no provider
//! is instantiated, no background task runs, and the events table stays empty.
//!
//! # Sub-modules
//!
//! * [`frigate`] — Frigate MQTT + HTTP backfill provider.

#[cfg(feature = "detection")]
pub mod frigate;
