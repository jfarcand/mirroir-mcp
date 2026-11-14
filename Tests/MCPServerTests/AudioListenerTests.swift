// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the listen tool's logic and handler: silence, missing app, languages, errors and the reply wording.
// ABOUTME: Audio capture and transcription are stood in: both are hardware boundaries tested for real elsewhere.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// Records the request and answers a fixed capture reply. Stands in for
/// ScreenCaptureKit, whose real behavior ScreenCaptureKitAudioTests measures.
final class StubAudioCapturer: AppAudioCapturing, @unchecked Sendable {
    var reply: AudioCaptureReply = .recorded(peak: 0.5, seconds: 10, end: .fullLength)
    private(set) var requests: [(pid: pid_t, seconds: Double, stopRule: ListenStopRule, file: URL)] = []

    func captureAudio(pid: pid_t, seconds: Double, stopRule: ListenStopRule, to file: URL) -> AudioCaptureReply {
        requests.append((pid, seconds, stopRule, file))
        if case .recorded = reply { FileManager.default.createFile(atPath: file.path, contents: Data([0])) }
        return reply
    }
}

/// Records the language asked and answers a fixed transcription. Stands in for
/// SpeechAnalyzer, whose real behavior OnDeviceTranscriberTests measures.
final class StubTranscriber: SpeechTranscribing, @unchecked Sendable {
    var reply: TranscriptionReply = .text("Tu fais dorer le poulet cinq minutes.", language: "fr-CA", engine: "speech")
    private(set) var languages: [String] = []
    private(set) var fileExisted: [Bool] = []

    func transcribe(file: URL, language: String) -> TranscriptionReply {
        languages.append(language)
        fileExisted.append(FileManager.default.fileExists(atPath: file.path))
        return reply
    }
}

final class AudioListenerTests: XCTestCase {

    private let capturer = StubAudioCapturer()
    private let transcriber = StubTranscriber()

    private func listen(_ bridge: StubBridge = StubBridge(), seconds: Double = 10,
                        language: String? = nil) -> AudioListener.Outcome {
        AudioListener.listen(bridge: bridge, seconds: seconds, language: language,
                             capturer: capturer, transcriber: transcriber, fallbackLanguage: "en-US")
    }

