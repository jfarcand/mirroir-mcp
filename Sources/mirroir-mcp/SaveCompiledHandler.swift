// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: save_compiled's logic: writes the skill's .compiled.json speed cache from the session,
// ABOUTME: and with emit=true also renders the compiled walk into the consumer's .mirroir/ iOS leg.

import Foundation
import HelperLib

/// The business logic behind `save_compiled`; `CompilationTools` owns its schema.
///
/// Two artifacts can come out of one call. The skill's own `.compiled.json`,
/// next to the skill file, is the replay cache standalone `mirroir-mcp test`
/// reads. With `emit`, the same walk is rendered as a `target: { kind: ios }`
/// scenario under `<output_dir>/.mirroir/apps/<app>/`: the runner replays that
/// scenario live, so no `.compiled.json` is ever written into the `.mirroir/`
/// tree (the one the runner keeps there is its own screen-drift baseline).
enum SaveCompiledHandler {

    /// Handle one `save_compiled` call against `session`, reading the device
    /// state the compiled file records from `target`.
    static func handle(
        args: [String: JSONValue], session: CompilationSession, target: any Target
    ) -> MCPToolResult {
        guard let skillName = args["skill_name"]?.asString() else {
            return .error("Missing required parameter: skill_name (string)")
        }
        let emit = args["emit"]?.asBool() ?? false
        let outputDir = args["output_dir"]?.asString()

        let stepCount = session.stepCount
        if stepCount == 0 {
            return .error("No steps recorded. Call record_step before save_compiled.")
        }
        // Replay pairs steps by position, so a gap would shift every later
        // step onto the wrong hints. The session is kept for the retry.
        let missing = session.missingIndices
        if !missing.isEmpty {
            return .error("No step recorded at index \(CompiledSkillIO.describe(missing)). "
                + "Call record_step for "
                + "every step, AI-only ones included, then save_compiled again.")
        }

        // Resolve skill path
        let dirs = PermissionPolicy.skillDirs
        let (resolvedPath, ambiguous) = MirroirMCP.resolveSkill(name: skillName, dirs: dirs)

        guard let skillPath = resolvedPath else {
            if !ambiguous.isEmpty {
                let matches = ambiguous.map { "  - \($0)" }.joined(separator: "\n")
                return .error(
                    "Ambiguous skill name '\(skillName)':\n\(matches)")
            }
            return .error("Skill '\(skillName)' not found")
        }
        return save(skillName: skillName, skillPath: skillPath, emit: emit, outputDir: outputDir,
                    session: session, target: target)
    }

    /// Save the session's steps as the compiled file of the skill at
    /// `skillPath` (asked for as `skillName`) and, with `emit`, render the
    /// walk into `<outputDir>/.mirroir/`. A refusal before the compiled file is
    /// written keeps the session for the retry.
    static func save(
        skillName: String, skillPath: String, emit: Bool, outputDir: String?,
        session: CompilationSession, target: any Target
    ) -> MCPToolResult {
        // A kind:game skill is model-interpreted: it is never compiled
        // to a .compiled.json. Refuse rather than writing a dead artifact.
        if let content = try? String(contentsOfFile: skillPath),
           SkillParser.headerKind(from: content) == "game" {
            return .error(
                "'\(skillName)' is a kind:game skill — model-interpreted and "
                + "never compiled. Run it via the game model loop instead.")
        }

        // A SKILL.md replays only from what was recorded, so each step must hold
        // what it needs to run (a YAML skill keeps its steps in its own file).
        // The session is kept so the AI can record the step again.
        if skillPath.hasSuffix(".md") {
            let problems = MirroirMCP.skillMdReplayProblems(session.recordedSteps)
            if !problems.isEmpty {
                return .error("Cannot save a SKILL.md that would not replay:\n"
                    + problems.joined(separator: "\n")
                    + "\nCall record_step again for these steps, then save_compiled.")
            }
        }

        // A YAML twin's compiled file holds a SKILL.md's only replayable steps.
        // The session is kept so the AI can save under the right name.
        if let owner = CompiledSkillIO.skillMdTwinOwningCompiledFile(for: skillPath) {
            return .error("\(CompiledSkillIO.compiledPath(for: skillPath)) holds the "
                + "recorded steps of \(owner); saving \(skillName) would overwrite them.")
        }

        // The screens are read before compiledSkill clears the session.
        let elementsAfter = session.elementsAfterSteps
        let compiled: CompiledSkill
        do {
            compiled = try compiledSkill(skillPath: skillPath, session: session, target: target)
        } catch {
            return .error("Failed to hash skill file: \(error.localizedDescription)")
        }

        let compiledPath = CompiledSkillIO.compiledPath(for: skillPath)
        let alreadyExists = FileManager.default.fileExists(atPath: compiledPath)
        do {
            try CompiledSkillIO.save(compiled, for: skillPath)
        } catch {
            return .error("Failed to write compiled file: \(error.localizedDescription)")
        }

        let response = savedText(compiled: compiled, compiledPath: compiledPath,
                                 alreadyExists: alreadyExists)
        guard emit else { return .text(response) }
        do {
            let walk = try CompiledWalkBuilder.flow(
                flowName: URL(fileURLWithPath: skillPath).deletingPathExtension().lastPathComponent,
                steps: compiled.steps, elementsAfter: elementsAfter)
            return .text(response + (try ExplorationLoopRunner.emitNote(
                appName: walk.appName, flows: [walk.flow], outputDir: outputDir)))
        } catch {
            return ExplorationLoopRunner.emitFailure(resultText: response, error: error)
        }
    }

