// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the shared Process.waitWithTimeout extension.
// ABOUTME: Validates timeout behavior with both fast-exiting and slow processes.

import Foundation
import Testing
@testable import HelperLib

@Suite("ProcessExtensions")
struct ProcessExtensionTests {

    @Test("waitWithTimeout returns .exited with status 0 for a successful process")
    func fastProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try! process.run()
        let result = process.waitWithTimeout(seconds: 5)
        #expect(result == .exited(status: 0))
        #expect(result.didExit)
    }

    @Test("waitWithTimeout returns .timedOut when process exceeds timeout")
    func slowProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try! process.run()

        let result = process.waitWithTimeout(seconds: 1)
        #expect(result == .timedOut)
        #expect(!result.didExit)
        #expect(process.isRunning)

        // Clean up
        process.terminate()
        process.waitUntilExit()
    }

    @Test("waitWithTimeout returns .exited when process exits before timeout")
    func processExitsWithinTimeout() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.1"]
        try! process.run()

        let result = process.waitWithTimeout(seconds: 5)
        #expect(result.didExit, "Process sleeping 0.1s should exit within 5s timeout")
    }

    @Test("waitWithTimeout returns .exited with non-zero status for failing process")
    func failingProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        try! process.run()

        let result = process.waitWithTimeout(seconds: 5)
        #expect(result == .exited(status: 1))
        #expect(result.didExit)
    }
}
