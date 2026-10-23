// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Built-in AI diagnosis system prompt and the loader that lets a prompt file override a built-in.
// ABOUTME: A same-named file in <cwd>/.mirroir-mcp/prompts/ or ~/.mirroir-mcp/prompts/ replaces the built-in.

import Foundation
import HelperLib

/// Every built-in system prompt a same-named file in the prompt directories can override.
/// The raw value is the override filename; `loadSystemPrompt` and the doctor's
/// `PromptOverrideCheck` both read this one registry.
enum SystemPromptFile: String, CaseIterable {
    /// The failure-diagnosis prompt sent by every AI agent provider.
    case diagnosis = "diagnosis.md"
    /// The vision prompt sent by `VisionScreenDescriber`.
    case screenDescribe = "screen-describe.md"

    /// The prompt used when no override file exists.
    var builtIn: String {
        switch self {
        case .diagnosis: aiDiagnosisDefaultPrompt
        case .screenDescribe: VisionScreenDescriber.defaultSystemPrompt
        }
    }
}

/// Built-in system prompt for AI diagnosis of failed skill steps. Its input section
/// mirrors `DiagnosticPayload` field-for-field; its response section mirrors `AIDiagnosis`.
let aiDiagnosisDefaultPrompt = """
    # iOS UI Automation Failure Diagnosis

    You are an expert iOS UI automation debugger analyzing a failed test skill
    from **mirroir-mcp**, a tool that replays YAML skills against
    iPhone Mirroring on macOS.

    ## Context

    You will receive a JSON payload containing:

    - **skillName**: The name of the skill that failed
    - **skillFilePath**: Path to the source YAML file
    - **failedSteps**: Array of steps that failed, each with:
      - `stepIndex`: Zero-based step number
      - `stepType`: The action type (`tap`, `wait_for`, `assert_visible`, `scroll_to`, etc.)
      - `label`: The UI element label being targeted (absent for steps without one)
      - `deterministicDiagnosis`: What the OCR-based analysis found (element moved, missing, timing, etc.)
      - `patches`: Suggested coordinate/timing fixes from deterministic analysis, each with
        `field`, `was`, and `shouldBe`

    ## Your Task

    Analyze the failure context and provide:

    1. **ROOT CAUSE** -- What specifically went wrong and why. Consider:
       - Wrong screen (previous navigation failed silently)
       - iOS version change shifted UI layout
       - Dynamic content (notifications, badges) displaced elements
       - Timing issue (animation not settled, network delay)
       - Resolution/orientation mismatch

    2. **FIX** -- Concrete actionable fix:
       - Coordinate changes with specific values
       - Timing adjustments (increase delay, add wait_for step)
       - Skill edits (add intermediate navigation, change step order)

    3. **CONFIDENCE** -- `high`, `medium`, or `low`

    ## Response Format

    Respond **only** in JSON:

    ```json
    {
      "analysis": "Clear explanation of root cause",
      "suggested_fixes": [
        {
          "field": "tapX",
          "was": "100.0",
          "should_be": "150.0"
        }
      ],
      "confidence": "high"
    }
    ```

    If no fixes are applicable, return an empty `suggested_fixes` array.
    """

/// Load a system prompt, preferring an override file over `file.builtIn`.
/// Resolution order: each of `searchDirs` in turn (project-local `<cwd>/.mirroir-mcp/prompts/`,
/// then global `~/.mirroir-mcp/prompts/`), then the built-in. An empty override file is ignored.
func loadSystemPrompt(
    _ file: SystemPromptFile = .diagnosis,
    searchDirs: [String] = PermissionPolicy.promptDirs
) -> String {
    resolvePromptOverride(file, searchDirs: searchDirs)?.content ?? file.builtIn
}

/// An override file that replaces a built-in system prompt.
struct PromptOverride: Equatable {
    /// The built-in prompt this file replaces.
    let file: SystemPromptFile
    /// Path of the override file.
    let path: String
    /// The file's text, used verbatim as the system prompt.
    let content: String
}

/// Find the file that overrides the built-in prompt `file`: the first non-empty file
/// named `file.rawValue` across `searchDirs`, in order. Returns nil when the built-in
/// prompt is in effect.
func resolvePromptOverride(
    _ file: SystemPromptFile,
    searchDirs: [String] = PermissionPolicy.promptDirs
) -> PromptOverride? {
    for dir in searchDirs {
        let path = dir + "/" + file.rawValue
        if let data = FileManager.default.contents(atPath: path),
           let content = String(data: data, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PromptOverride(file: file, path: path, content: content)
        }
    }
    return nil
}
