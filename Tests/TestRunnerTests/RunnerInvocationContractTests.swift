// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Checks that `mirroir-mcp test` accepts every command line mirroir-run builds for an ios block.
// ABOUTME: Both sides read one checked-in file, so a flag renamed in Swift or in Rust fails that side's suite.

import XCTest
import HelperLib
@testable import mirroir_mcp

/// mirroir-run spawns `mirroir-mcp test` with flags it builds in Rust
/// (runner/src/target/ios.rs). The runner's own test pins what it builds to
/// this file; these tests pin what the Swift parser makes of it.
final class RunnerInvocationContractTests: XCTestCase {

    private struct Contract: Decodable {
        let subcommand: String
        let environment: [String]
        let invocations: [String: [String]]
    }

    private func contract() throws -> Contract {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runner/src/target/fixtures/mirroir-mcp-test-invocation.json")
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    }

    func testEveryRunnerInvocationIsAccepted() throws {
        let contract = try contract()
        XCTAssertFalse(contract.invocations.isEmpty)
        for (name, arguments) in contract.invocations {
            let config = try TestRunner.parseArguments(arguments)
            XCTAssertEqual(config.reportJSONPath, "ios-report.json", name)
            XCTAssertEqual(config.captureKey, "ios", name)
            XCTAssertEqual(config.skillArgs, ["ios-block.yaml"], name)
            XCTAssertFalse(config.dryRun, name)
            XCTAssertFalse(config.noCompiled, name)
        }
    }

    func testOnlyTheRecordingInvocationCarriesTheCompiledPaths() throws {
        let contract = try contract()
        let block = try TestRunner.parseArguments(try XCTUnwrap(contract.invocations["block"]))
        XCTAssertNil(block.compiledOutPath)
        XCTAssertNil(block.compiledSourcePath)

        let recording = try TestRunner.parseArguments(
            try XCTUnwrap(contract.invocations["recording_block"]))
        XCTAssertEqual(recording.compiledOutPath, "out.compiled.json")
        XCTAssertEqual(recording.compiledSourcePath, "flow.ios.yaml")
    }

    /// The whole command line, subcommand first, routes to the command that parses it.
    func testTheSubcommandIsDispatched() throws {
        let contract = try contract()
        for (name, arguments) in contract.invocations {
            guard case .subcommand(let command, let rest) =
                    CLIDispatch.route([contract.subcommand] + arguments) else {
                return XCTFail("\(name) does not route to a subcommand")
            }
            XCTAssertEqual(command.name, contract.subcommand, name)
            XCTAssertEqual(CLIDispatch.preflight(command, rest), .run, name)
        }
    }

    func testTheEnvironmentVariablesAreRead() throws {
        XCTAssertEqual(try contract().environment, [PermissionPolicy.skillsCheckoutVariable])
    }
}
