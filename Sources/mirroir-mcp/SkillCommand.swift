// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI command that prints the agent operating manual as a SKILL.md, or installs it for Claude Code, Codex and OpenClaw.
// ABOUTME: The text itself lives in OperatingManual; this command only writes it out.

import Foundation
import HelperLib

/// Prints or installs the operating manual.
///
/// Usage: `mirroir-mcp skill [--install] [--help]`
enum SkillCommand {

    /// The option that writes the manual into each host's skills directory.
    static let installOption = "--install"

    /// The option that prints the manual with Agent Skills front matter only.
    static let portableOption = "--portable"

    /// Refuse anything but `--install` or `--portable`, and the two together:
    /// what is installed is the form each of those hosts reads.
    ///
    /// - Throws: `CLIArgumentError` naming the argument this command does not take.
    static func validate(_ arguments: [String]) throws {
        try CLIArguments.requireOnly([installOption, portableOption], in: arguments, command: "skill")
        if arguments.contains(installOption), arguments.contains(portableOption) {
            throw CLIArgumentError.unexpectedArgument(installOption, command: "skill")
        }
    }

    /// Print the manual, or install it. Returns 0, 1 when a file could not be
    /// written, or 2 for refused arguments.
    static func run(arguments: [String]) -> Int32 {
        do {
            try validate(arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return CLIDispatch.usageExitCode
        }
        if arguments.contains(portableOption) {
            print(OperatingManual.portableSkillMarkdown)
            return 0
        }
        guard arguments.contains(installOption) else {
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

    /// Where the skill is installed: Claude Code's personal skills, Codex's skills
    /// under `CODEX_HOME` (default `~/.codex`), and OpenClaw's managed skills under
    /// `OPENCLAW_STATE_DIR` (default `~/.openclaw`).
    static func installDirectories(environment: [String: String]) -> [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".codex")
        let openClawState = environment["OPENCLAW_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".openclaw")
        return [
            (home as NSString).appendingPathComponent(".claude/skills/\(OperatingManual.skillName)"),
            (codexHome as NSString).appendingPathComponent("skills/\(OperatingManual.skillName)"),
            (openClawState as NSString).appendingPathComponent("skills/\(OperatingManual.skillName)"),
        ]
    }

    /// The command's usage text.
    static var usage: String {
        """
            Usage: mirroir-mcp skill [--install | --portable]

            Prints the agent operating manual (how to drive the iPhone with the
            mirroir tools) as a SKILL.md on stdout.

            --install   Write it to ~/.claude/skills/\(OperatingManual.skillName)/SKILL.md,
                        ${CODEX_HOME:-~/.codex}/skills/\(OperatingManual.skillName)/SKILL.md and
                        ${OPENCLAW_STATE_DIR:-~/.openclaw}/skills/\(OperatingManual.skillName)/SKILL.md
            --portable  Print it with Agent Skills front matter only, the form the
                        Hermes package in plugins/hermes ships
            """
    }
}
