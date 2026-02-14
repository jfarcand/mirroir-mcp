// ABOUTME: Tests for the shared Process.waitWithTimeout extension.
// ABOUTME: Validates timeout behavior with both fast-exiting and slow processes.

import Foundation
import Testing
@testable import HelperLib

@Suite("ProcessExtensions")
struct ProcessExtensionTests {

    @Test("waitWithTimeout returns true for a process that exits immediately")
    func fastProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try! process.run()
        let exited = process.waitWithTimeout(seconds: 5)
        #expect(exited, "Process that exits immediately should return true")
        #expect(process.terminationStatus == 0)
    }

    @Test("waitWithTimeout returns false when process exceeds timeout")
    func slowProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try! process.run()

        let exited = process.waitWithTimeout(seconds: 1)
        #expect(!exited, "Process sleeping 10s should not exit within 1s timeout")
        #expect(process.isRunning)

        // Clean up
        process.terminate()
        process.waitUntilExit()
    }

    @Test("waitWithTimeout returns true when process exits before timeout")
    func processExitsWithinTimeout() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.1"]
        try! process.run()

        let exited = process.waitWithTimeout(seconds: 5)
        #expect(exited, "Process sleeping 0.1s should exit within 5s timeout")
    }

    @Test("waitWithTimeout returns true for process with non-zero exit code")
    func failingProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        try! process.run()

        let exited = process.waitWithTimeout(seconds: 5)
        #expect(exited, "Process should be detected as exited regardless of exit code")
        #expect(process.terminationStatus != 0)
    }
}
