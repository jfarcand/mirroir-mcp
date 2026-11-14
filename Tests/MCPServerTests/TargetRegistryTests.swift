/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Tests for TargetRegistry: resolve, switchActive, allTargets.
// ABOUTME: Verifies active target management and unknown target handling.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class TargetRegistryTests: XCTestCase {

    private func makeMultiTargetRegistry() -> (TargetRegistry, StubBridge, StubBridge) {
        let iphoneBridge = StubBridge()
        iphoneBridge.targetName = "iphone"
        let androidBridge = StubBridge()
        androidBridge.targetName = "android"

        let iphoneCtx = TargetContext(
            name: "iphone", targetType: "iphone-mirroring", bundleID: nil,
            bridge: iphoneBridge, input: StubInput(),
            capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder())
        let androidCtx = TargetContext(
            name: "android", targetType: "macos-app", bundleID: nil,
            bridge: androidBridge, input: StubInput(),
            capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder())

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
