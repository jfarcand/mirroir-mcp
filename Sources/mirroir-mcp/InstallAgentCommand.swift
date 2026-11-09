// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI command that writes the LaunchAgent which keeps `mirroir-mcp serve` running in the login session.
// ABOUTME: Creates the token file when absent and prints the launchctl commands; it starts nothing itself.

import Darwin
import Foundation
import HelperLib

/// Configuration parsed from `install-agent` arguments.
struct InstallAgentConfig: Equatable {
    let port: UInt16
    /// Write the plist to standard output and touch nothing.
    let printOnly: Bool
}

/// Where `install-agent` reads and writes. Tests point it at a temporary directory.
struct InstallAgentPaths: Equatable {
    /// The absolute path this binary was started from, symlinks kept.
    let executable: String
    let plist: String
    let tokenFile: String
    let log: String

    /// The paths of the user running the command.
    static var live: InstallAgentPaths {
        InstallAgentPaths(
            executable: InstallAgentCommand.invokedExecutablePath(),
            plist: NSHomeDirectory() + "/Library/LaunchAgents/\(InstallAgentCommand.label).plist",
            tokenFile: ServeToken.defaultPath,
            log: PermissionPolicy.globalConfigDir + "/serve.log")
    }
}

/// What `install-agent` did: the exit code, and the text for each stream.
struct InstallAgentOutcome: Equatable {
    let exitCode: Int32
    var standardOutput = ""
    var standardError = ""
}

/// Installs the LaunchAgent for `mirroir-mcp serve`.
///
/// A LaunchAgent, not a command typed into an SSH session, because capture and
/// input need the Mac's login session: launchd starts the agent inside it,
/// while a remote shell runs outside it.
///
/// Usage: `mirroir-mcp install-agent [--port N] [--print]`
enum InstallAgentCommand {

    /// The word after `mirroir-mcp`.
    static let commandName = "install-agent"

    /// The launchd label, and the plist's file name.
    static let label = "dev.mirroir.serve"

    static var usage: String {
        """
        Usage: mirroir-mcp install-agent [options]

        Writes ~/Library/LaunchAgents/\(label).plist, which runs `mirroir-mcp serve`
        in your login session, and creates the token file if there is none.
        It does not start the agent: it prints the command that does.

        Options:
          --port <n>   Port the agent serves on (default: \(ServeCommand.defaultPort))
          --print      Print the plist and write nothing
          --help, -h   Show this help
        """
    }

    /// Parse an `install-agent` command line.
    ///
    /// - Throws: `CLIArgumentError` for an unknown option or a missing or bad value.
    static func parseArguments(_ args: [String]) throws -> InstallAgentConfig {
        var port = ServeCommand.defaultPort
        var printOnly = false
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--port":
                i += 1
                guard i < args.count, !args[i].hasPrefix("-") else {
                    throw CLIArgumentError.missingValue(flag: arg)
                }
                port = try ServeCommand.parsePort(args[i], flag: arg)
            case "--print":
                printOnly = true
            default:
                throw CLIArguments.unrecognized(arg, command: commandName)
            }
            i += 1
        }
        return InstallAgentConfig(port: port, printOnly: printOnly)
    }

    static func run(arguments: [String]) -> Int32 {
        let config: InstallAgentConfig
        do {
            config = try parseArguments(arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return CLIDispatch.usageExitCode
        }
        let outcome = install(config: config, paths: .live)
        if !outcome.standardOutput.isEmpty { print(outcome.standardOutput) }
        if !outcome.standardError.isEmpty { fputs(outcome.standardError + "\n", stderr) }
        return outcome.exitCode
    }

    /// The agent's launchd job. It runs in the graphical login session only
    /// (`Aqua`), starts at login, and is restarted when it dies; it never
    /// holds the token, which `serve` reads from its own file.
    static func plist(executable: String, port: UInt16, logPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable, ServeCommand.commandName, "--port", String(port)],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "StandardErrorPath": logPath,
        ]
    }

    /// Write the plist and create the token file, or print the plist.
    static func install(config: InstallAgentConfig, paths: InstallAgentPaths) -> InstallAgentOutcome {
        let resolved = URL(fileURLWithPath: paths.executable).resolvingSymlinksInPath().path
        let channel = InstallChannel.of(executable: resolved) {
            FileManager.default.fileExists(atPath: $0 + "/.git")
        }
        if channel == .npx {
            return InstallAgentOutcome(exitCode: 1, standardError:
                "This copy runs from the npx cache, whose path changes. Install with Homebrew first: "
                + "brew install jfarcand/tap/mirroir-mcp")
        }

        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: plist(executable: paths.executable, port: config.port, logPath: paths.log),
                format: .xml, options: 0)
        } catch {
            return InstallAgentOutcome(exitCode: 1, standardError: "Error: the plist could not be built: \(error)")
        }
        if config.printOnly {
            return InstallAgentOutcome(
                exitCode: 0, standardOutput: String(decoding: data, as: UTF8.self))
        }

        do {
            // Read it back, new or not: a token file `serve` would refuse must
            // fail here, not every ten seconds under launchd.
            _ = try ServeToken.create(path: paths.tokenFile)
            _ = try ServeToken.load(path: paths.tokenFile)
            try FileManager.default.createDirectory(
                atPath: (paths.plist as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: paths.plist), options: .atomic)
        } catch {
            return InstallAgentOutcome(exitCode: 1, standardError: "Error: \(error.localizedDescription)")
        }
        return InstallAgentOutcome(exitCode: 0, standardOutput: """
            Wrote \(paths.plist).
            Start it: launchctl bootstrap gui/$(id -u) \(paths.plist)
            Stop it:  launchctl bootout gui/$(id -u)/\(label)
            The token is in \(paths.tokenFile); give it to your MCP client as the header
            Authorization: Bearer <token>.
            The agent serves http://\(NetworkHTTPServer.loopbackHost):\(config.port)\(MCPHTTPEndpoint.path) \
            and logs to \(paths.log).
            """)
    }

    /// The absolute path this process was started from, with symlinks kept, so
    /// a Homebrew path (`/opt/homebrew/bin/mirroir-mcp`) still names the
    /// binary after an upgrade moves the file it points to.
    static func invokedExecutablePath() -> String {
        var size = UInt32(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: Int(size))
        let raw = _NSGetExecutablePath(&buffer, &size) == 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : CommandLine.arguments[0]
        let absolute = raw.hasPrefix("/")
            ? raw : FileManager.default.currentDirectoryPath + "/" + raw
        // `standardized` drops `.` and `..` without resolving symlinks.
        return URL(fileURLWithPath: absolute).standardized.path
    }
}
