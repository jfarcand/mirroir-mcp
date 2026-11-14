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
// ABOUTME: Doctor check reporting which embacle FFI this build linked and whether it is current.
// ABOUTME: Catches a stale libembacle.a silently linked into local builds.

import Foundation
import HelperLib

/// Reports the embacle FFI this binary was built against.
///
/// The FFI is a static library resolved at build time, so a stale
/// `libembacle.a` is linked in silently and nothing at runtime says which
/// version is inside. A local build can therefore drift months behind the tap
/// without a single warning — which is exactly what happened here, unnoticed
/// until a hand-built binary was published.
///
/// Releases are built by CI, which installs the FFI fresh every run, so this
/// check is about local builds telling the truth about themselves.
enum EmbacleVersionCheck {
    /// Homebrew formula providing `libembacle.a`.
    private static let formula = "embacle-ffi"

    /// How long to wait on Homebrew before giving up and saying so.
    private static let brewTimeoutSeconds = 15.0

    static func run() -> DoctorCheck {
        #if EMBACLE
        return linkedBuildCheck()
        #else
        // A valid, documented configuration: no FFI, Apple Vision does the work.
        return DoctorCheck(
            name: "embacle FFI",
            status: .passed,
            detail: "not linked — describe_screen uses local OCR",
            fixHint: nil
        )
        #endif
    }

    /// The build linked the FFI: report the version and whether it is current.
    private static func linkedBuildCheck() -> DoctorCheck {
        guard let installed = brew(["list", "--versions", formula])?
            .split(separator: " ").last.map(String.init) else {
            return DoctorCheck(
                name: "embacle FFI",
                status: .warned,
                detail: "linked, but Homebrew cannot say which version is installed",
                fixHint: "Run `brew list --versions \(formula)`. If it is missing, this "
                    + "binary linked a copy Homebrew no longer tracks — rebuild after "
                    + "`brew install \(formula)`."
            )
        }

        // `brew outdated` prints the formula name when a newer version exists
        // and nothing when current, reading the local tap clone.
        guard let outdated = brew(["outdated", "--quiet", formula]) else {
            return DoctorCheck(
                name: "embacle FFI",
                status: .passed,
                detail: "linked \(installed) (could not check for updates)",
                fixHint: nil
            )
        }

        if outdated.contains(formula) {
            return DoctorCheck(
                name: "embacle FFI",
                status: .warned,
                detail: "linked \(installed), which is behind the tap",
                fixHint: "This build linked a stale FFI. Run "
                    + "`brew upgrade \(formula) && swift build -c release` to relink. "
                    + "Released binaries are unaffected — CI installs the FFI fresh."
            )
        }

        return DoctorCheck(
            name: "embacle FFI",
            status: .passed,
            detail: "linked \(installed) (current)",
            fixHint: nil
        )
    }

    /// Run `brew` with `arguments`, returning trimmed stdout, or nil when
    /// Homebrew is absent, fails, or takes too long.
    private static func brew(_ arguments: [String]) -> String? {
        guard let brewPath = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // `brew` occasionally blocks on its own updates; the check reports
        // "could not check" rather than holding up the whole doctor run.
        let deadline = Date().addingTimeInterval(brewTimeoutSeconds)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
