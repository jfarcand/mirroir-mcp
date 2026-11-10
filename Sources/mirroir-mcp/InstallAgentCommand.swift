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
    /// The app bundle the agent runs from, built around a copy of `executable`.
    let bundle: String
    let plist: String
    let tokenFile: String
    let log: String

    /// The paths of the user running the command.
    static var live: InstallAgentPaths {
        InstallAgentPaths(
            executable: InstallAgentCommand.invokedExecutablePath(),
            bundle: PermissionPolicy.globalConfigDir + "/\(ServeAppBundle.displayName).app",
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
        The agent runs from its own copy of this binary, in the app bundle
        ~/.mirroir-mcp/\(ServeAppBundle.displayName).app, so macOS lists it by name
        and icon when it asks for Accessibility and Screen Recording. The bundle
        is signed with a self-signed certificate it keeps in your login keychain,
        so those grants hold across upgrades. Run install-agent again after
        upgrading mirroir-mcp.
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
        let outcome = install(config: config, paths: .live, sign: ServeSigningIdentity.signWithLocalIdentity)
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

    /// Write the plist, the app bundle and the token file, or print the plist.
    ///
    /// - Parameters:
    ///   - sign: signs the app bundle; `ServeSigningIdentity.signWithLocalIdentity` outside tests.
    ///   - isAdHocSigned: whether the bundle already in place is signed ad hoc,
    ///     so its grants are tied to that one build.
    static func install(config: InstallAgentConfig, paths: InstallAgentPaths,
                        sign: (String) -> String?,
                        isAdHocSigned: (String) -> Bool = ServeSigningIdentity.isAdHocSigned) -> InstallAgentOutcome {
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
                fromPropertyList: plist(executable: ServeAppBundle.executablePath(in: paths.bundle),
                                        port: config.port, logPath: paths.log),
                format: .xml, options: 0)
        } catch {
            return InstallAgentOutcome(exitCode: 1, standardError: "Error: the plist could not be built: \(error)")
        }
        if config.printOnly {
            return InstallAgentOutcome(
                exitCode: 0, standardOutput: String(decoding: data, as: UTF8.self))
        }

        let replacesAdHoc = isAdHocSigned(paths.bundle)
        do {
            // Read it back, new or not: a token file `serve` would refuse must
            // fail here, not every ten seconds under launchd.
            _ = try ServeToken.create(path: paths.tokenFile)
            _ = try ServeToken.load(path: paths.tokenFile)
            try FileManager.default.createDirectory(
                atPath: (paths.bundle as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try ServeAppBundle.build(at: paths.bundle, executable: resolved, version: MirroirVersion.current, sign: sign)
            try FileManager.default.createDirectory(
                atPath: (paths.plist as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: paths.plist), options: .atomic)
        } catch {
            return InstallAgentOutcome(exitCode: 1, standardError: "Error: \(error.localizedDescription)")
        }
        var text = """
            Wrote \(paths.plist) and \(paths.bundle).
            Start it: launchctl bootstrap gui/$(id -u) \(paths.plist)
            Stop it:  launchctl bootout gui/$(id -u)/\(label)
            The token is in \(paths.tokenFile); give it to your MCP client as the header
            Authorization: Bearer <token>.
            The agent serves http://\(NetworkHTTPServer.loopbackHost):\(config.port)\(MCPHTTPEndpoint.path) \
            and logs to \(paths.log).
            \(grantText)
            """
        if replacesAdHoc { text += "\n" + adHocResetText }
        return InstallAgentOutcome(exitCode: 0, standardOutput: text)
    }

    /// How the agent gets its grants, and why an upgrade keeps them.
    static var grantText: String {
        """
        The bundle is signed with the certificate "\(ServeSigningIdentity.commonName)" in your login \
        keychain; the first time, macOS asks whether codesign may use it: choose Always Allow. \
        Turn on "\(ServeAppBundle.displayName)" in System Settings > Privacy & Security > Accessibility \
        and Screen Recording. macOS asks the first time the agent needs them, or lists it switched off. \
        The grants follow the certificate, not the build: after upgrading mirroir-mcp, run \
        install-agent again, then: launchctl kickstart -k gui/$(id -u)/\(label)
        """
    }

    /// The one-time step for a bundle an older install-agent signed ad hoc:
    /// its grants are pinned to that build, and turning the switch off and on
    /// keeps the old pin, so the entries must go before the new ones can be made.
    static var adHocResetText: String {
        """
        The bundle this replaced was signed for its build only, and its grants stay tied to that build. \
        Remove them once: tccutil reset All \(ServeAppBundle.identifier), then restart the agent and \
        turn "\(ServeAppBundle.displayName)" on again in both panes.
        """
    }

    /// The absolute path this process was started from, with symlinks kept.
    /// `install` resolves it to find the install channel and the file it copies.
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
