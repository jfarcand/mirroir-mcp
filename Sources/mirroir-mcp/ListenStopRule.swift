// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Decides when a listen recording stops early: nothing playing from the start, or silence once the sound ended.
// ABOUTME: Pure: fed the loudness and length of each audio buffer in order; ScreenCaptureKitAudio only feeds it.

import Foundation
import HelperLib

/// Why a recording stopped.
enum RecordingEnd: Sendable, Equatable {
    /// It ran the requested length.
    case fullLength
    /// Nothing louder than silence played during the first `silentStart` seconds.
    case silentStart
    /// Sound played, then `trailingSilence` seconds of silence followed it.
    case soundEnded
}

/// The thresholds a recording stops on, from settings.
struct ListenStopRule: Sendable, Equatable {
    /// Loudest sample still taken as silence.
    let silencePeak: Float
    /// Seconds of silence from the start that end the recording.
    let silentStart: Double
    /// Seconds of silence after sound that end the recording.
    let trailingSilence: Double

    /// The rule the settings name (`listenSilencePeak`, `listenSilentStartSeconds`,
    /// `listenTrailingSilenceSeconds`).
    static var fromSettings: ListenStopRule {
        ListenStopRule(silencePeak: Float(EnvConfig.listenSilencePeak),
                       silentStart: EnvConfig.listenSilentStartSeconds,
                       trailingSilence: EnvConfig.listenTrailingSilenceSeconds)
    }
}

/// Follows a recording buffer by buffer and says when it should stop.
///
/// Loudness alone decides: a reel whose music never pauses is never silent, so
/// it records its full length, even when it loops.
struct ListenStopTracker: Sendable {
    let rule: ListenStopRule

    /// Seconds recorded so far.
    private(set) var recorded: Double = 0
    /// Loudest sample so far.
    private(set) var peak: Float = 0
    /// Seconds of silence since the last buffer with sound, or since the start.
    private var quiet: Double = 0

    init(rule: ListenStopRule) {
        self.rule = rule
    }

    /// Add a buffer `seconds` long whose loudest sample is `bufferPeak`.
    /// Returns why the recording should stop now, or nil to keep recording.
    mutating func add(bufferPeak: Float, seconds: Double) -> RecordingEnd? {
        recorded += seconds
        peak = max(peak, bufferPeak)
        quiet = bufferPeak < rule.silencePeak ? quiet + seconds : 0
        let heardSound = peak >= rule.silencePeak
        if !heardSound, quiet >= rule.silentStart { return .silentStart }
        if heardSound, quiet >= rule.trailingSilence { return .soundEnded }
        return nil
    }
}
