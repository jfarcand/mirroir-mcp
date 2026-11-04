// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the once-a-day update check (version order, the cache, the notice) and the install channel read from a path.
// ABOUTME: No network: the registry lookup is a closure, the clock a fixed date, and the tools get a fixed notice.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class UpdateCheckTests: XCTestCase {

    // MARK: - Versions

    func testVersionsCompareByNumberNotText() {
        XCTAssertTrue(UpdateCheck.isNewer("0.44.0", than: "0.43.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.43.10", than: "0.43.9"))
        XCTAssertTrue(UpdateCheck.isNewer("v1.0", than: "0.99.99"))
        XCTAssertFalse(UpdateCheck.isNewer("0.43.0", than: "0.43.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.42.9", than: "0.43.0"))
    }

    func testTheNoticeAppearsOnlyWhenBehind() {
        XCTAssertNil(UpdateCheck.notice(current: "0.43.0", latest: "0.43.0"))
        XCTAssertNil(UpdateCheck.notice(current: "0.43.0", latest: nil))
        XCTAssertEqual(UpdateCheck.notice(current: "0.43.0", latest: "0.44.0"),
                       "mirroir-mcp 0.44.0 is available (this is 0.43.0). Run `mirroir-mcp update` "
                       + "to see how to upgrade this install.")
    }

    // MARK: - Cache

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAFreshCacheAnswersWithoutTheNetwork() {
        var fetches = 0
        let cache = UpdateCheck.Cache(checkedAt: now.addingTimeInterval(-3600), latest: "0.44.0")
        let latest = UpdateCheck.latest(now: now, cache: cache, fetch: { fetches += 1; return "9.9.9" },
                                        store: { _ in XCTFail("a fresh cache is not rewritten") })
        XCTAssertEqual(latest, "0.44.0")
        XCTAssertEqual(fetches, 0)
    }

    func testAStaleCacheIsRefreshedAndAFailureIsRemembered() {
        var stored: [UpdateCheck.Cache] = []
        let stale = UpdateCheck.Cache(checkedAt: now.addingTimeInterval(-UpdateCheck.cacheLifetime), latest: "0.44.0")
        XCTAssertNil(UpdateCheck.latest(now: now, cache: stale, fetch: { nil }, store: { stored.append($0) }))
        XCTAssertEqual(stored, [UpdateCheck.Cache(checkedAt: now, latest: nil)],
                       "an offline Mac is asked again tomorrow, not on every call")
    }

    // MARK: - Install channel

    private func channel(_ path: String, git: Set<String> = []) -> InstallChannel {
        InstallChannel.of(executable: path) { git.contains($0) }
    }

    func testTheChannelIsReadFromTheBinaryPath() {
        XCTAssertEqual(channel("/opt/homebrew/Cellar/mirroir-mcp/0.43.0/bin/mirroir-mcp"), .homebrew)
        XCTAssertEqual(channel("/Users/a/.npm/_npx/6f1/node_modules/mirroir-mcp/bin/mirroir-mcp-native"), .npx)
        XCTAssertEqual(channel("/Users/a/Library/Application Support/Claude/Claude Extensions/mirroir/server/mirroir-mcp"),
                       .mcpBundle)
        XCTAssertEqual(channel("/Users/a/mirroir-mcp/.build/release/mirroir-mcp", git: ["/Users/a/mirroir-mcp"]),
                       .source(root: "/Users/a/mirroir-mcp"))
        XCTAssertEqual(channel("/Users/a/elsewhere/.build/release/mirroir-mcp"), .unknown)
    }

    func testOnlyHomebrewAndSourceRunAnUpgrade() {
        XCTAssertEqual(InstallChannel.homebrew.command, "brew upgrade mirroir-mcp")
        XCTAssertEqual(InstallChannel.source(root: "/r").command, "git -C '/r' pull --ff-only && cd '/r' && ./mirroir.sh")
        XCTAssertNil(InstallChannel.npx.command)
        XCTAssertTrue(InstallChannel.npx.advice.contains("mirroir-mcp@latest"))
    }

    // MARK: - Where the notice shows

    private func call(_ tool: String, notice: String?) -> String {
        let server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil))
        let capture = StubCapture()
        capture.captureResult = "base64data"
        MirroirMCP.registerInfoTools(
            server: server, registry: makeTestRegistry(bridge: StubBridge(), input: StubInput(), capture: capture),
            updateNotice: { notice })
        let request = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "tools/call",
                                     params: .object(["name": .string(tool), "arguments": .object([:])]))
        guard case .object(let result)? = server.handleRequest(request)?.result,
              case .array(let content)? = result["content"],
              case .object(let first)? = content.first,
              case .string(let text)? = first["text"] else { return "" }
        return text
    }

    func testStatusAndCheckHealthCarryTheNotice() {
        XCTAssertTrue(call("status", notice: "mirroir-mcp 9.0.0 is available").hasSuffix("mirroir-mcp 9.0.0 is available"))
        XCTAssertTrue(call("check_health", notice: "mirroir-mcp 9.0.0 is available")
            .contains("[WARN] mirroir-mcp 9.0.0 is available"))
        XCTAssertFalse(call("status", notice: nil).contains("available"))
    }

    func testDoctorWarnsButNeverFailsOnAnOldVersion() {
        XCTAssertEqual(DoctorCommand.updateCheck(notice: "newer").status, .warned)
        XCTAssertEqual(DoctorCommand.updateCheck(notice: nil).status, .passed)
    }
}
