// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Doctor check listing every prompt file that overrides a built-in AI system prompt.
// ABOUTME: Makes a stale diagnosis.md or screen-describe.md copied by an older installer visible.

import Foundation
import HelperLib

/// Reports each active system-prompt override in the prompt directories.
///
/// An override replaces the built-in prompt entirely, so a file copied into
/// `~/.mirroir-mcp/prompts/` by an older installer keeps shadowing the built-in
/// after every upgrade. Nothing at runtime says so; this check does. Each
/// override is a warning, never a failure: a deliberate customization is valid,
/// and the hint tells the user to delete the file when it is not theirs.
enum PromptOverrideCheck {

    static func run(
        files: [SystemPromptFile] = SystemPromptFile.allCases,
        searchDirs: [String] = PermissionPolicy.promptDirs
    ) -> [DoctorCheck] {
        let overrides = files.compactMap {
            resolvePromptOverride($0, searchDirs: searchDirs)
        }
        guard !overrides.isEmpty else {
            return [DoctorCheck(
                name: "System prompts",
                status: .passed,
                detail: "built-in (no override in \(searchDirs.joined(separator: ", ")))",
                fixHint: nil
            )]
        }
        return overrides.map { override in
            DoctorCheck(
                name: "System prompt override",
                status: .warned,
                detail: "override active: \(override.path)",
                fixHint: "This file replaces the built-in prompt. Delete it unless you wrote it "
                    + "(an older installer copied \(override.file.rawValue) there)."
            )
        }
    }
}
