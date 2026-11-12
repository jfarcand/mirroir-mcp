// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Speaks a sentence from FakeMirroring's own process when a test asks, so `listen` has real sound to hear.
// ABOUTME: Synthesizes into buffers and plays them through this app's audio engine, not the system speech daemon.

import AVFoundation
import Foundation

/// Plays speech as the iPhone Mirroring app plays a video's sound: from the app itself.
///
/// A test posts the distributed notification `speakNotification` with the
/// sentence under `textKey`. `AVSpeechSynthesizer.speak` would play from the
/// speech daemon, a different process that a capture of this app does not
/// hear, so the speech is written into buffers and played by this app's own
/// `AVAudioEngine`.
@MainActor
final class FakeSpeaker {

    /// The distributed notification that asks FakeMirroring to speak.
    nonisolated static let speakNotification = Notification.Name("com.jfarcand.FakeMirroring.speak")

    /// The `userInfo` key holding the sentence.
    nonisolated static let textKey = "text"

    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?

    init() {
        engine.attach(player)
        DistributedNotificationCenter.default().addObserver(
            forName: Self.speakNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let text = note.userInfo?[Self.textKey] as? String, !text.isEmpty else { return }
            MainActor.assumeIsolated { self?.speak(text) }
        }
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            DispatchQueue.main.async { self?.play(pcm) }
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        if connectedFormat != buffer.format {
            engine.stop()
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            connectedFormat = buffer.format
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                FileHandle.standardError.write(Data("[FakeMirroring] audio engine failed: \(error)\n".utf8))
                return
            }
        }
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }
}
