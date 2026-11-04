// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI command that prints the agent operating manual as a SKILL.md, or installs it for Claude Code and Codex.
// ABOUTME: The text itself lives in OperatingManual; this command only writes it out.

import Foundation
import HelperLib

/// Prints or installs the operating manual.
///
/// Usage: `mirroir-mcp skill [--install] [--help]`
enum SkillCommand {

    static func run(arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return 0
        }
        guard arguments.contains("--install") else {
            print(OperatingManual.skillMarkdown)
            return 0
        }
        let environment = ProcessInfo.processInfo.environment
        var failed = false
        for directory in installDirectories(environment: environment) {
            let path = (directory as NSString).appendingPathComponent("SKILL.md")
            do {
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true)
                try OperatingManual.skillMarkdown.write(toFile: path, atomically: true, encoding: .utf8)
                fputs("Installed \(path)\n", stderr)
            } catch {
                fputs("Could not write \(path): \(error.localizedDescription)\n", stderr)
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    /// Where the skill is installed: Claude Code's personal skills, and Codex's
    /// skills under `CODEX_HOME` (default `~/.codex`).
    static func installDirectories(environment: [String: String]) -> [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".codex")
        return [
            (home as NSString).appendingPathComponent(".claude/skills/\(OperatingManual.skillName)"),
            (codexHome as NSString).appendingPathComponent("skills/\(OperatingManual.skillName)"),
        ]
    }

    static func printUsage() {
        fputs("""
            Usage: mirroir-mcp skill [--install]

            Prints the agent operating manual (how to drive the iPhone with the
            mirroir tools) as a SKILL.md on stdout.

            --install   Write it to ~/.claude/skills/\(OperatingManual.skillName)/SKILL.md and
                        ${CODEX_HOME:-~/.codex}/skills/\(OperatingManual.skillName)/SKILL.md

            """, stderr)
    }
}
