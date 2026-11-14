// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Runs the agent-skill step of uninstall-mirroir.sh against a throwaway home.
// ABOUTME: Every directory `skill --install` writes is removed; a skill mirroir did not write is kept.

import Foundation
import XCTest
@testable import mirroir_mcp

final class UninstallSkillStepTests: XCTestCase {

    private static let scriptURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("uninstall-mirroir.sh")
    private static let stepStart = "# --- Step 3:"
    private static let stepEnd = "# --- Step 4:"

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("uninstall-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// The step 3 block of the uninstaller, the lines between its heading and step 4's.
    private func skillStep() throws -> String {
        let script = try String(contentsOf: Self.scriptURL, encoding: .utf8)
        let start = try XCTUnwrap(script.range(of: Self.stepStart), "uninstaller has no step 3")
        let end = try XCTUnwrap(script.range(of: Self.stepEnd, range: start.upperBound..<script.endIndex),
                                "uninstaller has no step 4")
        return String(script[start.lowerBound..<end.lowerBound])
    }

    private func runSkillStep(environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", try skillStep()]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func install(_ markdown: String, in directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try markdown.write(toFile: (directory as NSString).appendingPathComponent("SKILL.md"),
                           atomically: true, encoding: .utf8)
    }

    func testRemovesEveryDirectoryTheInstallWrites() throws {
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let directories = SkillCommand.installDirectories(environment: environment)
        for directory in directories {
            try install(OperatingManual.skillMarkdown, in: directory)
        }

        XCTAssertEqual(try runSkillStep(environment: environment), 0)

        for directory in directories {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory), directory)
        }
    }

    func testFollowsTheCodexAndOpenClawEnvironmentOverrides() throws {
        let environment = [
            "HOME": home.path, "PATH": "/usr/bin:/bin",
            "CODEX_HOME": home.appendingPathComponent("codex-elsewhere").path,
            "OPENCLAW_STATE_DIR": home.appendingPathComponent("openclaw-elsewhere").path,
        ]
        let directories = SkillCommand.installDirectories(environment: environment)
        for directory in directories {
            try install(OperatingManual.skillMarkdown, in: directory)
        }

        XCTAssertEqual(try runSkillStep(environment: environment), 0)

        for directory in directories {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory), directory)
        }
    }

    func testKeepsASkillMirroirDidNotWrite() throws {
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let directories = SkillCommand.installDirectories(environment: environment)
        for directory in directories {
            try install("# Someone else's skill\n", in: directory)
        }

        XCTAssertEqual(try runSkillStep(environment: environment), 0)

        for directory in directories {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory), directory)
        }
    }
}
