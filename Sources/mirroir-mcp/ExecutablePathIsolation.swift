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
// ABOUTME: Runs a second mirroir-mcp process of one binary from its own copy, so ScreenCaptureKit serves both.
// ABOUTME: replayd keys capture clients by executable path; two processes of one path knock each other off (carnet#58).

import Darwin
import Foundation
import HelperLib

/// Gives this process an executable path no other live process has.
///
/// `replayd` identifies ScreenCaptureKit clients by executable path, so two
/// live processes of the same binary interrupt each other's connection and
/// every capture ends with its handler released unanswered
/// (`WindowShotFailure.handlerDropped`). Two Claude sessions each starting the
/// stdio server, or a `mirroir-mcp test` run next to a server, hit it. A
/// process that finds another one at its own path re-executes itself from a
/// copy under `runDirectory/<pid>/`, which replayd sees as a separate client:
/// a copy captured 5 of 5 next to a live server (carnet#24), where a hard
/// link to the same file still lost every capture (2026-11-14). The copy
/// keeps the binary's name, so tools that look for `mirroir-mcp` by name
/// still find it.
enum ExecutablePathIsolation {

    /// Set on the re-executed process, so it never re-executes again.
    static let isolatedEnvironmentKey = "MIRROIR_PATH_ISOLATED"

    /// Where the per-process copies live.
    static var runDirectory: URL {
        URL(fileURLWithPath: PermissionPolicy.globalConfigDir).appendingPathComponent("run")
    }

    /// One live process and the executable it runs.
    struct RunningProcess: Equatable {
        let pid: pid_t
        let path: String
    }

    /// The path this process should run from instead of `ownPath`, or nil
    /// when no other live process runs `ownPath`.
    static func isolatedPath(ownPID: pid_t, ownPath: String, live: [RunningProcess],
                             runDirectory: URL) -> URL? {
        guard live.contains(where: { $0.pid != ownPID && $0.path == ownPath }) else { return nil }
        return runDirectory
            .appendingPathComponent(String(ownPID))
            .appendingPathComponent(URL(fileURLWithPath: ownPath).lastPathComponent)
    }

    /// The per-process directories under `runDirectory` whose process is gone.
    static func staleDirectories(in names: [String], isAlive: (pid_t) -> Bool) -> [String] {
        names.filter { name in
            guard let pid = pid_t(name) else { return false }
            return !isAlive(pid)
        }
    }

    /// Re-execute this process from its own copy when another live process
    /// runs the same executable. Returns only when it did not re-execute:
    /// alone, already isolated, or the copy could not be made (logged).
    static func isolateIfShared(arguments: [String] = CommandLine.arguments) {
        guard ProcessInfo.processInfo.environment[isolatedEnvironmentKey] == nil,
              let ownPath = executablePath(of: getpid()) else { return }
        let directory = runDirectory
        removeStaleCopies(in: directory)
        guard let target = isolatedPath(ownPID: getpid(), ownPath: ownPath,
                                        live: runningProcesses(), runDirectory: directory) else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            if !manager.fileExists(atPath: target.path) {
                try manager.copyItem(atPath: ownPath, toPath: target.path)
            }
        } catch {
            DebugLog.persist("startup", "another process runs \(ownPath); its own copy failed: \(error)")
            return
        }
        DebugLog.persist("startup", "another process runs \(ownPath); re-executing from \(target.path)")
        setenv(isolatedEnvironmentKey, "1", 1)
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv[0] = strdup(target.path)
        argv.append(nil)
        execv(target.path, argv)
        DebugLog.persist("startup", "re-executing from \(target.path) failed: errno \(errno)")
        unsetenv(isolatedEnvironmentKey)
    }

    private static func removeStaleCopies(in directory: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in staleDirectories(in: names, isAlive: { kill($0, 0) == 0 || errno == EPERM }) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Every live process this user can see, with its executable path.
    private static func runningProcesses() -> [RunningProcess] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: max(capacity, 0))
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(count, 0)).compactMap { pid in
            executablePath(of: pid).map { RunningProcess(pid: pid, path: $0) }
        }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
