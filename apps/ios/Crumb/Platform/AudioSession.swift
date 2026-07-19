// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
#if os(iOS)
import AVFoundation
#endif

/// Refcounted `.playback` audio-session activation, shared by the two places that
/// can produce sound: live (`Fmp4StreamController`'s audio renderer) and recorded
/// playback (`SegmentPlayer`'s `AVQueuePlayer`).
///
/// Why this exists: without an explicitly-`.playback` `AVAudioSession`, an unmuted
/// player runs under the default (`.soloAmbient`) category — silenced by the ring
/// switch and ducked/pausing on interruptions. A camera operator who taps "listen"
/// expects to actually hear the feed. We only ever request **playback**, never the
/// mic — Crumb is a viewer and must never prompt for microphone access (the reason
/// the WebRTC live path deliberately negotiates video-only; see `WebRTCManager`).
///
/// Refcounted because live audio and playback audio can be active independently;
/// the session stays up while either holds a reference and is torn down (notifying
/// other apps so their audio resumes) only when the last one releases.
///
/// On macOS there is no `AVAudioSession`, so every call is a no-op — the OS mixes
/// app audio without an explicit session.
@MainActor
enum CrumbAudioSession {

    private static var refcount = 0

    /// Activate the shared `.playback` session. Balanced by `release()`.
    static func acquire() {
        refcount += 1
        guard refcount == 1 else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // `.playback` + `.moviePlayback`: plays through the speaker regardless of
        // the ring switch, which is what "listen to this camera" should do.
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        #endif
    }

    /// Release one reference; deactivates the session when the count hits zero.
    static func release() {
        guard refcount > 0 else { return }
        refcount -= 1
        guard refcount == 0 else { return }
        #if os(iOS)
        // `.notifyOthersOnDeactivation`: let any app we interrupted (e.g. music)
        // resume once Crumb stops producing sound.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}
