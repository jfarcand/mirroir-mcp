// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Names what holds this process's privacy grants: the process macOS holds responsible for it.
// ABOUTME: Doctor's and check_health's hints say "turn on iTerm" or "turn on mirroir-mcp" instead of "your terminal app".

import Darwin
import Foundation

/// macOS checks Screen Recording and Accessibility against the process it
/// holds *responsible* for mirroir-mcp, which is not always an ancestor app.
/// A terminal or an editor is responsible for what it starts (mirroir-mcp ←
/// zsh ← iTerm.app is granted through iTerm), but Claude starts its servers
/// through a helper that disclaims responsibility, so each server is
/// responsible for itself and the grant goes to mirroir-mcp. launchd jobs, the
/// serve agent among them, are responsible for themselves as well.
enum HostApp {

    /// What the privacy panes list for this process, and how a new Screen
    /// Recording grant reaches it.
    enum Grantee: Equatable {
        /// An app that started mirroir-mcp and answers for it: a terminal,
        /// an editor, an AI client. The grant takes effect once it reopens.
        case app(name: String)
        /// The serve LaunchAgent's own bundle, restarted through launchctl.
        case serveAgent
        /// mirroir-mcp answers for itself: the panes list it under `name`,
        /// and the app that started it must reopen to start it again.
        case server(name: String)

        /// The name System Settings lists.
        var displayName: String {
            switch self {
            case .app(let name), .server(let name): return name
            case .serveAgent: return ServeAppBundle.displayName
            }
        }
    }

    /// The private libquarantine call that names a process's responsible
    /// process; resolved at run time because no SDK header declares it.
    private typealias ResponsibleForPID = @convention(c) (pid_t) -> pid_t
    private static let responsibleSymbol = "responsibility_get_pid_responsible_for_pid"
    /// `RTLD_DEFAULT`, which Swift does not import: search every loaded image.
    private static var everyLoadedImage: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: -2) }

    /// Who holds the grants, given the executable path of the responsible
    /// process and whether that process is this one.
    ///
    /// - Returns: nil when the responsible process is neither this server nor
    ///   inside an app (an ssh session, a bare launchd job).
    static func grantee(responsiblePath: String, isSelf: Bool) -> Grantee? {
        let bundle = bundlePath(executable: responsiblePath)
        if isSelf {
            guard let bundle else {
                return .server(name: (responsiblePath as NSString).lastPathComponent)
            }
            let name = displayName(bundlePath: bundle)
            return name == ServeAppBundle.displayName ? .serveAgent : .server(name: name)
        }
        return bundle.map { .app(name: displayName(bundlePath: $0)) }
    }

    /// The outermost `.app` bundle containing `executable` (`Claude.app`, not
    /// the helper app nested in it), or nil when it is in none.
    static func bundlePath(executable: String) -> String? {
        let components = (executable as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...index]))
    }

    /// The name System Settings lists for the bundle at `path`: its file
    /// name without the `.app` extension.
    static func displayName(bundlePath path: String) -> String {
        let file = (path as NSString).lastPathComponent
        return file.hasSuffix(".app") ? String(file.dropLast(".app".count)) : file
    }

    /// Who holds the running process's grants, or nil when macOS names no
    /// responsible process or it is neither this server nor an app.
    static var current: Grantee? {
        let pid = getpid()
        guard let responsible = responsiblePID(of: pid), let path = executablePath(of: responsible) else {
            return nil
        }
        return grantee(responsiblePath: path, isSelf: responsible == pid)
    }

    /// The process macOS holds responsible for `pid`, or nil when the call is
    /// unavailable or fails.
    static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let symbol = dlsym(everyLoadedImage, responsibleSymbol) else { return nil }
        let call = unsafeBitCast(symbol, to: ResponsibleForPID.self)
        let responsible = call(pid)
        return responsible > 0 ? responsible : nil
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
