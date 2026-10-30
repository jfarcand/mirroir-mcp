// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Emits a runnable .mirroir/apps/<slug>/ iOS leg from a finished exploration.
// ABOUTME: Writes one ios scenario per replayable flow, declares each in SAMPLE.md and the plan; never web files.

import Foundation
import HelperLib

/// Emits the iOS leg of the shared `.mirroir/apps/<slug>/` contract from a finished
/// `generate_skill` capture. The web leg (real DOM selectors, runnable) is authored
/// separately by the `mirroir-onboard` skill in `.claude/skills/mirroir-onboard/`,
/// which drives the running web app through chrome-devtools-mcp. This emitter is
/// purely additive — it writes one `.ios.yaml` scenario per flow, declares each
/// in `SAMPLE.md` and a `must_pass` plan entry, and never overwrites a file the
/// web leg owns.
enum MirroirAppTreeEmitter {

    /// One captured walk to emit as its own `scenarios/<flow>.ios.yaml`.
    struct Flow: Sendable {
        /// Human name of the flow; its slug names the scenario file.
        let name: String
        /// The linear walk: the launch screen, then each screen an action reached.
        let screens: [ExploredScreen]
    }

    /// Paths written by an emit, surfaced to the caller for the MCP result text.
    struct EmitResult: Sendable {
        let appDir: URL
        /// One scenario per emitted flow, in the order SAMPLE.md declares them.
        let scenarioPaths: [URL]
        /// Human-readable note: SAMPLE.md was created, extended, or already declared every flow.
        let sampleNote: String
        /// Human-readable note: the plan was created/updated, or a copy-paste snippet.
        let planNote: String
        /// Flows left out because their walk cannot replay, in name order.
        let dropped: [DroppedFlow]
    }

    /// A flow the emit left out, and the formatter's reason it cannot replay.
    struct DroppedFlow: Sendable, Equatable {
        let flow: String
        let reason: String
    }

    /// Errors the emitter surfaces to the caller.
    enum EmitError: LocalizedError, Equatable {
        /// The resolved `.mirroir/` would be the runner's `~/.mirroir` pack home.
        case noConsumerRoot
        /// The exploration produced no walk to emit.
        case noFlows(appName: String)
        /// A flow holds no screen at all, not even the launch.
        case emptyWalk(flow: String)
        /// The exploration stopped before finishing (paused, trapped, or could
        /// not relaunch), so it produced no graph to emit flows from.
        case explorationUnfinished(appName: String, outcome: String)
        /// Every flow's walk holds a step a replay cannot perform, so no
        /// scenario was written. `dropped` names each flow and why.
        case noReplayableFlow(appName: String, dropped: [DroppedFlow])
        /// The scenarios were written, but the existing, human-owned `SAMPLE.md`
        /// does not declare `undeclared` of them, so `mirroir-run` would never
        /// replay those. `snippet` is the exact text to paste under
        /// `session.scenarios.must_pass`; `stale` names declared iOS flows this
        /// emit did not produce; `dropped` names the flows left out because
        /// their walk cannot replay, and why. An owned `SAMPLE.md` whose
        /// `must_pass` list cannot be located unambiguously raises it too.
        /// `planError` describes the plan entry's failure when `mirroir.yaml`
        /// could not be updated either, with the entry to paste.
        case undeclaredFlows(
            sample: String, undeclared: [String], snippet: String, stale: [String],
            dropped: [DroppedFlow], planError: String?)
        /// The emitter owns `mirroir.yaml` but cannot locate its
        /// `plan.must_pass` list unambiguously, so the `slug` entry was not
        /// added; `snippet` is the entry to paste there.
        case unplacedPlanEntry(plan: String, slug: String, snippet: String)
        var errorDescription: String? {
            switch self {
            case .noConsumerRoot:
                return "no .mirroir/ found by walking up from the working directory — " +
                    "pass output_dir or run the MCP from your consumer repo " +
                    "(refusing to emit into ~/.mirroir)"
            case .noFlows(let appName):
                return "emit requested but the exploration of \(appName) produced no walk " +
                    "to write; nothing was emitted"
            case .emptyWalk(let flow):
                return "emit requested but flow \"\(flow)\" captured no screen; nothing was emitted"
            case .explorationUnfinished(let appName, let outcome):
                return "emit requested but the exploration of \(appName) did not finish " +
                    "(\(outcome)); nothing was emitted"
            case .noReplayableFlow(let appName, let dropped):
                return "emit requested but no flow of \(appName) can replay; nothing was " +
                    "emitted:\n" + MirroirAppTreeEmitter.droppedList(dropped)
            case .undeclaredFlows(
                let sample, let undeclared, let snippet, let stale, let dropped, let planError):
                let droppedNote = dropped.isEmpty ? "" :
                    "\nalso dropped (a step no replay can perform; no scenario written):\n" +
                    MirroirAppTreeEmitter.droppedList(dropped)
                let planNote = planError.map { "\nthe plan was not updated either: \($0)" } ?? ""
                return "wrote \(undeclared.joined(separator: ", ")) but \(sample) does not " +
                    "declare them, so mirroir-run will not replay them; add these lines to " +
                    "SAMPLE.md under session.scenarios.must_pass:\n\(snippet)" +
                    MirroirManifestUpsert.staleNote(stale) + droppedNote + planNote
            case .unplacedPlanEntry(let plan, let slug, let snippet):
                return "\(plan) has no single plan.must_pass block list to add '\(slug)' to; " +
                    "add this entry under plan.must_pass:\n\(snippet)"
            }
        }
    }

