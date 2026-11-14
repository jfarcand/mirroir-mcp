// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The listen tool's logic: record what the target app plays, transcribe it on the Mac, word the answer.
// ABOUTME: Stops early on silence (nothing playing, or the sound ended); the audio file is deleted once read.

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

    /// What listening produced: the text for the agent, and whether it is an error.
    struct Outcome: Equatable {
        let text: String
        let isError: Bool
    }

    /// Record up to `seconds` of what the target's app plays and transcribe it
    /// in `language`, or in `fallbackLanguage` (the Mac's) when none is given.
    /// The recording stops early on `stopRule`: below its silence peak the
    /// sound is taken as silence, so a paused video or a muted phone is said
    /// to be quiet, not transcribed as empty speech.
    static func listen(
        bridge: any WindowBridging,
        seconds: Double,
        language: String?,
        capturer: any AppAudioCapturing,
        transcriber: any SpeechTranscribing,
        fallbackLanguage: String = Locale.current.identifier(.bcp47),
        stopRule: ListenStopRule = .fromSettings
    ) -> Outcome {
        guard let pid = bridge.getWindowInfo()?.pid ?? bridge.findProcess()?.processIdentifier else {
            return Outcome(text: "'\(bridge.targetName)' is not running, so there is nothing to listen to.",
                           isError: true)
        }
        let spoken = language.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLanguage
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirroir-listen-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }

        let length: String
        let ending: String
        switch capturer.captureAudio(pid: pid, seconds: seconds, stopRule: stopRule, to: file) {
        case .appNotShareable:
            return Outcome(text: "'\(bridge.targetName)' is not available for audio capture. Check that it is "
                + "running and that Screen Recording is granted (run check_health).", isError: true)
        case .failed(let message):
            return Outcome(text: "Listening failed: \(message).", isError: true)
        case .recorded(_, let recorded, .silentStart):
            return Outcome(text: "Nothing is playing: \(format(recorded)) of silence from the start, so "
                + "listening stopped early. Is the video muted or paused, or the phone silenced? Start the "
                + "sound, then listen again.", isError: false)
        case .recorded(let peak, _, .fullLength) where peak < stopRule.silencePeak:
            return Outcome(text: "Nothing played during the \(format(seconds)): the video may be paused, the phone "
                + "muted, or the sound not started yet. Start it, then listen again.", isError: false)
        case .recorded(_, let recorded, .soundEnded):
            length = format(recorded)
            ending = " (stopped after \(format(stopRule.trailingSilence)) of silence: the sound had ended)"
        case .recorded(_, _, .fullLength):
            length = format(seconds)
            ending = ""
        }

        switch transcriber.transcribe(file: file, language: spoken) {
        case .text(let words, let used, _) where words.isEmpty:
            return Outcome(text: "Sound played during the \(length), but no speech was recognized in \(used). "
                + "It may be music, or speech in another language: pass language, e.g. \"fr-CA\".",
                           isError: false)
        case .text(let words, let used, let engine):
            return Outcome(text: "Heard during the \(length)\(ending), transcribed on this Mac in \(used) by the "
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

    /// `seconds` as the reply says it: whole seconds plainly, else to a tenth.
    static func format(_ seconds: Double) -> String {
        let tenths = (seconds * 10).rounded() / 10
        return tenths == tenths.rounded() ? "\(Int(tenths)) s" : String(format: "%.1f s", tenths)
    }
}