    func testSpeechIsReturnedAsWordsWithTheLanguageUsed() {
        let outcome = listen(language: "fr-CA")
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.text, "Heard during the 10 s, transcribed on this Mac in fr-CA by the speech engine "
            + "(words only, not who spoke):\nTu fais dorer le poulet cinq minutes.")
        XCTAssertEqual(transcriber.languages, ["fr-CA"])
    }

    func testTheTargetsOwnProcessIsRecorded() {
        let bridge = StubBridge()
        bridge.windowInfo = WindowInfo(windowID: 7, position: .zero, size: CGSize(width: 430, height: 942), pid: 4242)
        _ = listen(bridge, seconds: 15)
        XCTAssertEqual(capturer.requests.first?.pid, 4242)
        XCTAssertEqual(capturer.requests.first?.seconds, 15)
    }

    func testWithoutALanguageTheMacsIsUsed() {
        _ = listen()
        XCTAssertEqual(transcriber.languages, ["en-US"])
        _ = listen(language: "")
        XCTAssertEqual(transcriber.languages, ["en-US", "en-US"], "an empty language is no language")
    }

    func testSilenceIsReportedAndNotTranscribed() {
        capturer.reply = .recorded(peak: 0.001, seconds: 3.4, end: .fullLength)
        let outcome = listen()
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.hasPrefix("Nothing played during the 10 s"), outcome.text)
        XCTAssertTrue(transcriber.languages.isEmpty)
    }

    /// carnet#67: a muted reel was recorded for its whole 48 s.
    func testASilentStartStopsEarlyAndSaysNothingIsPlaying() {
        capturer.reply = .recorded(peak: 0.002, seconds: 4.1, end: .silentStart)
        let outcome = listen(seconds: 48)
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.hasPrefix("Nothing is playing: 4.1 s of silence from the start"), outcome.text)
        XCTAssertTrue(outcome.text.contains("muted"), outcome.text)
        XCTAssertTrue(transcriber.languages.isEmpty, "silence is not transcribed")
    }

    /// carnet#67: a 33 s reel was recorded for 61 s.
    func testSpeechThatEndedIsTranscribedForTheLengthRecorded() {
        capturer.reply = .recorded(peak: 0.8, seconds: 36.04, end: .soundEnded)
        let rule = ListenStopRule(silencePeak: 0.01, silentStart: 4, trailingSilence: 3)
        let outcome = AudioListener.listen(bridge: StubBridge(), seconds: 60, language: "fr-CA",
                                           capturer: capturer, transcriber: transcriber,
                                           fallbackLanguage: "en-US", stopRule: rule)
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.hasPrefix("Heard during the 36 s (stopped after 3 s of silence: the sound "
            + "had ended), transcribed on this Mac in fr-CA"), outcome.text)
        XCTAssertEqual(capturer.requests.first?.stopRule, rule, "the capture stops on the rule given")
    }

    func testTheStopRuleComesFromSettings() {
        _ = listen()
        XCTAssertEqual(capturer.requests.first?.stopRule, ListenStopRule(
            silencePeak: Float(TimingConstants.listenSilencePeak),
            silentStart: TimingConstants.listenSilentStartSeconds,
            trailingSilence: TimingConstants.listenTrailingSilenceSeconds))
    }

    func testSoundWithoutWordsSuggestsTheLanguage() {
        transcriber.reply = .text("", language: "en-US", engine: "dictation")
        let outcome = listen()
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.contains("no speech was recognized in en-US"), outcome.text)
        XCTAssertTrue(outcome.text.contains("pass language"), outcome.text)
    }

    func testTheRecordingIsGoneOnceRead() throws {
        _ = listen()
        let file = try XCTUnwrap(capturer.requests.first?.file)
        XCTAssertEqual(transcriber.fileExisted, [true], "the transcriber reads the recording")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the audio does not outlive the call")
    }

    func testAStoppedTargetIsNamed() {
        let bridge = StubBridge()
        bridge.windowInfo = nil
        bridge.processRunning = false
        let outcome = listen(bridge)
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "'iphone' is not running, so there is nothing to listen to.")
        XCTAssertTrue(capturer.requests.isEmpty)
    }

    func testCaptureAndTranscriptionFailuresAreErrors() {
        capturer.reply = .appNotShareable
        XCTAssertTrue(listen().text.contains("check_health"))
        capturer.reply = .failed("no grant")
        XCTAssertEqual(listen().text, "Listening failed: no grant.")

        capturer.reply = .recorded(peak: 0.4, seconds: 10, end: .fullLength)
        transcriber.reply = .unsupportedLanguage("xx-YY")
        XCTAssertTrue(listen(language: "xx-YY").text.hasPrefix("No on-device speech model exists for 'xx-YY'"))
        transcriber.reply = .unavailable("listening needs macOS 26 or later")
        let old = listen()
        XCTAssertTrue(old.isError)
        XCTAssertEqual(old.text, "Listening is not available: listening needs macOS 26 or later.")
    }

    func testTheLengthIsClampedToItsBounds() {
        XCTAssertEqual(AudioListener.clampedSeconds(nil), AudioListener.defaultSeconds)
        XCTAssertEqual(AudioListener.clampedSeconds(0), AudioListener.minSeconds)
        XCTAssertEqual(AudioListener.clampedSeconds(600), AudioListener.maxSeconds)
        XCTAssertEqual(AudioListener.clampedSeconds(7.5), 7.5)
    }

    // MARK: - The tool

    private func call(_ args: [String: JSONValue]) -> (text: String, isError: Bool) {
        let server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil), transport: .stdio)
        MirroirMCP.registerListenTools(server: server, registry: makeTestRegistry(bridge: StubBridge(), input: StubInput()),
                                       capturer: capturer, transcriber: transcriber)
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string("listen"), "arguments": .object(args)]))
        guard case .object(let result)? = server.handleRequest(request)?.result,
              case .array(let content)? = result["content"],
              case .object(let first)? = content.first,
              case .string(let text)? = first["text"] else { return ("", true) }
        if case .bool(let isError)? = result["isError"] { return (text, isError) }
        return (text, false)
    }

    func testTheToolPassesItsArgumentsAndClampsTheLength() {
        let reply = call(["seconds": .number(120), "language": .string("fr-CA")])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains("Heard during the 60 s"), reply.text)
        XCTAssertEqual(capturer.requests.first?.seconds, AudioListener.maxSeconds)
        XCTAssertEqual(transcriber.languages, ["fr-CA"])
    }

    func testTheToolReportsAFailureAsAnError() {
        capturer.reply = .failed("no grant")
        XCTAssertEqual(call([:]).isError, true)
    }

    func testListenIsReadOnly() {
        XCTAssertTrue(PermissionPolicy.readonlyTools.contains("listen"))
    }
}