    /// Emit the iOS oracle leg for `appName`: one scenario per replayable
    /// flow, every one declared under `must_pass` in `SAMPLE.md`, plus the
    /// plan entry.
    ///
    /// Flows are written in slug order — the order a graph walk produced them
    /// in is not stable — and two flows whose names slug alike are told apart
    /// by a numeric suffix. Every flow is rendered before anything is written.
    /// A flow whose walk holds a step the scenario grammar cannot express, or
    /// a label a replay could not find, is dropped and named in
    /// `EmitResult.dropped`; only when every flow is dropped is the emit
    /// refused, leaving the tree untouched. The emitter owns each `.ios.yaml`
    /// it writes and overwrites it on re-emit; `APP.md` is created when
    /// absent and never rewritten.
    ///
    /// `SAMPLE.md` and `mirroir.yaml` are created with an ownership marker
    /// and kept current by later emits (`MirroirManifestUpsert`), which insert
    /// into their `must_pass` lists in place. A `SAMPLE.md` without that
    /// marker is a human's and is checked last: a written flow it does not
    /// declare is an `undeclaredFlows` error carrying the lines to paste and
    /// the flows dropped as unreplayable — `mirroir-run` replays only what SAMPLE.md
    /// declares, so a flow written but undeclared is not emitted in any sense
    /// that matters. Declared iOS flows this emit did not produce are named,
    /// in that error or in the success note; they stay on disk and declared.
    ///
    /// - Throws: `EmitError` when there is nothing to emit, no replayable
    ///   flow, no consumer root, a written flow SAMPLE.md does not declare and
    ///   the emitter cannot add, a plan entry it cannot place, or a
    ///   file-system error.
    static func emit(
        appName: String,
        flows: [Flow],
        outputDir: String? = nil,
        root: URL? = nil
    ) throws -> EmitResult {
        guard !flows.isEmpty else { throw EmitError.noFlows(appName: appName) }
        if let empty = flows.first(where: { $0.screens.isEmpty }) {
            throw EmitError.emptyWalk(flow: empty.name)
        }
        guard let mirroirRoot = root ?? MirroirRootLocator.resolve(explicitDir: outputDir) else {
            throw EmitError.noConsumerRoot
        }
        let (scenarios, dropped) = try renderScenarios(appName: appName, flows: flows)
        guard !scenarios.isEmpty else {
            throw EmitError.noReplayableFlow(appName: appName, dropped: dropped)
        }

        let slug = slugify(appName)
        let appDir = mirroirRoot.appendingPathComponent("apps/\(slug)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(
            at: appDir.appendingPathComponent("scenarios", isDirectory: true),
            withIntermediateDirectories: true)

        var scenarioPaths: [URL] = []
        for scenario in scenarios {
            let path = appDir.appendingPathComponent(scenario.file)
            try scenario.yaml.write(to: path, atomically: true, encoding: .utf8)
            scenarioPaths.append(path)
        }

        // APP.md is the shared contract's human doc — the web leg owns the canonical
        // one, so only seed a banner when the dir doesn't already have it.
        let appMd = appDir.appendingPathComponent("APP.md")
        if !fm.fileExists(atPath: appMd.path) {
            try appMdBanner(appName: appName).write(to: appMd, atomically: true, encoding: .utf8)
        }

        // The plan's error is raised after SAMPLE.md is brought current, and
        // SAMPLE.md goes last, so either error leaves every other file in place.
        // When both fail, SAMPLE.md's error carries the plan's, so one result
        // names every line to paste.
        let plan = Result { try MirroirManifestUpsert.upsertPlan(mirroirRoot: mirroirRoot, slug: slug) }
        let sampleNote: String
        do {
            sampleNote = try MirroirManifestUpsert.upsertSample(
                appDir: appDir, appName: appName, scenarios: scenarios.map(\.file))
        } catch EmitError.undeclaredFlows(let sample, let undeclared, let snippet, let stale, _, _) {
            var planError: String?
            if case .failure(let error) = plan {
                planError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            throw EmitError.undeclaredFlows(
                sample: sample, undeclared: undeclared, snippet: snippet, stale: stale,
                dropped: dropped, planError: planError)
        }
        let planNote = try plan.get()
        return EmitResult(
            appDir: appDir, scenarioPaths: scenarioPaths,
            sampleNote: sampleNote, planNote: planNote, dropped: dropped
        )
    }

    /// One line per dropped flow: its name and why it cannot replay.
    static func droppedList(_ dropped: [DroppedFlow]) -> String {
        dropped.map { "    \($0.flow): \($0.reason)" }.joined(separator: "\n")
    }

    // MARK: - Private

    /// One rendered scenario: its path under the app dir and its YAML.
    private struct RenderedScenario {
        let file: String
        let yaml: String
    }

    /// Render every flow, ordered by slug (then by its steps, so equal slugs
    /// order the same way on every run). A repeated slug takes the first
    /// suffix `-2`, `-3`… that no other flow's slug — its own or suffixed —
    /// holds, so "Foo", "Foo" and "Foo 2" write three distinct files. A flow
    /// the formatter refuses is dropped, with its reason, before slugs are
    /// assigned, so it takes none.
    private static func renderScenarios(
        appName: String, flows: [Flow]
    ) throws -> (scenarios: [RenderedScenario], dropped: [DroppedFlow]) {
        var dropped: [DroppedFlow] = []
        let keyed = flows.compactMap { flow -> (slug: String, flow: Flow, body: String)? in
            let slug = slugify(flow.name.isEmpty ? "capture" : flow.name)
            do {
                let body = try ScenarioStepFormatter.scenarioYAML(
                    name: slug, appName: appName, screens: flow.screens)
                return (slug, flow, body)
            } catch {
                dropped.append(DroppedFlow(
                    flow: flow.name.isEmpty ? slug : flow.name,
                    reason: error.localizedDescription))
                return nil
            }
        }
        let ordered = keyed.sorted { ($0.slug, $0.body) < ($1.slug, $1.body) }
        var taken = Set(ordered.map(\.slug))
        var used: Set<String> = []
        let scenarios = try ordered.map { entry -> RenderedScenario in
            var slug = entry.slug
            if used.contains(slug) {
                var suffix = 2
                while taken.contains("\(entry.slug)-\(suffix)") { suffix += 1 }
                slug = "\(entry.slug)-\(suffix)"
                taken.insert(slug)
            }
            used.insert(slug)
            let yaml = slug == entry.slug ? entry.body : try ScenarioStepFormatter.scenarioYAML(
                name: slug, appName: appName, screens: entry.flow.screens)
            return RenderedScenario(file: "scenarios/\(slug).ios.yaml", yaml: yaml)
        }
        let byName = dropped.sorted { ($0.flow, $0.reason) < ($1.flow, $1.reason) }
        return (scenarios, byName)
    }

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
        `target: { kind: ios }`, waiting for each screen a tap reaches.
        `generate_skill` owns those files: re-emitting a flow overwrites its
        `.ios.yaml`, so record a changed walk rather than edit one by hand.
        `mirroir-run` hands that block to
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
}
