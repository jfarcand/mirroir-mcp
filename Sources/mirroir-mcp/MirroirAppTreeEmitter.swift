// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Emits a runner-consumable .mirroir/apps/<slug>/ iOS oracle leg from a finished exploration.
// ABOUTME: Writes the iOS capture + the cross-surface baseline mirroir-run compares; never overwrites onboard's web files.

import Foundation
import HelperLib

/// Emits the iOS leg of the shared `.mirroir/apps/<slug>/` contract from a finished
/// `generate_skill` capture. The web leg (real DOM selectors, runnable) is authored
/// separately by the `mirroir-onboard` skill in `.claude/skills/mirroir-onboard/`,
/// which drives the running web app through chrome-devtools-mcp. This emitter is
/// purely additive — it
/// writes the `.ios.yaml` scenario + the cross-surface baseline and upserts a plan
/// entry, and never overwrites a file the web leg owns.
enum MirroirAppTreeEmitter {

    /// Paths written by an emit, surfaced to the caller for the MCP result text.
    struct EmitResult: Sendable {
        let appDir: URL
        let scenarioPath: URL
        let baselinePath: URL
        /// The cross-surface parity gate pairing the iOS baseline with a web baseline.
        let parityPath: URL
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
        let baselinesDir = appDir.appendingPathComponent("baselines", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: scenariosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: baselinesDir, withIntermediateDirectories: true)

        let scenarioPath = scenariosDir.appendingPathComponent("\(flowSlug).ios.yaml")
        let baselinePath = baselinesDir.appendingPathComponent("\(flowSlug).ios.txt")
        let parityPath = scenariosDir.appendingPathComponent("\(flowSlug).parity.yaml")
        try ScenarioStepFormatter.scenarioYAML(name: flowSlug, appName: appName, screens: screens)
            .write(to: scenarioPath, atomically: true, encoding: .utf8)
        try ScenarioStepFormatter.baseline(screens: screens)
            .write(to: baselinePath, atomically: true, encoding: .utf8)
        try ScenarioStepFormatter.crossSurfaceYAML(name: flowSlug, flow: flowSlug)
            .write(to: parityPath, atomically: true, encoding: .utf8)

        // APP.md is the shared contract's human doc — the web leg owns the canonical
        // one, so only seed a banner when the dir doesn't already have it.
        let appMd = appDir.appendingPathComponent("APP.md")
        if !fm.fileExists(atPath: appMd.path) {
            try appMdBanner(appName: appName).write(to: appMd, atomically: true, encoding: .utf8)
        }

        let planNote = try upsertPlan(mirroirRoot: mirroirRoot, slug: slug)
        return EmitResult(
            appDir: appDir, scenarioPath: scenarioPath, baselinePath: baselinePath,
            parityPath: parityPath, planNote: planNote
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
        iPhone Mirroring capture. The `scenarios/<flow>.ios.yaml` document is a
        faithful **linear** record of the captured walk. It opens
        `target: { kind: ios }`, a surface mirroir-run has no executor for, so the
        runner refuses it by name — at `--validate` exactly as at run time. It is
        a capture artifact and the parity gate's anchor, not a runner scenario.

        The **web leg** (real DOM selectors, runnable on `mirroir-run`) is authored
        separately. Cross-surface parity pairs `baselines/<flow>.ios.txt` (emitted
        here) with a web capture via a `cross_surface:` step, which fails closed
        until the web capture exists.

        This `.mirroir/` directory is the runner's consumer dotfile, distinct from
        the Swift MCP's `~/.mirroir-mcp/` home.
        """
    }

    /// Add a `local:` plan entry for `slug` under `plan.nice_to_pass` (`skip: true`
    /// until a web boot is wired). Creates `mirroir.yaml` when absent; when present
    /// and human-edited, returns a copy-paste snippet rather than risk a lossy rewrite.
    private static func upsertPlan(mirroirRoot: URL, slug: String) throws -> String {
        let planPath = mirroirRoot.appendingPathComponent("mirroir.yaml")
        let entry = [
            "    - name: \(slug)",
            "      local: apps/\(slug)",
            "      skip: true",
            "      boot:",
            "        command: \"true\"",
        ].joined(separator: "\n")

        let fm = FileManager.default
        guard fm.fileExists(atPath: planPath.path) else {
            let doc = "version: 1\nplan:\n  nice_to_pass:\n" + entry + "\n"
            try doc.write(to: planPath, atomically: true, encoding: .utf8)
            return "created .mirroir/mirroir.yaml with plan entry '\(slug)'"
        }
        let existing = (try? String(contentsOf: planPath, encoding: .utf8)) ?? ""
        if existing.contains("name: \(slug)") {
            return "plan entry '\(slug)' already present in mirroir.yaml"
        }
        return "add this entry to .mirroir/mirroir.yaml under plan.nice_to_pass:\n\(entry)"
    }
}
