// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the real on-device transcriber, with speech from macOS's own `say`, and the capture's refusal of a gone app.
// ABOUTME: Before macOS 26 the transcriber must refuse plainly instead; ListenIntegrationTests records a real app.

import XCTest
@testable import mirroir_mcp

final class OnDeviceTranscriberTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("listen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// Speak `text` with macOS's `say` into an audio file.
    private func spoken(_ text: String) throws -> URL {
        let file = directory.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", file.path, text]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "say could not speak")
        return file
    }

    private let sentence = "Brown the chicken for five minutes, then add the green onions."
    // The words both engines heard, measured on macOS 26.5: SpeechTranscriber
    // wrote the sentence whole (numbers as digits), dictation heard "Ground the
    // chicken for five minutes, then add the green onion".
    private let expectedWords = ["the chicken", "minutes", "green onion"]

    /// Transcribe the sentence with `engine` and check the words, or the
    /// refusal macOS before 26 gives.
    private func checkWords(engine: OnDeviceTranscriber.Engine, expectedEngine: String) throws {
        let reply = OnDeviceTranscriber(engine: engine).transcribe(file: try spoken(sentence), language: "en-US")
        if #available(macOS 26.0, *) {
            guard case .text(let words, let language, let used) = reply else {
                return XCTFail("expected words, got \(reply)")
            }
            XCTAssertEqual(language, "en-US")
            XCTAssertEqual(used, expectedEngine)
            for word in expectedWords {
                XCTAssertTrue(words.lowercased().contains(word), "'\(word)' not in \(words)")
            }
        } else {
            guard case .unavailable(let reason) = reply else { return XCTFail("expected a refusal, got \(reply)") }
            XCTAssertTrue(reason.contains("macOS 26"), reason)
        }
    }

    /// The default takes SpeechTranscriber where macOS offers it, and
    /// dictation where it does not, as on GitHub's macOS virtual machines.
    func testTheDefaultEngineTranscribesWithWhatThisMacOffers() throws {
        var expected = "dictation"
        if OnDeviceTranscriber.speechEngineAvailable { expected = "speech" }
        try checkWords(engine: .automatic, expectedEngine: expected)
    }

    func testTheDictationEngineTranscribesSpokenEnglish() throws {
        try checkWords(engine: .dictation, expectedEngine: "dictation")
    }

    /// SpeechTranscriber where macOS offers it; elsewhere it is refused by name.
    func testTheSpeechEngineTranscribesOrIsRefusedWhereMacOSLacksIt() throws {
        if #available(macOS 26.0, *), !OnDeviceTranscriber.speechEngineAvailable {
            let reply = OnDeviceTranscriber(engine: .speech).transcribe(file: try spoken(sentence), language: "en-US")
            XCTAssertEqual(reply, .unavailable("this Mac does not offer SpeechTranscriber"))
            return
        }
        try checkWords(engine: .speech, expectedEngine: "speech")
    }

    func testAProcessThatIsNotRunningIsNotShareable() {
        let reply = ScreenCaptureKitAudio().captureAudio(
            pid: pid_t(Int32.max), seconds: 1, stopRule: .fromSettings,
            to: directory.appendingPathComponent("none.caf"))
        XCTAssertEqual(reply, .appNotShareable)
    }

    func testALanguageWithNoModelIsNamed() throws {
        let file = try spoken("Hello.")
        let reply = OnDeviceTranscriber().transcribe(file: file, language: "tlh-QQ")
        if #available(macOS 26.0, *) {
            XCTAssertEqual(reply, .unsupportedLanguage("tlh-QQ"))
        } else {
            guard case .unavailable = reply else { return XCTFail("expected a refusal, got \(reply)") }
        }
    }
}
