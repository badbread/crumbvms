// SPDX-License-Identifier: AGPL-3.0-or-later

//! Tracing / logging initialisation.
//!
//! Call [`init`] exactly once at process startup, before spawning any tasks.
//!
//! ## Format selection
//!
//! | `LOG_FORMAT` env var | Output |
//! |---|---|
//! | `json` (default) | Newline-delimited JSON — structured, machine-readable, correct for production Docker / log aggregators. |
//! | `pretty` | Human-readable ANSI coloured output for local development. |
//!
//! ## Level selection
//!
//! The filter is read from `RUST_LOG` first; if absent, from `LOG_LEVEL`;
//! if both absent, defaults to `info`.
//!
//! # Example
//!
//! ```no_run
//! crumb_common::logging::init();
//! tracing::info!("Crumb recorder starting");
//! ```

use std::env;
use tracing_subscriber::{fmt, EnvFilter};

/// Initialise the global tracing subscriber.
///
/// Safe to call multiple times in tests (each call after the first is a no-op
/// because `try_init()` silently fails on a second registration).
pub fn init() {
    let filter = build_filter();
    let format = env::var("LOG_FORMAT").unwrap_or_else(|_| "json".to_owned());

    // Use json or pretty depending on LOG_FORMAT.
    // We construct the subscriber inline for each branch rather than boxing the
    // layer, keeping the types concrete and avoiding dynamic dispatch.
    if format.eq_ignore_ascii_case("pretty") {
        let _ = fmt::Subscriber::builder()
            .with_env_filter(filter)
            .with_target(true)
            .with_thread_ids(true)
            .with_line_number(true)
            .try_init();
    } else {
        let _ = fmt::Subscriber::builder()
            .json()
            .with_env_filter(filter)
            .with_current_span(true)
            .with_span_list(true)
            .try_init();
    }
}

fn build_filter() -> EnvFilter {
    // Priority: RUST_LOG → LOG_LEVEL → "info"
    let directive = env::var("RUST_LOG")
        .or_else(|_| env::var("LOG_LEVEL"))
        .unwrap_or_else(|_| "info".to_owned());

    EnvFilter::try_new(&directive).unwrap_or_else(|e| {
        eprintln!("warn: invalid log filter '{directive}': {e} — defaulting to 'info'");
        EnvFilter::new("info")
    })
}
