// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: End-to-end listen against FakeMirroring: the app speaks, ScreenCaptureKit records it, the Mac transcribes it.
// ABOUTME: Real capture and real transcription; before macOS 26 the transcriber's refusal is checked instead.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class ListenIntegrationTests: XCTestCase {

    private var bridge: MirroringBridge!

    /// What FakeMirroring is asked to say, and the words the transcript must hold.
    private let sentence = "Brown the chicken for five minutes, then add the green onions and the sauce."
    private let expectedWords = ["the chicken", "minutes", "green onion"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        try IntegrationTestHelper.ensureFakeMirroringRunning()
        bridge = MirroringBridge(bundleID: IntegrationTestHelper.fakeBundleID)
    }

    /// Ask FakeMirroring to speak, from its own process, as a reel plays its sound.
    private func speak() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.jfarcand.FakeMirroring.speak"), object: nil,
            userInfo: ["text": sentence], deliverImmediately: true)
    }

    func testTheSoundTheAppPlaysIsRecorded() throws {
        let pid = try XCTUnwrap(bridge.findProcess()?.processIdentifier, "FakeMirroring is not running")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("listen-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        speak()
        let reply = ScreenCaptureKitAudio().captureAudio(
            pid: pid, seconds: 4, stopRule: .fromSettings, to: file)
        guard case .recorded(let peak, _, _) = reply else { return XCTFail("expected a recording, got \(reply)") }
        XCTAssertGreaterThan(peak, ListenStopRule.fromSettings.silencePeak, "FakeMirroring's speech was not heard")
    }

    func testListenHearsTheWordsTheAppSpeaks() {
        speak()
        let outcome = AudioListener.listen(
            bridge: bridge, seconds: 6, language: "en-US",
            capturer: ScreenCaptureKitAudio(), transcriber: OnDeviceTranscriber())
        if #available(macOS 26.0, *) {
            XCTAssertFalse(outcome.isError, outcome.text)
            let heard = outcome.text.lowercased()
            for word in expectedWords {
                XCTAssertTrue(heard.contains(word), "'\(word)' not in \(outcome.text)")
            }
        } else {
            XCTAssertTrue(outcome.isError)
            XCTAssertTrue(outcome.text.contains("macOS 26"), outcome.text)
        }
    }

    func testSilenceIsReportedAsSilence() {
        let outcome = AudioListener.listen(
            bridge: bridge, seconds: 2, language: "en-US",
            capturer: ScreenCaptureKitAudio(), transcriber: OnDeviceTranscriber())
        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertTrue(outcome.text.hasPrefix("Nothing played during the 2 s"), outcome.text)
    }
}
