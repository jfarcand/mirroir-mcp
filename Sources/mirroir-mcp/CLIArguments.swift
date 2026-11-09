// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Argument errors and checks shared by every mirroir-mcp subcommand.
// ABOUTME: One wording for a command line the binary refuses, whichever command refuses it.

import Foundation

/// A command line a subcommand refuses. `CLIDispatch` prints the description
/// after `Error:` and exits with `CLIDispatch.usageExitCode`. A subcommand keeps
/// its own error type only for rules no other command has.
enum CLIArgumentError: LocalizedError, Equatable {
    /// An argument starting with `-` that the command does not define.
    case unknownOption(String, command: String)
    /// A positional argument the command takes none of.
    case unexpectedArgument(String, command: String)
    /// Something the command cannot run without, named for the user.
    case missingArgument(String, command: String)
    /// An option that takes a value, given without one.
    case missingValue(flag: String)
    /// An option whose value is not of the expected kind.
    case invalidValue(flag: String, value: String, expected: String)

    var errorDescription: String? {
        switch self {
        case .unknownOption(let option, let command):
            return "unknown option '\(option)' (see mirroir-mcp \(command) --help)"
        case .unexpectedArgument(let argument, let command):
            return "unexpected argument '\(argument)' (see mirroir-mcp \(command) --help)"
        case .missingArgument(let what, let command):
            return "missing \(what) (see mirroir-mcp \(command) --help)"
        case .missingValue(let flag):
            return "option '\(flag)' needs a value"
        case .invalidValue(let flag, let value, let expected):
            return "option '\(flag)' got '\(value)', expected \(expected)"
        }
    }
}

/// Checks every subcommand parser shares.
enum CLIArguments {

    /// The options that ask for a command's usage text.
    static let helpOptions: Set<String> = ["--help", "-h"]

    /// Whether the command line asks for help, anywhere in it.
    static func wantsHelp(_ arguments: [String]) -> Bool {
        arguments.contains { helpOptions.contains($0) }
    }

    /// The error for an argument no case of a parser took: an unknown option
    /// when it starts with `-`, an unexpected argument otherwise.
    static func unrecognized(_ argument: String, command: String) -> CLIArgumentError {
        argument.hasPrefix("-")
            ? .unknownOption(argument, command: command)
            : .unexpectedArgument(argument, command: command)
    }

    /// Refuse anything but the given flags. For commands whose options take no value.
    ///
    /// - Throws: `CLIArgumentError` naming the first argument outside `allowed`.
    static func requireOnly(_ allowed: Set<String>, in arguments: [String], command: String) throws {
        if let stray = arguments.first(where: { !allowed.contains($0) }) {
            throw unrecognized(stray, command: command)
        }
    }
}
