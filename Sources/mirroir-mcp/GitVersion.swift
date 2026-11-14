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
// ABOUTME: Resolves the git commit hash and timestamp for startup logging.
// ABOUTME: Derives repo path from the executable location inside .build/.

import Foundation

/// Resolves git version info from the repository containing the running binary.
/// The binary lives at `<repo>/.build/debug/mirroir-mcp`, so we walk up to find the repo root.
enum GitVersion {

    /// Short commit hash + timestamp, e.g. "3ffca73 (2026-02-26 14:32)".
    /// Falls back to "unknown" if git is unavailable or the binary isn't inside a repo.
    static let commitHash: String = {
        let repoDir = resolveRepoDir()
        let hash = git(repoDir, "rev-parse", "--short", "HEAD") ?? "unknown"
        let timestamp = git(repoDir, "log", "-1", "--format=%ci") ?? ""
        if timestamp.isEmpty {
            return hash
        }
        // "%ci" returns "2026-02-26 14:32:05 -0500" — trim to "2026-02-26 14:32"
        let trimmed = String(timestamp.prefix(16))
        return "\(hash) (\(trimmed))"
    }()

    /// Walk up from the executable path to find the git repo root.
    /// The binary is at `<repo>/.build/debug/mirroir-mcp`.
    private static func resolveRepoDir() -> String? {
        let execPath = CommandLine.arguments[0]
        var url = URL(fileURLWithPath: execPath).standardized
        // Walk up until we find a .git directory (max 10 levels)
        for _ in 0..<10 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
        }
        return nil
    }

    /// Run a git command in the given repo directory.
    private static func git(_ repoDir: String?, _ args: String...) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var allArgs = args.map { $0 }
        if let dir = repoDir {
            allArgs = ["-C", dir] + allArgs
        }
        process.arguments = allArgs
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