    /// The text reporting the `.compiled.json` a call wrote.
    private static func savedText(
        compiled: CompiledSkill, compiledPath: String, alreadyExists: Bool
    ) -> String {
        let steps = compiled.steps
        let compiledSteps = steps.filter { $0.hints != nil }.count
        let passthroughSteps = steps.filter { $0.hints?.compiledAction == .passthrough }.count
        let aiOnlySteps = steps.filter { $0.hints == nil }.count

        var response = "Saved \(compiledPath)\n"
        response += "Steps: \(steps.count) total, \(compiledSteps) compiled, "
        response += "\(passthroughSteps) passthrough, \(aiOnlySteps) AI-only"

        if alreadyExists {
            response += "\nWarning: overwrote existing compiled file"
        }
        if compiled.screenFingerprint == nil {
            response += "\nNote: no start-screen fingerprint saved: get_skill was not "
                + "called for this skill before its first step"
        }
        return response
    }

    /// Build the compiled skill save_compiled writes for `skillPath` from the steps
    /// `session` holds, clearing it. Its fingerprint is the screen get_skill read
    /// before step 1, the moment every producer of a compiled skill fingerprints;
    /// never the screen the run ended on. Each value the skill takes from a `${VAR}`
    /// placeholder is stored as that placeholder, field by field.
    ///
    /// - Throws: the error reading `skillPath` to hash it; the session is then kept.
    static func compiledSkill(
        skillPath: String, session: CompilationSession, target: any Target
    ) throws -> CompiledSkill {
        let sourceHash = try CompiledSkillIO.sha256(of: skillPath)
        let windowInfo = target.bridge.getWindowInfo()
        let fingerprint = session.startFingerprint(for: skillPath)
        let source = (try? String(contentsOfFile: skillPath, encoding: .utf8)) ?? ""
        let steps = session.finalizeAndClear().map { step in
            CompiledStep(
                index: step.index, type: step.type,
                label: step.label.map { MirroirMCP.storedLabel($0, type: step.type, source: source) },
                hints: step.hints)
        }
        return CompiledSkill(
            version: CompiledSkill.currentVersion,
            source: SourceInfo(
                sha256: sourceHash,
                compiledAt: ISO8601DateFormatter().string(from: Date())
            ),
            device: DeviceInfo(
                windowWidth: windowInfo.map { Double($0.size.width) } ?? 0,
                windowHeight: windowInfo.map { Double($0.size.height) } ?? 0,
                orientation: target.bridge.getOrientation()?.rawValue ?? "unknown"
            ),
            steps: steps,
            screenFingerprint: fingerprint
        )
    }
}
