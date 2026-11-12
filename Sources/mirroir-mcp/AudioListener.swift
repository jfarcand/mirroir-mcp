// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The listen tool's logic: record what the target app plays, transcribe it on the Mac, word the answer.
// ABOUTME: Silence is reported as silence and the audio file is deleted once read; nothing leaves the Mac.

import Foundation

/// Hears what the target plays: a reel's narration, a voice message, a video.
///
/// The recording lives in a temporary file only as long as the transcription
/// takes. The reply holds the words, never the audio.
enum AudioListener {

    /// Shortest and longest recording, and the default.
    static let minSeconds = 1.0
    static let maxSeconds = 60.0
    static let defaultSeconds = 10.0

    /// Below this peak (about -40 dBFS) the recording is taken as silence, so a
    /// paused video or a muted phone is said to be quiet, not transcribed as
    /// empty speech. Measured on the XR: a reel's music peaked at 0.69, speech at 1.03.
    static let silencePeak: Float = 0.01

    /// What listening produced: the text for the agent, and whether it is an error.
    struct Outcome: Equatable {
        let text: String
        let isError: Bool
    }

    /// Record `seconds` of what the target's app plays and transcribe it in
    /// `language`, or in `fallbackLanguage` (the Mac's) when none is given.
    static func listen(
        bridge: any WindowBridging,
        seconds: Double,
        language: String?,
        capturer: any AppAudioCapturing,
        transcriber: any SpeechTranscribing,
        fallbackLanguage: String = Locale.current.identifier(.bcp47)
    ) -> Outcome {
        guard let pid = bridge.getWindowInfo()?.pid ?? bridge.findProcess()?.processIdentifier else {
            return Outcome(text: "'\(bridge.targetName)' is not running, so there is nothing to listen to.",
                           isError: true)
        }
        let spoken = language.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLanguage
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirroir-listen-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }

        let length = format(seconds)
        switch capturer.captureAudio(pid: pid, seconds: seconds, to: file) {
        case .appNotShareable:
            return Outcome(text: "'\(bridge.targetName)' is not available for audio capture. Check that it is "
                + "running and that Screen Recording is granted (run check_health).", isError: true)
        case .failed(let message):
            return Outcome(text: "Listening failed: \(message).", isError: true)
        case .recorded(let peak) where peak < silencePeak:
            return Outcome(text: "Nothing played during the \(length): the video may be paused, the phone "
                + "muted, or the sound not started yet. Start it, then listen again.", isError: false)
        case .recorded:
            break
        }

        switch transcriber.transcribe(file: file, language: spoken) {
        case .text(let words, let used, _) where words.isEmpty:
            return Outcome(text: "Sound played during the \(length), but no speech was recognized in \(used). "
                + "It may be music, or speech in another language: pass language, e.g. \"fr-CA\".",
                           isError: false)
        case .text(let words, let used, let engine):
            return Outcome(text: "Heard during the \(length), transcribed on this Mac in \(used) by the "
                + "\(engine) engine (words only, not who spoke):\n\(words)", isError: false)
        case .unsupportedLanguage(let asked):
            return Outcome(text: "No on-device speech model exists for '\(asked)'. Pass a language such as "
                + "\"en-US\" or \"fr-CA\".", isError: true)
        case .unavailable(let reason):
            return Outcome(text: "Listening is not available: \(reason).", isError: true)
        case .failed(let message):
            return Outcome(text: "Transcription failed: \(message).", isError: true)
        }
    }

    /// The length clamped to what `listen` accepts.
    static func clampedSeconds(_ requested: Double?) -> Double {
        min(max(requested ?? defaultSeconds, minSeconds), maxSeconds)
    }

    private static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }
}
