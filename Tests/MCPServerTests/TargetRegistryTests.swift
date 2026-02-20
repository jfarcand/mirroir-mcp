// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for TargetRegistry: resolve, switchActive, allTargets.
// ABOUTME: Verifies active target management and unknown target handling.

import XCTest
import HelperLib
@testable import iphone_mirroir_mcp

final class TargetRegistryTests: XCTestCase {

    private func makeMultiTargetRegistry() -> (TargetRegistry, StubBridge, StubBridge) {
        let iphoneBridge = StubBridge()
        iphoneBridge.targetName = "iphone"
        let androidBridge = StubBridge()
        androidBridge.targetName = "android"

        let iphoneCtx = TargetContext(
            name: "iphone", bridge: iphoneBridge, input: StubInput(),
            capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder(),
            capabilities: [.menuActions, .spotlight, .home, .appSwitcher])
        let androidCtx = TargetContext(
            name: "android", bridge: androidBridge, input: StubInput(),
            capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder(),
            capabilities: [])

        let registry = TargetRegistry(
            targets: ["iphone": iphoneCtx, "android": androidCtx],
            defaultName: "iphone")
        return (registry, iphoneBridge, androidBridge)
    }

    // MARK: - resolve

    func testResolveNilReturnsActiveTarget() {
        let (registry, _, _) = makeMultiTargetRegistry()
        let ctx = registry.resolve(nil)
        XCTAssertNotNil(ctx)
        XCTAssertEqual(ctx?.name, "iphone")
    }

    func testResolveByNameReturnsCorrectTarget() {
        let (registry, _, _) = makeMultiTargetRegistry()
        let ctx = registry.resolve("iphone")
        XCTAssertNotNil(ctx)
        XCTAssertEqual(ctx?.name, "iphone")

        let ctx2 = registry.resolve("android")
        XCTAssertNotNil(ctx2)
        XCTAssertEqual(ctx2?.name, "android")
    }

    func testResolveUnknownNameReturnsNil() {
        let (registry, _, _) = makeMultiTargetRegistry()
        let ctx = registry.resolve("nonexistent")
        XCTAssertNil(ctx)
    }

    // MARK: - switchActive

    func testSwitchActiveSuccess() {
        let (registry, _, _) = makeMultiTargetRegistry()
        XCTAssertEqual(registry.activeTarget.name, "iphone")

        let result = registry.switchActive(to: "android")
        XCTAssertTrue(result)
        XCTAssertEqual(registry.activeTarget.name, "android")
    }

    func testSwitchActiveUnknownReturnsFalse() {
        let (registry, _, _) = makeMultiTargetRegistry()
        let result = registry.switchActive(to: "nonexistent")
        XCTAssertFalse(result)
        XCTAssertEqual(registry.activeTarget.name, "iphone")
    }

    // MARK: - allTargets

    func testAllTargetsReturnsAllConfigured() {
        let (registry, _, _) = makeMultiTargetRegistry()
        let all = registry.allTargets
        XCTAssertEqual(all.count, 2)
        let names = all.map { $0.name }.sorted()
        XCTAssertEqual(names, ["android", "iphone"])
    }

    // MARK: - activeTarget

    func testActiveTargetIsDefault() {
        let (registry, _, _) = makeMultiTargetRegistry()
        XCTAssertEqual(registry.activeTarget.name, "iphone")
        XCTAssertEqual(registry.activeTargetName, "iphone")
    }
}
