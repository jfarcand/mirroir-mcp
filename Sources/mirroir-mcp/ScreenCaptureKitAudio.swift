// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Records the sound one app plays, and only that app, with a ScreenCaptureKit audio stream, stopping early on silence.
// ABOUTME: Measured on macOS 26.5: iPhone Mirroring's audio arrives whole even with the Mac's output muted.

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Production `AppAudioCapturing`.
///
/// An `SCStream` filtered to one application delivers that application's
/// audio only. It needs the Screen & System Audio Recording grant mirroir
/// already holds for screenshots, and nothing else. A stream must carry video
/// too, so it asks for the smallest frame at one frame per second and ignores it.
struct ScreenCaptureKitAudio: Sendable {

    /// Sample rate of the recording: what ScreenCaptureKit delivers natively.
    static let sampleRate = 48_000

    /// Extra time allowed past the requested length for the stream to start and stop.
    static let overhead: TimeInterval = 10

    /// How often the recording checks whether its stop rule has ended it, in
    /// nanoseconds: a tenth of a second, short next to any silence it waits for.
    static let stopCheckNanoseconds: UInt64 = 100_000_000

    func captureAudio(pid: pid_t, seconds: Double, stopRule: ListenStopRule, to file: URL) -> AudioCaptureReply {
        let done = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        Task.detached {
            box.set(await Self.record(pid: pid, seconds: seconds, stopRule: stopRule, to: file))
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds + Self.overhead) == .success else {
            return .failed("the audio stream did not finish within \(Int(seconds + Self.overhead)) s")
        }
        return box.value ?? .failed("the audio stream gave no answer")
    }

    private static func record(
        pid: pid_t, seconds: Double, stopRule: ListenStopRule, to file: URL
    ) async -> AudioCaptureReply {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            return .failed("no shareable content: \(error.localizedDescription)")
        }
        guard let app = content.applications.first(where: { $0.processID == pid }),
              let display = content.displays.first else {
            return .appNotShareable
        }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = sampleRate
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let sink = AudioFileSink(file: file, stopRule: stopRule)
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline, !sink.hasEnded {
                try await Task.sleep(nanoseconds: stopCheckNanoseconds)
            }
            try await stream.stopCapture()
        } catch {
            return .failed("the audio stream failed: \(error.localizedDescription)")
        }
        return sink.finish()
    }
}

/// Writes the audio buffers of one stream to a file and feeds each buffer's
/// loudest sample to a `ListenStopTracker`. Buffers after the tracker has ended
/// the recording are dropped.
private final class AudioFileSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "mirroir.listen.audio")
    private let url: URL
    private var file: AVAudioFile?
    private var tracker: ListenStopTracker
    private var end: RecordingEnd?
    private var failure: String?

    init(file: URL, stopRule: ListenStopRule) {
        self.url = file
        self.tracker = ListenStopTracker(rule: stopRule)
    }

    /// Whether the stop rule has ended the recording.
    var hasEnded: Bool { queue.sync { end != nil } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, failure == nil, end == nil,
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr
        else { return }
        var bufferPeak: Float = 0
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for index in 0..<Int(frames) { bufferPeak = max(bufferPeak, abs(channels[channel][index])) }
            }
        }
        do {
            if file == nil { file = try AVAudioFile(forWriting: url, settings: format.settings) }
            try file?.write(from: buffer)
        } catch {
            failure = "the audio could not be written: \(error.localizedDescription)"
        }
        end = tracker.add(bufferPeak: bufferPeak, seconds: Double(frames) / format.sampleRate)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async { self.failure = self.failure ?? "the audio stream stopped: \(error.localizedDescription)" }
    }

    /// The reply, once the stream has stopped: buffers still queued are written first.
    func finish() -> AudioCaptureReply {
        queue.sync {
            file = nil
            if let failure { return .failed(failure) }
            return .recorded(peak: tracker.peak, seconds: tracker.recorded, end: end ?? .fullLength)
        }
    }
}

/// The reply handed from the capture task to the waiting thread.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AudioCaptureReply?

    var value: AudioCaptureReply? { lock.withLock { stored } }

    func set(_ reply: AudioCaptureReply) { lock.withLock { stored = reply } }
}
