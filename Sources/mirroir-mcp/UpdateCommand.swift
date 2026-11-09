// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI command that upgrades mirroir-mcp the way it was installed: Homebrew, a source checkout, npx or an MCP bundle.
// ABOUTME: The channel is read from where the running binary lives; --dry-run prints the upgrade without running it.

import Foundation
import HelperLib

/// How this copy of mirroir-mcp was installed, read from its executable path.
enum InstallChannel: Equatable {
    case homebrew
    /// A git checkout built with `mirroir.sh` or the curl installer; the path is its root.
    case source(root: String)
    case npx
    case mcpBundle
    case unknown

    /// The channel of the binary at `executable` (symlinks already resolved).
    /// `isGitCheckout` says whether a directory holds a `.git`.
    static func of(executable: String, isGitCheckout: (String) -> Bool) -> InstallChannel {
        if executable.contains("/Cellar/mirroir-mcp/") { return .homebrew }
        if executable.contains("/_npx/") || executable.contains("/node_modules/mirroir-mcp/") { return .npx }
        if executable.contains("/Claude Extensions/") { return .mcpBundle }
        if let range = executable.range(of: "/.build/") {
            let root = String(executable[..<range.lowerBound])
            if isGitCheckout(root) { return .source(root: root) }
        }
        return .unknown
    }

    /// The shell command that upgrades this channel, or nil when the upgrade
    /// is a manual step.
    var command: String? {
        switch self {
        case .homebrew: return "brew upgrade mirroir-mcp"
        case .source(let root): return "git -C '\(root)' pull --ff-only && cd '\(root)' && ./mirroir.sh"
        case .npx, .mcpBundle, .unknown: return nil
        }
    }

    /// What to do for this channel, in one or two sentences.
    var advice: String {
        switch self {
        case .homebrew:
            return "Installed with Homebrew."
        case .source(let root):
            return "Installed from the source checkout at \(root)."
        case .npx:
            return "Run through npx, which keeps using the copy it cached. Point your MCP config at "
                + "`npx -y mirroir-mcp@latest` so each start fetches the newest release."
        case .mcpBundle:
            return "Installed as an MCP bundle. Download the newest mirroir-mcp.mcpb from "
                + "https://github.com/jfarcand/mirroir-mcp/releases/latest and open it."
        case .unknown:
            return "The install channel could not be told from this binary's path. Reinstall with "
                + "the method you used first (see https://github.com/jfarcand/mirroir-mcp#install)."
        }
    }
}

/// Upgrades this install.
///
/// Usage: `mirroir-mcp update [--dry-run] [--help]`
enum UpdateCommand {

    /// The option that prints the upgrade command without running it.
    static let dryRunOption = "--dry-run"

    /// Refuse anything but `--dry-run`: a mistyped option must never start an upgrade.
    ///
    /// - Throws: `CLIArgumentError` naming the argument this command does not take.
    static func validate(_ arguments: [String]) throws {
        try CLIArguments.requireOnly([dryRunOption], in: arguments, command: "update")
    }

    /// Upgrade this install. Returns the upgrade command's exit code, or 2 for
    /// refused arguments.
    static func run(arguments: [String]) -> Int32 {
        do {
            try validate(arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return CLIDispatch.usageExitCode
        }
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
        let channel = InstallChannel.of(executable: executable) { root in
            FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git"))
        }
        fputs("mirroir-mcp \(MirroirVersion.current). \(channel.advice)\n", stderr)
        guard let command = channel.command else { return 0 }
        if arguments.contains(dryRunOption) {
            fputs("Would run: \(command)\n", stderr)
            return 0
        }
        fputs("Running: \(command)\n", stderr)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        do {
            try process.run()
        } catch {
            fputs("Could not run the upgrade: \(error.localizedDescription)\n", stderr)
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The command's usage text.
    static var usage: String {
        """
            Usage: mirroir-mcp update [--dry-run]

            Upgrades mirroir-mcp the way it was installed: `brew upgrade` for Homebrew,
            `git pull` and `mirroir.sh` for a source checkout. For npx and MCP bundles
            it says what to change instead.

            --dry-run   Print the upgrade command without running it
            """
    }
}
