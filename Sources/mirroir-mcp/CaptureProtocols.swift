// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: System-boundary protocols for what the target shows and plays: screenshot capture, window images,
// ABOUTME: recording, an app's audio, on-device speech-to-text, text recognition and the screen describers.

import AppKit
import CoreGraphics
import Foundation
import HelperLib

/// Bundled capture output: screenshot data + the window info used to capture it.
/// Eliminates redundant getWindowInfo() calls when the caller needs both.
struct CaptureResult: Sendable {
    let data: Data
    let info: WindowInfo
}

/// Abstracts screenshot capture from the mirroring window.
protocol ScreenCapturing: Sendable {
    /// Capture the target window returning screenshot data + window info in one call.
    /// Single source of truth — eliminates duplicate getWindowInfo() calls.
    func captureWithInfo() -> CaptureResult?
    /// Capture the target window and return raw PNG data.
    func captureData() -> Data?
    /// Capture the target window and return base64-encoded PNG.
    func captureBase64() -> String?
}

/// The answer to one window-image request.
enum WindowImageReply: Sendable {
    /// The window's pixels, PNG-encoded.
    case image(Data)
    /// The window is not in the shareable content (closed, or not capturable).
    case windowNotShareable
    /// The capture API reported an error (no Screen Recording permission, a
    /// window that cannot start a stream, ...).
    case failed(String)
}

/// Abstracts asynchronous capture of a single window's pixels by `CGWindowID`
/// (ScreenCaptureKit in production).
///
/// `reply` is called at most once. A provider that drops `reply` without
/// calling it is a failure the caller detects the moment the closure is
/// released, so it must not keep it alive past the request.
protocol WindowImageProviding: Sendable {
    func captureWindowImage(
        windowID: CGWindowID, reply: @escaping @Sendable (WindowImageReply) -> Void)
}

/// Abstracts video recording of the mirroring window.
protocol ScreenRecording: Sendable {
    func startRecording(outputPath: String?) -> String?
    func stopRecording() -> (filePath: String?, error: String?)
}

/// What one audio capture of an app produced.
enum AudioCaptureReply: Sendable, Equatable {
    /// The app's audio was written to the file; `peak` is the loudest sample
    /// (0 to about 1), so a silent capture can be told from a quiet one.
    case recorded(peak: Float)
    /// The app is not in the shareable content (not running, or not capturable).
    case appNotShareable
    /// The capture API reported an error (no Screen Recording grant, ...).
    case failed(String)
}

/// Abstracts capture of the sound one app plays (ScreenCaptureKit in
/// production): only that app's audio, whatever else the Mac plays, and
/// whether or not the Mac's output is muted.
protocol AppAudioCapturing: Sendable {
    /// Record `seconds` of the audio of the app with process `pid` into `file`.
    func captureAudio(pid: pid_t, seconds: Double, to file: URL) -> AudioCaptureReply
}

/// What one transcription produced.
enum TranscriptionReply: Sendable, Equatable {
    /// The words heard, in order (empty when nothing was said), the language
    /// they were read in and the on-device engine that read them.
    case text(String, language: String, engine: String)
    /// No on-device model exists for the language asked.
    case unsupportedLanguage(String)
    /// This macOS has no on-device transcriber.
    case unavailable(String)
    /// The transcriber failed.
    case failed(String)
}

/// Abstracts speech-to-text that runs on the Mac (SpeechAnalyzer in
/// production): the audio never leaves the machine.
protocol SpeechTranscribing: Sendable {
    /// Transcribe the speech in `file`, spoken in `language` (BCP-47, e.g. "fr-CA").
    func transcribe(file: URL, language: String) -> TranscriptionReply
}

