// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The table of mirroir-mcp subcommands and the routing of a command line to one of them or to the server.
// ABOUTME: Help, refusals and their exit codes are decided here, so every subcommand behaves the same way.

import Darwin
import Foundation
import HelperLib

/// One subcommand of the mirroir-mcp binary.
struct CLISubcommand: Sendable {
    /// The word after `mirroir-mcp`.
    let name: String
    /// One line for the top-level usage.
    let summary: String
    /// The command's full usage text.
    let usage: @Sendable () -> String
    /// Throws for a command line the command refuses. Reads arguments only:
    /// it starts nothing and writes nothing.
    let validate: @Sendable ([String]) throws -> Void
    /// Runs a command line `validate` accepted, and returns the exit code.
    let run: @Sendable ([String]) -> Int32
}

/// Routes a command line: to a subcommand, to the usage text, or to the MCP server.
enum CLIDispatch {

    /// Exit code for a command line the binary refuses, as distinct from 1, a
    /// command that ran and failed.
    static let usageExitCode: Int32 = 2

    /// Turns on verbose logging for the server and for every subcommand.
    static let debugOption = "--debug"

    /// Prints the version and exits.
    static let versionOption = "--version"

    /// The options the server itself takes.
    static let serverOptions: Set<String> = PermissionPolicy.skipPermissionsOptions

    /// Every subcommand, in the order the usage text lists them.
    static let subcommands: [CLISubcommand] = [
        CLISubcommand(
            name: "test", summary: "Run skills against iPhone Mirroring and report each verdict",
            usage: { TestRunner.usage },
            validate: { _ = try TestRunner.parseArguments($0) },
            run: TestRunner.run(arguments:)),
        CLISubcommand(
            name: "record", summary: "Record a walk on the iPhone as a replayable scenario",
            usage: { RecordCommand.usage },
            validate: { _ = try RecordCommand.parseArguments($0) },
            run: RecordCommand.run(arguments:)),
        CLISubcommand(
            name: "compile", summary: "Run skills on the device and save their compiled replay",
            usage: { CompileCommand.usage },
            validate: { _ = try CompileCommand.parseArguments($0) },
            run: CompileCommand.run(arguments:)),
        CLISubcommand(
            name: "migrate", summary: "Convert YAML skills to SKILL.md",
            usage: { MigrateCommand.usage },
            validate: { _ = try MigrateCommand.parseArguments($0) },
            run: MigrateCommand.run(arguments:)),
        CLISubcommand(
            name: "doctor", summary: "Check every prerequisite and name the fix for each failure",
            usage: { DoctorCommand.usage },
            validate: { _ = try DoctorCommand.parseArguments($0) },
            run: DoctorCommand.run(arguments:)),
        CLISubcommand(
            name: "update", summary: "Upgrade mirroir-mcp the way it was installed",
            usage: { UpdateCommand.usage },
            validate: UpdateCommand.validate,
            run: UpdateCommand.run(arguments:)),
        CLISubcommand(
            name: "skill", summary: "Print or install the agent operating manual",
            usage: { SkillCommand.usage },
            validate: SkillCommand.validate,
            run: SkillCommand.run(arguments:)),
        CLISubcommand(
            name: "configure", summary: "Choose the iPhone keyboard layout",
            usage: { ConfigureCommand.usage },
            validate: ConfigureCommand.validate,
            run: ConfigureCommand.run(arguments:)),
        CLISubcommand(
            name: AXCaptureCommand.commandName,
            summary: "Save the iPhone Mirroring window's Accessibility tree as a test fixture",
            usage: { AXCaptureCommand.usage },
            validate: { _ = try AXCaptureCommand.parseArguments($0) },
            run: AXCaptureCommand.run(arguments:)),
        CLISubcommand(
            name: ServeCommand.commandName,
            summary: "Serve the MCP tools over HTTP on loopback, behind a bearer token",
            usage: { ServeCommand.usage },
            validate: { _ = try ServeCommand.parseArguments($0) },
            run: ServeCommand.run(arguments:)),
        CLISubcommand(
            name: InstallAgentCommand.commandName,
            summary: "Write the LaunchAgent that keeps serve running in your login session",
            usage: { InstallAgentCommand.usage },
            validate: { _ = try InstallAgentCommand.parseArguments($0) },
            run: InstallAgentCommand.run(arguments:)),
    ]

    /// Where a command line goes.
    enum Route {
        /// Start the MCP server on stdio, with the server options given.
        case server(arguments: [String])
        /// Print the top-level usage.
        case help
        /// Print the version.
        case version
        /// Hand the remaining arguments to a subcommand.
        case subcommand(CLISubcommand, arguments: [String])
        /// Refuse the command line, with the reason.
        case refused(String)
    }

    /// Route the arguments after the executable name. `--debug` is global and
    /// is removed first. With no command the binary is the MCP server, so an
    /// unknown first word is refused instead of starting a server nobody asked for.
    static func route(_ arguments: [String]) -> Route {
        let args = arguments.filter { $0 != debugOption }
        guard let first = args.first else { return .server(arguments: []) }
        if let command = subcommands.first(where: { $0.name == first }) {
            return .subcommand(command, arguments: Array(args.dropFirst()))
        }
        if CLIArguments.helpOptions.contains(first) { return .help }
        if first == versionOption { return .version }
        guard first.hasPrefix("-") else {
            return .refused("unknown command '\(first)' (see mirroir-mcp --help)")
        }
        if let stray = args.first(where: { !serverOptions.contains($0) }) {
            let kind = stray.hasPrefix("-") ? "unknown option" : "unexpected argument"
            return .refused("\(kind) '\(stray)' (see mirroir-mcp --help)")
        }
        return .server(arguments: args)
    }

    /// What to do with a subcommand's arguments before running it.
    enum Preflight: Equatable {
        case help
        case refused(String)
        case run
    }

    /// Help anywhere in the arguments wins; otherwise the command's own
    /// validation decides between running and refusing.
    static func preflight(_ command: CLISubcommand, _ arguments: [String]) -> Preflight {
        if CLIArguments.wantsHelp(arguments) { return .help }
        do {
            try command.validate(arguments)
            return .run
        } catch {
            return .refused(error.localizedDescription)
        }
    }

    /// Run a subcommand: usage and 0 for help, the reason and `usageExitCode`
    /// for a refused command line, the command's own exit code otherwise.
    static func execute(_ command: CLISubcommand, _ arguments: [String]) -> Int32 {
        switch preflight(command, arguments) {
        case .help:
            fputs(command.usage() + "\n", stderr)
            return 0
        case .refused(let message):
            fputs("Error: \(message)\n", stderr)
            return usageExitCode
        case .run:
            return command.run(arguments)
        }
    }

    /// The top-level usage text, built from the table.
    static var usage: String {
        let width = (subcommands.map(\.name.count).max() ?? 0) + 2
        let commands = subcommands
            .map { "  " + $0.name.padding(toLength: width, withPad: " ", startingAt: 0) + $0.summary }
            .joined(separator: "\n")
        return """
            Usage: mirroir-mcp [--debug] [--dangerously-skip-permissions]
                   mirroir-mcp <command> [options]

            With no command, runs the MCP server on stdio.

            Commands:
            \(commands)

            Options:
              --dangerously-skip-permissions, --yolo
                           Expose every tool, whatever permissions.json says
              --debug      Verbose logging, for the server and for any command
              --version    Print the version
              --help, -h   Show this help

            Run mirroir-mcp <command> --help for a command's options.
            """
    }
}
