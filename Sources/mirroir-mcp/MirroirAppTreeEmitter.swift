// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Emits a runnable .mirroir/apps/<slug>/ iOS leg from a finished exploration.
// ABOUTME: Writes the ios scenario, declares it in SAMPLE.md and the plan; never overwrites onboard's web files.

import Foundation
import HelperLib

/// Emits the iOS leg of the shared `.mirroir/apps/<slug>/` contract from a finished
/// `generate_skill` capture. The web leg (real DOM selectors, runnable) is authored
/// separately by the `mirroir-onboard` skill in `.claude/skills/mirroir-onboard/`,
/// which drives the running web app through chrome-devtools-mcp. This emitter is
/// purely additive — it writes the `.ios.yaml` scenario, declares it in
/// `SAMPLE.md` and a `must_pass` plan entry, and never overwrites a file the web
/// leg owns.
enum MirroirAppTreeEmitter {

    /// Paths written by an emit, surfaced to the caller for the MCP result text.
    struct EmitResult: Sendable {
        let appDir: URL
        let scenarioPath: URL
        /// Human-readable note: SAMPLE.md was created, or a copy-paste snippet.
        let sampleNote: String
        /// Human-readable note: the plan was created/updated, or a copy-paste snippet.
        let planNote: String
    }

    /// Errors the emitter surfaces to the caller.
    enum EmitError: LocalizedError {
        /// The resolved `.mirroir/` would be the runner's `~/.mirroir` pack home.
        case noConsumerRoot
        var errorDescription: String? {
            switch self {
            case .noConsumerRoot:
                return "no .mirroir/ found by walking up from the working directory — " +
                    "pass output_dir or run the MCP from your consumer repo " +
                    "(refusing to emit into ~/.mirroir)"
            }
        }
    }

    /// Emit the iOS oracle leg for `appName` / `goal` from its linear `screens`.
    ///
    /// - Throws: a file-system error if a directory or file cannot be written, or
    ///   `ScenarioStepFormatter.FormatError` when the walk holds an action the
    ///   scenario grammar cannot express.
    static func emit(
        appName: String,
        flow: String,
        screens: [ExploredScreen],
        outputDir: String? = nil,
        root: URL? = nil
    ) throws -> EmitResult {
        guard let mirroirRoot = root ?? MirroirRootLocator.resolve(explicitDir: outputDir) else {
            throw EmitError.noConsumerRoot
        }
        let slug = slugify(appName)
        let flowSlug = slugify(flow.isEmpty ? "capture" : flow)
        let appDir = mirroirRoot.appendingPathComponent("apps/\(slug)", isDirectory: true)
        let scenariosDir = appDir.appendingPathComponent("scenarios", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: scenariosDir, withIntermediateDirectories: true)

        let scenarioFile = "scenarios/\(flowSlug).ios.yaml"
        let scenarioPath = appDir.appendingPathComponent(scenarioFile)
        try ScenarioStepFormatter.scenarioYAML(name: flowSlug, appName: appName, screens: screens)
            .write(to: scenarioPath, atomically: true, encoding: .utf8)
        let sampleNote = try upsertSample(appDir: appDir, appName: appName, scenario: scenarioFile)

        // APP.md is the shared contract's human doc — the web leg owns the canonical
        // one, so only seed a banner when the dir doesn't already have it.
        let appMd = appDir.appendingPathComponent("APP.md")
        if !fm.fileExists(atPath: appMd.path) {
            try appMdBanner(appName: appName).write(to: appMd, atomically: true, encoding: .utf8)
        }

        let planNote = try upsertPlan(mirroirRoot: mirroirRoot, slug: slug)
        return EmitResult(
            appDir: appDir, scenarioPath: scenarioPath,
            sampleNote: sampleNote, planNote: planNote
        )
    }

    // MARK: - Private

    /// Lowercase, collapse non-alphanumerics to single dashes, trim. Never empty.
    static func slugify(_ value: String) -> String {
        var out = ""
        var lastDash = false
        for c in value.lowercased() {
            if c.isLetter || c.isNumber {
                out.append(c)
                lastDash = false
            } else if !out.isEmpty && !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "app" : out
    }

    private static func appMdBanner(appName: String) -> String {
        """
        # \(appName) — iOS capture (mirroir-mcp)

        The **iOS leg** of this app dir is emitted by `generate_skill` from an
        iPhone Mirroring capture. Each `scenarios/<flow>.ios.yaml` is a faithful
        **linear** record of the captured walk, opened by
        `target: { kind: ios }`. `mirroir-run` hands that block to
        `mirroir-mcp test` on a macOS host with iPhone Mirroring connected, and
        refuses it by name on any other host. `SAMPLE.md` declares every flow
        under `must_pass`.

        To hold the app's **web leg** to the same screen, add this flow's iOS
        block to the web scenario and end it with a `cross_surface:` step that
        captures both surfaces live — a web `selector` scrape and the iOS
        block's final screen — and compares them.

        This `.mirroir/` directory is the runner's consumer dotfile, distinct from
        the Swift MCP's `~/.mirroir-mcp/` home.
        """
    }

    /// Declare `scenario` in the app dir's `SAMPLE.md` under `must_pass`.
    /// Creates `SAMPLE.md` when absent; when present, returns a copy-paste
    /// snippet rather than risk a lossy rewrite of a human-edited manifest.
    private static func upsertSample(appDir: URL, appName: String, scenario: String) throws -> String {
        let samplePath = appDir.appendingPathComponent("SAMPLE.md")
        let entry = "      - \(scenario)"
        let fm = FileManager.default
        guard fm.fileExists(atPath: samplePath.path) else {
            let doc = """
                # \(appName)

                The iOS flows `generate_skill` recorded for this app. Each runs as
                one `target: { kind: ios }` block through `mirroir-mcp test`; the
                app needs no server, so the boot command starts nothing.

                ```yaml
                version: 1
                session:
                  boot:
                    command: "true"
                  scenarios:
                    must_pass:
                \(entry)
                ```

                """
            try doc.write(to: samplePath, atomically: true, encoding: .utf8)
            return "created SAMPLE.md declaring \(scenario)"
        }
        let existing = (try? String(contentsOf: samplePath, encoding: .utf8)) ?? ""
        if existing.contains(scenario) {
            return "\(scenario) already declared in SAMPLE.md"
        }
        return "add this line to SAMPLE.md under session.scenarios.must_pass:\n\(entry)"
    }

    /// Add a `local:` plan entry for `slug` under `plan.must_pass`. Creates
    /// `mirroir.yaml` when absent; when present and human-edited, returns a
    /// copy-paste snippet rather than risk a lossy rewrite.
    private static func upsertPlan(mirroirRoot: URL, slug: String) throws -> String {
        let planPath = mirroirRoot.appendingPathComponent("mirroir.yaml")
        let entry = [
            "    - name: \(slug)",
            "      local: apps/\(slug)",
            "      boot:",
            "        command: \"true\"",
        ].joined(separator: "\n")

        let fm = FileManager.default
        guard fm.fileExists(atPath: planPath.path) else {
            let doc = "version: 1\nplan:\n  must_pass:\n" + entry + "\n"
            try doc.write(to: planPath, atomically: true, encoding: .utf8)
            return "created .mirroir/mirroir.yaml with plan entry '\(slug)'"
        }
        let existing = (try? String(contentsOf: planPath, encoding: .utf8)) ?? ""
        if existing.contains("name: \(slug)") {
            return "plan entry '\(slug)' already present in mirroir.yaml"
        }
        return "add this entry to .mirroir/mirroir.yaml under plan.must_pass:\n\(entry)"
    }
}
