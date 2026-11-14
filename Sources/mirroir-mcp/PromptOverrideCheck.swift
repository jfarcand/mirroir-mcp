/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
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
