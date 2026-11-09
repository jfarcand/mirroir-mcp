// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Decides whether CLI output may carry ANSI colour, and holds the colour codes.
// ABOUTME: Colour is for a person at a terminal: piped output and NO_COLOR get plain text an agent can parse.

import Darwin
import Foundation

/// The one place that decides whether human-readable CLI output is coloured.
enum TerminalColor {

    /// The NO_COLOR convention (https://no-color.org): set and not empty turns colour off.
    static let noColorVariable = "NO_COLOR"

    static let green = "\u{001B}[32m"
    static let red = "\u{001B}[31m"
    static let yellow = "\u{001B}[33m"
    static let reset = "\u{001B}[0m"

    /// Colour is on only for a terminal, with `NO_COLOR` unset or empty, and
    /// with no flag turning it off.
    static func isEnabled(isTerminal: Bool, environment: [String: String], disabledByFlag: Bool) -> Bool {
        guard isTerminal, !disabledByFlag else { return false }
        return (environment[noColorVariable] ?? "").isEmpty
    }

    /// The live decision for a file descriptor: whether it is a terminal, and
    /// what this process's environment says.
    static func isEnabled(for descriptor: Int32, disabledByFlag: Bool) -> Bool {
        isEnabled(isTerminal: isatty(descriptor) != 0,
                  environment: ProcessInfo.processInfo.environment,
                  disabledByFlag: disabledByFlag)
    }
}
