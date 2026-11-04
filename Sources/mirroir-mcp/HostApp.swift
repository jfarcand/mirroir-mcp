// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Names the Mac app that holds this process's privacy grants: the outermost .app among its ancestors.
// ABOUTME: Doctor's permission hints say "turn on iTerm" or "turn on Claude" instead of "your terminal app".

import Darwin
import Foundation

/// macOS grants Screen Recording and Accessibility to an app, not to the
/// mirroir binary: the terminal, editor or desktop client that started it.
/// That app is the outermost `.app` bundle among this process's ancestors
/// (mirroir-mcp ← zsh ← iTerm.app, or mirroir-mcp ← node ← Claude.app).
enum HostApp {

    /// The bundle path of the host app, given the executable paths of a
    /// process chain ordered from this process up to launchd. The outermost
    /// process inside a bundle wins, and within its path the outermost
    /// bundle (`Claude.app`, not the helper app nested in it).
    static func bundlePath(chain: [String]) -> String? {
        for executable in chain.reversed() {
            let components = (executable as NSString).pathComponents
            guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { continue }
            return NSString.path(withComponents: Array(components[...index]))
        }
        return nil
    }

    /// The name System Settings lists for the bundle at `path`: its file
    /// name without the `.app` extension.
    static func displayName(bundlePath path: String) -> String {
        let file = (path as NSString).lastPathComponent
        return file.hasSuffix(".app") ? String(file.dropLast(".app".count)) : file
    }

    /// The host app of the running process, or nil when no ancestor is an
    /// app (an ssh session, launchd).
    static var current: String? {
        bundlePath(chain: liveChain()).map { displayName(bundlePath: $0) }
    }

    /// Executable paths from this process up to launchd.
    static func liveChain() -> [String] {
        var chain: [String] = []
        var pid = getpid()
        var visited: Set<pid_t> = []
        while pid > 1, visited.insert(pid).inserted {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                chain.append(String(cString: buffer))
            }
            guard let parent = parentPID(of: pid) else { break }
            pid = parent
        }
        return chain
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
