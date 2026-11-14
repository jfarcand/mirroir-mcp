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
// ABOUTME: Reads .github/workflows/release.yml for the order its jobs put the version bump on main.
// ABOUTME: The plugin's npx pin reaches main only after npm serves that version.

import Foundation
import XCTest

final class ReleaseWorkflowOrderTests: XCTestCase {

    private static let workflowURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".github/workflows/release.yml")

    /// The text of each job, keyed by its id: the lines from `  <id>:` to the next job.
    private static func jobs() throws -> [String: String] {
        let text = try String(contentsOf: workflowURL, encoding: .utf8)
        guard let jobsStart = text.range(of: "\njobs:\n") else { return [:] }
        var jobs: [String: String] = [:]
        var current: String?
        for line in text[jobsStart.upperBound...].components(separatedBy: "\n") {
            let isJobHeader = line.hasPrefix("  ") && !line.hasPrefix("   ")
                && line.hasSuffix(":") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            if isJobHeader {
                current = String(line.dropFirst(2).dropLast())
                continue
            }
            if let current { jobs[current, default: ""] += line + "\n" }
        }
        return jobs
    }

    func testTheReleaseJobPushesTheBumpOnlyAsTheTag() throws {
        let release = try XCTUnwrap(try Self.jobs()["release"])
        XCTAssertTrue(release.contains("git push origin \"HEAD:refs/tags/v$VERSION\""))
        XCTAssertFalse(release.contains("git push origin main"),
                       "main must not get the npx pin before npm serves the version")
    }

    func testMainGetsTheBumpAfterNpmServesTheVersion() throws {
        let jobs = try Self.jobs()
        let push = try XCTUnwrap(jobs["push-version-to-main"])
        XCTAssertTrue(push.contains("needs: [release, publish-npm]"), push)
        XCTAssertTrue(push.contains("git push origin \"HEAD:$DEFAULT_BRANCH\""), push)
        let npm = try XCTUnwrap(jobs["publish-npm"])
        XCTAssertTrue(npm.contains("npm view \"mirroir-mcp@$VERSION\" version"),
                      "publish-npm succeeds only once npm serves the version")
    }
}
