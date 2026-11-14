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
// ABOUTME: Resolves the consumer-repo .mirroir/ root where the iOS oracle leg is emitted.
// ABOUTME: Walks up from cwd for an existing .mirroir/, else falls back to <cwd>/.mirroir.

import Foundation

/// Locates the consumer repository's `.mirroir/` dotfile directory — the runner's
/// consumer root, distinct from the Swift MCP's `~/.mirroir-mcp/` home. Mirrors the
/// runner's own walk-up discovery (`runner/src/mirroir/discover.rs`).
enum MirroirRootLocator {

    /// Directory name of the consumer-side mirroir tree.
    static let dirName = ".mirroir"

    /// Resolve the `.mirroir/` directory to emit into. Resolution order:
    /// 1. `explicitDir` (a `generate_skill output_dir` arg), if given → `<explicitDir>/.mirroir`.
    /// 2. The nearest existing `.mirroir/` walking up from `start` (the process cwd).
    /// 3. `<start>/.mirroir`.
    ///
    /// Returns `nil` when the resolved target would be `~/.mirroir` — that is the
    /// runner's pack home (`~/.mirroir/skills/`), not a consumer dotfile, so the
    /// caller must pass an `output_dir` or run from a consumer repo. Does not create
    /// the directory.
    static func resolve(explicitDir: String? = nil, start: URL? = nil) -> URL? {
        let target: URL
        if let explicitDir, !explicitDir.isEmpty {
            target = URL(fileURLWithPath: explicitDir, isDirectory: true)
                .appendingPathComponent(dirName, isDirectory: true)
        } else {
            let base = start ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            target = walkUp(from: base) ?? base.appendingPathComponent(dirName, isDirectory: true)
        }
        let homeMirroir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(dirName, isDirectory: true).standardizedFileURL
        return target.standardizedFileURL.path == homeMirroir.path ? nil : target
    }

    /// Walk up from `base` returning the nearest existing `.mirroir/`, or nil.
    ///
    /// Walks on path strings rather than `URL.deletingLastPathComponent()`.
    /// `FileManager.homeDirectoryForCurrentUser` (a common `base`) is a
    /// directory-form URL with a trailing slash, and `deletingLastPathComponent()`
    /// on that form never settles at `/` — it keeps appending `..`, so a
    /// `parent == current` terminator spins forever. `NSString` path semantics plus
    /// an explicit root check terminate unambiguously for any URL form.
    private static func walkUp(from base: URL) -> URL? {
        var dir = base.standardizedFileURL.path
        while !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: candidate, isDirectory: true)
            }
            if dir == "/" { return nil } // reached the filesystem root
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
