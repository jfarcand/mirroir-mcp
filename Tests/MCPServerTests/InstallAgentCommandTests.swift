// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for `mirroir-mcp install-agent`: the LaunchAgent it writes, and what it refuses or leaves untouched.
// ABOUTME: Runs against a temporary directory; nothing is written under the real home and launchctl is never called.

import XCTest
@testable import mirroir_mcp

final class InstallAgentCommandTests: XCTestCase {

    private var directory = ""
    /// A real executable to copy: an install copies the binary into the bundle.
    private var binary = ""

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "install-agent-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory + "/bin", withIntermediateDirectories: true)
        binary = directory + "/bin/mirroir-mcp"
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: binary)
    }

    /// Signing is stubbed except where a test checks the real signature.
    private let signed: (String) -> String? = { _ in nil }

    private func install(port: UInt16 = 8765, printOnly: Bool = false,
                         paths: InstallAgentPaths? = nil,
                         replacingAdHoc: Bool = false) -> InstallAgentOutcome {
        InstallAgentCommand.install(config: InstallAgentConfig(port: port, printOnly: printOnly),
                                    paths: paths ?? self.paths(), sign: signed,
                                    isAdHocSigned: { _ in replacingAdHoc })
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
    }

    private func paths(executable: String? = nil) -> InstallAgentPaths {
        InstallAgentPaths(
            executable: executable ?? binary, bundle: directory + "/config/mirroir serve.app",
            plist: directory + "/LaunchAgents/agent.plist",
            tokenFile: directory + "/config/serve-token", log: directory + "/config/serve.log")
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testThePlistRunsServeInTheGUISession() throws {
        let outcome = install(port: 9100)
        XCTAssertEqual(outcome.exitCode, 0, outcome.standardError)

        let plist = try decode(try Data(contentsOf: URL(fileURLWithPath: paths().plist)))
        XCTAssertEqual(plist["Label"] as? String, "dev.mirroir.serve")
        XCTAssertEqual(plist["ProgramArguments"] as? [String],
                       [paths().bundle + "/Contents/MacOS/mirroir serve", "serve", "--port", "9100"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "Aqua")
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(plist["StandardErrorPath"] as? String, paths().log)
    }

    /// Grants follow the certificate, so the output says an upgrade keeps them.
    func testTheOutputNamesTheCertificateAndTheGrants() {
        let outcome = install()
        XCTAssertEqual(outcome.exitCode, 0, outcome.standardError)
        XCTAssertTrue(outcome.standardOutput.contains("\"mirroir serve local signing\""), outcome.standardOutput)
        XCTAssertTrue(outcome.standardOutput.contains("Always Allow"))
        XCTAssertTrue(outcome.standardOutput.contains("launchctl kickstart -k gui/$(id -u)/dev.mirroir.serve"))
        XCTAssertFalse(outcome.standardOutput.contains("tccutil"), "nothing to reset on a first install")
    }

    /// Grants given to an ad-hoc bundle stay pinned to its build hash, and
    /// toggling the switch keeps the pin (measured on macOS 26.5): they must be reset.
    func testReplacingAnAdHocBundleSaysToResetItsGrants() {
        let outcome = install(replacingAdHoc: true)
        XCTAssertEqual(outcome.exitCode, 0, outcome.standardError)
        XCTAssertTrue(outcome.standardOutput.contains("tccutil reset All dev.mirroir.serve"), outcome.standardOutput)
    }

    /// The arguments the agent runs must be ones `serve` accepts.
    func testTheAgentsArgumentsParseAsAServeCommandLine() throws {
        let job = InstallAgentCommand.plist(executable: "/x/mirroir-mcp", port: 9100, logPath: "/x/log")
        let arguments = try XCTUnwrap(job["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments[1], ServeCommand.commandName)
        XCTAssertEqual(try ServeCommand.parseArguments(Array(arguments.dropFirst(2))).port, 9100)
    }

    func testThePlistNeverHoldsTheToken() throws {
        let outcome = install()
        XCTAssertEqual(outcome.exitCode, 0, outcome.standardError)
        let token = try ServeToken.load(path: paths().tokenFile)
        let plist = try String(contentsOfFile: paths().plist, encoding: .utf8)
        XCTAssertFalse(plist.contains(token))
        XCTAssertFalse(outcome.standardOutput.contains(token), "the token is not printed either")
        XCTAssertTrue(outcome.standardOutput.contains(paths().tokenFile), "only where it lives")
    }

    func testAnExistingTokenIsKept() throws {
        XCTAssertEqual(install().exitCode, 0)
        let first = try ServeToken.load(path: paths().tokenFile)
        XCTAssertEqual(install().exitCode, 0)
        XCTAssertEqual(try ServeToken.load(path: paths().tokenFile), first)
    }

    /// A token file `serve` would refuse fails the install, with the same message.
    func testAnUnusableExistingTokenFailsTheInstall() throws {
        try FileManager.default.createDirectory(atPath: directory + "/config", withIntermediateDirectories: true)
        try Data("short".utf8).write(to: URL(fileURLWithPath: paths().tokenFile))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths().tokenFile)

        let outcome = install()
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertTrue(outcome.standardError.contains("holds fewer than 32 characters"), outcome.standardError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths().plist),
                       "no agent is installed over a token it could not start with")
    }

    func testAnNpxCopyIsRefused() {
        let npx = paths(executable: "/Users/someone/.npm/_npx/abc123/node_modules/mirroir-mcp/bin/mirroir-mcp")
        let outcome = install(paths: npx)
        XCTAssertEqual(outcome.exitCode, 1)
        XCTAssertEqual(outcome.standardError,
                       "This copy runs from the npx cache, whose path changes. Install with Homebrew first: "
                       + "brew install jfarcand/tap/mirroir-mcp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: npx.plist))
        XCTAssertFalse(FileManager.default.fileExists(atPath: npx.tokenFile))
    }

    func testPrintWritesNothing() throws {
        let outcome = install(printOnly: true)
        XCTAssertEqual(outcome.exitCode, 0)
        let plist = try decode(Data(outcome.standardOutput.utf8))
        XCTAssertEqual(plist["Label"] as? String, InstallAgentCommand.label)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory), ["bin"])
    }

    func testArguments() throws {
        XCTAssertEqual(try InstallAgentCommand.parseArguments([]),
                       InstallAgentConfig(port: ServeCommand.defaultPort, printOnly: false))
        XCTAssertEqual(try InstallAgentCommand.parseArguments(["--print", "--port", "9001"]),
                       InstallAgentConfig(port: 9001, printOnly: true))
        XCTAssertThrowsError(try InstallAgentCommand.parseArguments(["--port"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .missingValue(flag: "--port"))
        }
    }

    func testTheInvokedPathIsAbsolute() {
        XCTAssertTrue(InstallAgentCommand.invokedExecutablePath().hasPrefix("/"))
    }
}