/// Abstracts raw text recognition from a screenshot image.
/// Implementations produce `[RawTextElement]` in window-point space,
/// decoupling the OCR engine from the rest of the describe pipeline.
protocol TextRecognizing: Sendable {
    /// Recognize text elements in a screenshot.
    ///
    /// - Parameters:
    ///   - image: The raw screenshot as a `CGImage`.
    ///   - windowSize: Size of the target window in points (for coordinate scaling).
    ///   - contentBounds: Pixel-space rect from `ContentBoundsDetector`
    ///     (caller computes this before invoking).
    /// - Returns: Text elements with coordinates in window-point space. An empty
    ///   array means the image held no text.
    /// - Throws: `TextRecognitionError` when the engine itself failed, which is
    ///   a different answer from "no text" and must reach the caller as one.
    func recognizeText(
        in image: CGImage,
        windowSize: CGSize,
        contentBounds: CGRect
    ) throws -> [RawTextElement]
}

/// A text recognition engine failed to produce an answer.
///
/// Distinct from recognizing nothing: a blank screen legitimately yields zero
/// elements, while these cases mean the pipeline is broken and the caller is
/// looking at an absence of information rather than information about absence.
enum TextRecognitionError: Error, CustomStringConvertible {
    /// The Vision request failed, including after retry and CPU fallback.
    case visionRequestFailed(underlying: any Error)
    /// A backend inside a composite failed; the others may have succeeded.
    case backendFailed(name: String, underlying: any Error)

    var description: String {
        switch self {
        case .visionRequestFailed(let underlying):
            return "Vision text recognition failed: \(underlying)"
        case .backendFailed(let name, let underlying):
            return "\(name) failed: \(underlying)"
        }
    }
}

/// Abstracts OCR-based screen element detection.
protocol ScreenDescribing: Sendable {
    /// Describe the current screen.
    ///
    /// - Parameter settleTimeoutUs: How long to wait for two consecutive
    ///   identical frames before describing (0 describes the first frame).
    ///   Nil uses the describer's own policy: the vision describer settles,
    ///   because a transitional frame still bills a full model call; the local
    ///   OCR describer does not, because its callers poll with their own delays
    ///   and a stale frame only costs one more cheap describe.
    func describe(settleTimeoutUs: UInt32?) -> ScreenDescriber.DescribeResult?

    /// Describe the full page by scrolling through all viewports.
    /// Delegates to `CalibrationScroller.collectFullPage()` for element collection.
    ///
    /// - Parameters:
    ///   - input: Input provider for scroll gestures.
    ///   - bridge: Window bridge for getting window dimensions.
    ///   - maxScrolls: Maximum number of scroll attempts.
    /// - Returns: The scroll result with all unique elements, or nil if OCR failed.
    func describeFullPage(
        input: any InputProviding,
        bridge: any WindowBridging,
        maxScrolls: Int
    ) -> CalibrationScroller.ScrollResult?
}

extension ScreenDescribing {
    /// Describe the current screen with the describer's own settle policy.
    func describe() -> ScreenDescriber.DescribeResult? {
        describe(settleTimeoutUs: nil)
    }

    func describeFullPage(
        input: any InputProviding,
        bridge: any WindowBridging,
        maxScrolls: Int = EnvConfig.defaultScrollMaxAttempts
    ) -> CalibrationScroller.ScrollResult? {
        CalibrationScroller.collectFullPage(
            describer: self, input: input,
            bridge: bridge, maxScrolls: maxScrolls
        )
    }
}

// MARK: - Conformances

extension ScreenCapture: ScreenCapturing {}

extension ScreenRecorder: ScreenRecording {}

extension ScreenCaptureKitAudio: AppAudioCapturing {}

extension OnDeviceTranscriber: SpeechTranscribing {}

extension AppleVisionTextRecognizer: TextRecognizing {}

extension CoreMLElementDetector: TextRecognizing {}

extension CompositeTextRecognizer: TextRecognizing {}

extension ScreenDescriber: ScreenDescribing {}

extension VisionScreenDescriber: ScreenDescribing {}
