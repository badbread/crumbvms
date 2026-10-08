// SPDX-License-Identifier: AGPL-3.0-or-later

//! The go2rtc stream definitions a Crumb-managed camera needs in order to
//! RECORD: its main stream and, when it has a sub source, its `<name>_sub`.
//!
//! Two processes register these streams with Crumb's own go2rtc: the api's
//! reconcile loop (`services/api/src/go2rtc.rs`, which also owns every derived
//! client-facing stream and all updates and removals) and the recorder's
//! create-if-missing fallback (`services/recorder/src/stream_registry.rs`, so a
//! go2rtc or recorder restart while the api is down still records). Both build
//! the definitions HERE so they are byte-identical: if the two ever disagreed,
//! each process would keep "correcting" the other's stream.
//!
//! Pure, no I/O.

use crate::db::CameraStream;

/// One go2rtc stream: its name and its producer source, exactly as sent to
/// go2rtc's `/api/streams?name=…&src=…`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamSpec {
    pub name: String,
    pub src: String,
}

/// A camera's recording streams (see the module doc).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordingStreams {
    /// `<go2rtc_name>` sourced from the camera's `source_url`.
    pub main: StreamSpec,
    /// `<go2rtc_name>_sub` sourced from `source_sub_url`, when that is set and
    /// not blank.
    pub sub: Option<StreamSpec>,
}

impl RecordingStreams {
    /// Main first, then sub when present.
    pub fn into_specs(self) -> Vec<StreamSpec> {
        let mut v = vec![self.main];
        v.extend(self.sub);
        v
    }
}

/// The go2rtc stream name for a camera's SUB stream.
pub fn sub_name(go2rtc_name: &str) -> String {
    format!("{go2rtc_name}_sub")
}

/// Build a camera's recording stream definitions. The sources are passed
/// through verbatim (go2rtc is the one that parses them); a sub source that is
/// blank or whitespace means "no sub".
pub fn recording_streams(cam: &CameraStream) -> RecordingStreams {
    let sub = cam
        .source_sub_url
        .as_deref()
        .filter(|u| !u.trim().is_empty())
        .map(|u| StreamSpec {
            name: sub_name(&cam.go2rtc_name),
            src: u.to_owned(),
        });
    RecordingStreams {
        main: StreamSpec {
            name: cam.go2rtc_name.clone(),
            src: cam.source_url.clone(),
        },
        sub,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn cam(name: &str, main: &str, sub: Option<&str>) -> CameraStream {
        CameraStream {
            id: Uuid::nil(),
            name: name.to_owned(),
            go2rtc_name: name.to_owned(),
            source_url: main.to_owned(),
            source_sub_url: sub.map(str::to_owned),
        }
    }

    #[test]
    fn main_and_sub_are_passed_through_verbatim() {
        let c = cam(
            "driveway",
            "rtsp://user:p%40ss@192.0.2.10:554/Streaming/Channels/101",
            Some("rtsp://user:p%40ss@192.0.2.10:554/Streaming/Channels/102"),
        );
        let s = recording_streams(&c);
        assert_eq!(s.main.name, "driveway");
        assert_eq!(s.main.src, c.source_url);
        let sub = s.sub.expect("sub present");
        assert_eq!(sub.name, "driveway_sub");
        assert_eq!(Some(sub.src.as_str()), c.source_sub_url.as_deref());
    }

    #[test]
    fn blank_or_missing_sub_means_no_sub() {
        for sub in [None, Some(""), Some("   ")] {
            let s = recording_streams(&cam("porch", "rtsp://192.0.2.11/s0", sub));
            assert!(s.sub.is_none(), "sub {sub:?} must not register a _sub");
            assert_eq!(s.into_specs().len(), 1);
        }
    }

    #[test]
    fn into_specs_orders_main_then_sub() {
        let specs = recording_streams(&cam(
            "yard",
            "rtsp://192.0.2.12/a",
            Some("rtsp://192.0.2.12/b"),
        ))
        .into_specs();
        let names: Vec<_> = specs.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, ["yard", "yard_sub"]);
    }
}
