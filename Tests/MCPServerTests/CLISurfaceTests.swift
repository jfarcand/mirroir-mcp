// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: One contract over every mirroir-mcp subcommand: help, unknown options, documented options, exit codes.
// ABOUTME: Runs each command's validation only, never the command, so no test starts an upgrade or drives a device.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class CLISurfaceTests: XCTestCase {

    /// An option no command defines.
    private static let bogusOption = "--definitely-not-an-option"

    /// Every `--long-option` a usage text names.
    private func documentedOptions(_ usage: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: "--[a-z][a-z-]+")
        let range = NSRange(usage.startIndex..., in: usage)
        return Set(pattern.matches(in: usage, range: range).compactMap {
            Range($0.range, in: usage).map { String(usage[$0]) }
        })
    }

    func testSubcommandNamesAreUniqueAndComplete() {
        XCTAssertEqual(CLIDispatch.subcommands.map(\.name),
                       ["test", "record", "compile", "migrate", "doctor", "update", "skill", "configure",
                        "ax-capture", "serve", "install-agent", "bundle-app"])
    }

    func testEverySubcommandAnswersHelp() {
        for command in CLIDispatch.subcommands {
            XCTAssertEqual(CLIDispatch.preflight(command, ["--help"]), .help, command.name)
            XCTAssertEqual(CLIDispatch.preflight(command, ["-h"]), .help, command.name)
            XCTAssertTrue(command.usage().hasPrefix("Usage: mirroir-mcp \(command.name)"), command.name)
            XCTAssertFalse(command.usage().hasSuffix("\n"), "\(command.name): usage ends without a blank line")
        }
    }

    func testHelpWinsOverOtherArguments() {
        for command in CLIDispatch.subcommands {
            XCTAssertEqual(CLIDispatch.preflight(command, [Self.bogusOption, "--help"]), .help, command.name)
        }
    }

    func testEverySubcommandRefusesAnUnknownOption() {
        for command in CLIDispatch.subcommands {
            XCTAssertThrowsError(try command.validate([Self.bogusOption]), command.name) {
                XCTAssertEqual($0 as? CLIArgumentError,
                               .unknownOption(Self.bogusOption, command: command.name), command.name)
            }
        }
    }

    /// The generated half: an option a usage text documents must be one the
    /// parser takes. Given alone it may still lack its value or a required
    /// partner, but it is never unknown.
    func testEveryDocumentedOptionIsParsed() throws {
        for command in CLIDispatch.subcommands {
            let options = try documentedOptions(command.usage()).subtracting(CLIArguments.helpOptions)
            for option in options {
                do {
                    try command.validate([option])
                } catch let error as CLIArgumentError {
                    XCTAssertNotEqual(error, .unknownOption(option, command: command.name),
                                      "\(command.name) documents \(option) but does not parse it")
                } catch {
                    continue
                }
            }
        }
    }

    /// No parser accepts a prefix of an option: `--dry-ru` is refused, never
    /// read as `--dry-run` and never dropped.
    func testNoSubcommandAcceptsAnAbbreviatedOption() throws {
        for command in CLIDispatch.subcommands {
            let options = try documentedOptions(command.usage())
            for option in options {
                let shortened = String(option.dropLast())
                guard !options.contains(shortened) else { continue }
                XCTAssertThrowsError(try command.validate([shortened]), "\(command.name) \(shortened)") {
                    XCTAssertEqual($0 as? CLIArgumentError,
                                   .unknownOption(shortened, command: command.name))
                }
            }
        }
    }

    func testExecuteMapsPreflightToExitCodes() {
        struct Refusal: LocalizedError { var errorDescription: String? { "no" } }
        let ranWith = Recorder()
        let accepting = CLISubcommand(
            name: "probe", summary: "", usage: { "Usage: mirroir-mcp probe" },
            validate: { _ in }, run: { ranWith.record($0); return 7 })
        let refusing = CLISubcommand(
            name: "probe", summary: "", usage: { "Usage: mirroir-mcp probe" },
            validate: { _ in throw Refusal() }, run: { ranWith.record($0); return 7 })

        XCTAssertEqual(CLIDispatch.execute(accepting, ["--help"]), 0)
        XCTAssertEqual(CLIDispatch.execute(refusing, ["x"]), CLIDispatch.usageExitCode)
        XCTAssertEqual(ranWith.calls, [], "help and a refusal never reach run")
        XCTAssertEqual(CLIDispatch.execute(accepting, ["x"]), 7)
        XCTAssertEqual(ranWith.calls, [["x"]])
        XCTAssertEqual(CLIDispatch.usageExitCode, 2)
    }

    func testUnknownSubcommandIsRefused() {
        guard case .refused(let message) = CLIDispatch.route(["bogus"]) else {
            return XCTFail("an unknown command must not start the server")
        }
        XCTAssertTrue(message.contains("unknown command 'bogus'"), message)
    }

    func testUnknownServerOptionIsRefused() {
        for arguments in [["--nope"], ["--yolo", "extra"], ["--yol"], ["--dangerously-skip"]] {
            guard case .refused = CLIDispatch.route(arguments) else {
                return XCTFail("\(arguments) must be refused")
            }
        }
    }

    func testServerRoutes() {
        for arguments in [[], ["--debug"], ["--yolo"], ["--dangerously-skip-permissions", "--debug"]] {
            guard case .server(let rest) = CLIDispatch.route(arguments) else {
                return XCTFail("\(arguments) must start the server")
            }
            XCTAssertFalse(rest.contains(CLIDispatch.debugOption))
            XCTAssertEqual(PermissionPolicy.parseSkipPermissions(from: rest),
                           arguments.contains { CLIDispatch.serverOptions.contains($0) })
        }
    }

    func testDebugIsRemovedBeforeASubcommandParses() {
        guard case .subcommand(let command, let arguments) = CLIDispatch.route(["--debug", "doctor", "--json"]) else {
            return XCTFail("--debug before a command still routes to the command")
        }
        XCTAssertEqual(command.name, "doctor")
        XCTAssertEqual(arguments, ["--json"])
    }

    func testTopLevelHelpAndVersion() {
        for arguments in [["--help"], ["-h"]] {
            guard case .help = CLIDispatch.route(arguments) else { return XCTFail("\(arguments)") }
        }
        guard case .version = CLIDispatch.route(["--version"]) else { return XCTFail("--version") }
        for command in CLIDispatch.subcommands {
            XCTAssertTrue(CLIDispatch.usage.contains("  \(command.name) "), command.name)
        }
    }

    func testCompileAndMigrateRefuseABadValue() {
        XCTAssertThrowsError(try CompileCommand.parseArguments(["--timeout"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .missingValue(flag: "--timeout"))
        }
        XCTAssertThrowsError(try CompileCommand.parseArguments(["--timeout", "soon"])) {
            XCTAssertEqual($0 as? CLIArgumentError,
                           .invalidValue(flag: "--timeout", value: "soon",
                                         expected: "a positive whole number of seconds"))
        }
        XCTAssertThrowsError(try MigrateCommand.parseArguments(["--dir"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .missingValue(flag: "--dir"))
        }
        XCTAssertThrowsError(try MigrateCommand.parseArguments(["--dry-run"])) {
            XCTAssertEqual($0 as? CLIArgumentError,
                           .missingArgument("a YAML file or --dir <path>", command: "migrate"))
        }
    }

    /// A mistyped option must never fall through to the action: `update
    /// --dryrun` used to run the upgrade, and `configure --x` used to rewrite settings.
    func testFlagOnlyCommandsRefuseATypo() {
        XCTAssertThrowsError(try UpdateCommand.validate(["--dryrun"]))
        XCTAssertNoThrow(try UpdateCommand.validate(["--dry-run"]))
        XCTAssertThrowsError(try SkillCommand.validate(["--instal"]))
        XCTAssertNoThrow(try SkillCommand.validate(["--install"]))
        XCTAssertThrowsError(try ConfigureCommand.validate(["--x"]))
        XCTAssertNoThrow(try ConfigureCommand.validate([]))
    }
}

/// Collects the argument lists a probe command was run with.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []

    func record(_ arguments: [String]) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(arguments)
    }

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
