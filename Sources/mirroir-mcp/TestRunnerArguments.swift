// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI surface of `mirroir test` — argument parsing, skill-file resolution, and usage text.
// ABOUTME: Split from TestRunner so the orchestrator holds only the run itself.

import Darwin
import Foundation
import HelperLib

extension TestRunner {

    // MARK: - Argument Parsing

    /// Parse CLI arguments into TestRunConfig.
    static func parseArguments(_ args: [String]) -> TestRunConfig {
        var skillArgs: [String] = []
        var junitPath: String?
        var screenshotDir = "./mirroir-test-results"
        var timeoutSeconds = EnvConfig.waitForTimeoutSeconds
        var verbose = false
        var dryRun = false
        var noCompiled = false
        var agent: String?
        var noAutoRecompile = false
        var confirmDestructive = false
        var reportJSONPath: String?
        var captureKey: String?
        var showHelp = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--help", "-h":
                showHelp = true
            case "--junit":
                i += 1
                if i < args.count { junitPath = args[i] }
            case "--report-json":
                i += 1
                if i < args.count { reportJSONPath = args[i] }
            case "--capture":
                i += 1
                if i < args.count { captureKey = args[i] }
            case "--screenshot-dir":
                i += 1
                if i < args.count { screenshotDir = args[i] }
            case "--timeout":
                i += 1
                if i < args.count, let t = Int(args[i]) { timeoutSeconds = t }
            case "--verbose", "-v":
                verbose = true
            case "--dry-run":
                dryRun = true
            case "--no-compiled":
                noCompiled = true
            case "--confirm-destructive":
                confirmDestructive = true
            case "--no-auto-recompile":
                noAutoRecompile = true
            case "--agent":
                // Peek-ahead: if next arg doesn't start with "-" and isn't a skill file
                // (.md, .yaml, .yml), consume it as the model name. Otherwise, bare
                // --agent = deterministic only.
                if i + 1 < args.count {
                    let next = args[i + 1]
                    if !next.hasPrefix("-") && !next.hasSuffix(".md")
                        && !next.hasSuffix(".yaml") && !next.hasSuffix(".yml") {
                        agent = next
                        i += 1
                    } else {
                        agent = ""
                    }
                } else {
                    agent = ""
                }
            default:
                if !arg.hasPrefix("-") {
                    skillArgs.append(arg)
                }
            }
            i += 1
        }

        return TestRunConfig(
            skillArgs: skillArgs,
            junitPath: junitPath,
            screenshotDir: screenshotDir,
            timeoutSeconds: timeoutSeconds,
            verbose: verbose,
            dryRun: dryRun,
            noCompiled: noCompiled,
            agent: agent,
            noAutoRecompile: noAutoRecompile,
            confirmDestructive: confirmDestructive,
            reportJSONPath: reportJSONPath,
            captureKey: captureKey,
            showHelp: showHelp
        )
    }

    /// Resolve skill arguments to file paths.
    /// If no args given, discovers all skills from default directories.
    static func resolveSkillFiles(_ args: [String]) throws -> [String] {
        if args.isEmpty {
            // Discover all skills from skill directories
            return discoverAllSkillFiles()
        }

        var files: [String] = []
        let dirs = PermissionPolicy.skillDirs

        for arg in args {
            // Check if it's a direct file path
            if FileManager.default.fileExists(atPath: arg) {
                files.append(arg)
                continue
            }

            // Check if it's a glob pattern (contains *)
            if arg.contains("*") {
                let expanded = expandGlob(arg)
                if expanded.isEmpty {
                    throw TestRunnerError.noSkillsFound(pattern: arg)
                }
                files.append(contentsOf: expanded)
                continue
            }

            switch RunnerSkillResolver.resolve(name: arg, dirs: dirs) {
            case .run(let path), .unusable(let path):
                // An unusable file is loaded anyway: its load error says why it cannot run.
                files.append(path)
            case .ambiguous(let matches):
                throw TestRunnerError.ambiguousSkill(name: arg, matches: matches.joined(separator: ", "))
            case .notFound:
                throw TestRunnerError.skillNotFound(name: arg)
            }
        }

        return files
    }

    /// Discover every replayable skill in `dirs`. For each skill, the runner takes the
    /// copy MCP resolution picks (a SKILL.md before a YAML skill, nearer dir first) or,
    /// when that one cannot run, the nearest YAML copy (`SkillFileLoader.runnerChoice`). A SKILL.md
    /// replays only from the steps recorded when it was compiled, so one without a fresh
    /// compiled file is counted and left out, and one holding a step the runner cannot
    /// replay is skipped with its reason.
    static func discoverAllSkillFiles(
        in dirs: [String] = PermissionPolicy.skillDirs
    ) -> [String] {
        // Every copy of each skill, grouped by its path under the skill dir.
        var stems: [String] = []
        var copies: [String: [(path: String, isMd: Bool, dirIndex: Int)]] = [:]
        for (dirIndex, dir) in dirs.enumerated() {
            for relPath in MirroirMCP.findSkillFiles(in: dir) {
                let stem = MirroirMCP.skillStem(relPath)
                if copies[stem] == nil { stems.append(stem) }
                copies[stem, default: []].append(
                    (dir + "/" + relPath, relPath.hasSuffix(".md"), dirIndex))
            }
        }

        var files: [String] = []
        var skippedMd = 0
        for stem in stems {
            // MCP resolution's order: every .md before every .yaml, nearer dir first.
            let ordered = (copies[stem] ?? [])
                .sorted { ($0.isMd ? 0 : 1, $0.dirIndex) < ($1.isMd ? 0 : 1, $1.dirIndex) }
                .map(\.path)
            // A SKILL.md holding a step the runner cannot replay is reported by name;
            // a YAML copy, if any, runs in its place.
            var reported = false
            if let first = ordered.first, SkillFileLoader.isReplayable(filePath: first),
               let unreadable = SkillFileLoader.unreadableStep(filePath: first) {
                fputs("Skipping \(first): \(unreadable)\n", stderr)
                reported = true
            }
            let runnable = { (path: String) in
                SkillFileLoader.isReplayable(filePath: path)
                    && SkillFileLoader.unreadableStep(filePath: path) == nil
            }
            guard let choice = SkillFileLoader.runnerChoice(
                ordered, accept: runnable, yamlFallback: true) else {
                if !reported { skippedMd += 1 }
                continue
            }
            files.append(choice)
        }

        if skippedMd > 0 {
            fputs("Skipped \(skippedMd) .md file(s) with no fresh compiled file or kind:game\n", stderr)
        }
        return files
    }

    /// Expand a glob pattern to matching file paths.
    private static func expandGlob(_ pattern: String) -> [String] {
        var gt = glob_t()
        defer { globfree(&gt) }

        let result = glob(pattern, 0, nil, &gt)
        guard result == 0 else { return [] }

        var files: [String] = []
        for i in 0..<Int(gt.gl_matchc) {
            if let path = gt.gl_pathv[i] {
                files.append(String(cString: path))
            }
        }
        let skills = files.filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".md") }
        let loadable = skills.filter { SkillFileLoader.isReplayable(filePath: $0) }
        let replayable = loadable.filter { path in
            guard let unreadable = SkillFileLoader.unreadableStep(filePath: path) else { return true }
            fputs("Skipping \(path): \(unreadable)\n", stderr)
            return false
        }
        let skipped = skills.count - loadable.count
        if skipped > 0 {
            fputs("Skipped \(skipped) .md file(s) matching \(pattern) with no fresh compiled "
                + "file or kind:game\n", stderr)
        }
        // A replayable SKILL.md and its YAML twin are one skill: the SKILL.md runs.
        let replayableMd = Set(replayable.filter { $0.hasSuffix(".md") })
        return replayable.filter { path in
            !(path.hasSuffix(".yaml")
              && replayableMd.contains((path as NSString).deletingPathExtension + ".md"))
        }.sorted()
    }

    /// Print usage information.
    static func printUsage() {
        let usage = """
        Usage: mirroir-mcp test [options] [skill...]

        Run skills deterministically against iPhone Mirroring. A YAML skill runs
        its own steps; a SKILL.md runs the steps recorded in its .compiled.json
        when it was compiled through an MCP client (get_skill, record_step,
        save_compiled).

        Arguments:
          <skill>             Skill name, .md or .yaml file path (multiple allowed)
                              If none specified, discovers all from skill dirs
                              (an uncompiled SKILL.md is skipped)

        Options:
          --junit <path>      Write JUnit XML report to <path>
          --report-json <path>
                              Write a Playwright JSON-reporter document to <path>
                              (the format mirroir-run ingests)
          --capture <key>     Attach each skill's final-screen OCR text to the
                              --report-json document under cross_surface.<key>
          --screenshot-dir    Failure screenshot directory (default: ./mirroir-test-results/)
          --timeout <sec>     wait_for timeout in seconds (default: 15)
          --verbose, -v       Show detailed output
          --dry-run           Parse and validate without executing
          --confirm-destructive
                              Allow steps that send, remove, spend, or reset
                              something on the device. Refused by default.
          --no-compiled       Skip compiled skills (force full OCR)
          --no-auto-recompile Skip auto-recompilation of drifted compiled skills
          --agent [model]     Diagnose compiled failures. Without model: deterministic OCR only.
                              With model: deterministic + AI diagnosis.
                              Built-in: gpt-5.3, claude-opus-5-5, claude-sonnet-5-5,
                                        claude-haiku-5-5, embacle, embacle:claude
                              Ollama: ollama:<model>  Custom: name from agents/ dir
          --help, -h          Show this help

        Examples:
          mirroir-mcp test check-about
          mirroir-mcp test apps/settings/check-about.md
          mirroir-mcp test --junit results.xml apps/settings/*.yaml
          mirroir-mcp test --agent skill.yaml           # deterministic diagnosis
          mirroir-mcp test --agent claude-sonnet-5-5 skill.yaml  # AI diagnosis
          mirroir-mcp test                    # run all discovered skills
        """
        fputs(usage + "\n", stderr)
    }
}

/// Errors during test run resolution.
enum TestRunnerError: LocalizedError {
    case noSkillsFound(pattern: String)
    case ambiguousSkill(name: String, matches: String)
    case skillNotFound(name: String)

    var errorDescription: String? {
        switch self {
        case .noSkillsFound(let pattern):
            return "No skills found matching pattern: \(pattern)"
        case .ambiguousSkill(let name, let matches):
            return "Ambiguous skill '\(name)'. Multiple matches: \(matches)"
        case .skillNotFound(let name):
            return "Skill '\(name)' not found"
        }
    }
}
