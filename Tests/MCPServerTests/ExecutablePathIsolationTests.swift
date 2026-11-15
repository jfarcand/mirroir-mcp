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
// ABOUTME: Tests for ExecutablePathIsolation: when a process needs its own executable path, and which run copies are stale.
// ABOUTME: The decisions are pure; the re-exec itself is exercised by two live servers on a Mac.

import XCTest
@testable import mirroir_mcp

final class ExecutablePathIsolationTests: XCTestCase {

    private let runDirectory = URL(fileURLWithPath: "/tmp/mirroir-run")
    private let binary = "/opt/homebrew/bin/mirroir-mcp"

    func testAProcessRunningAloneKeepsItsPath() {
        let live = [ExecutablePathIsolation.RunningProcess(pid: 10, path: binary),
                    ExecutablePathIsolation.RunningProcess(pid: 11, path: "/usr/bin/other")]
        XCTAssertNil(ExecutablePathIsolation.isolatedPath(
            ownPID: 10, ownPath: binary, live: live, runDirectory: runDirectory))
    }

    /// carnet#58: a second live process of the same binary runs from its own
    /// copy, named like the binary, under a directory named for its pid.
    func testASecondProcessOfTheSameBinaryGetsItsOwnCopy() {
        let live = [ExecutablePathIsolation.RunningProcess(pid: 10, path: binary),
                    ExecutablePathIsolation.RunningProcess(pid: 42, path: binary)]
        let path = ExecutablePathIsolation.isolatedPath(
            ownPID: 42, ownPath: binary, live: live, runDirectory: runDirectory)
        XCTAssertEqual(path?.path, "/tmp/mirroir-run/42/mirroir-mcp")
    }

    func testOnlyDirectoriesOfDeadProcessesAreStale() {
        let stale = ExecutablePathIsolation.staleDirectories(
            in: ["42", "77", "notes"], isAlive: { $0 == 42 })
        XCTAssertEqual(stale, ["77"])
    }
}
