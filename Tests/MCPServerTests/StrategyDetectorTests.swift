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
// ABOUTME: Unit tests for StrategyDetector: auto-detection of exploration strategy from target metadata.
// ABOUTME: Covers explicit override, target type, app name matching, and default fallback.

import XCTest
@testable import mirroir_mcp

final class StrategyDetectorTests: XCTestCase {

    // MARK: - Explicit Override

    func testExplicitOverrideMobile() {
        let result = StrategyDetector.detect(
            targetType: "macos-app",
            appName: "Reddit", explicitStrategy: "mobile")
        XCTAssertEqual(result, .mobile,
            "Explicit 'mobile' should override all other signals")
    }

    func testExplicitOverrideSocial() {
        let result = StrategyDetector.detect(
            targetType: "iphone-mirroring",
            appName: "Settings", explicitStrategy: "social")
        XCTAssertEqual(result, .social)
    }

    func testExplicitOverrideDesktop() {
        let result = StrategyDetector.detect(
            targetType: "iphone-mirroring",
            appName: "Settings", explicitStrategy: "desktop")
        XCTAssertEqual(result, .desktop)
    }

    func testInvalidExplicitOverrideFallsThrough() {
        let result = StrategyDetector.detect(
            targetType: "iphone-mirroring",
            appName: "Settings", explicitStrategy: "invalid")
        XCTAssertEqual(result, .mobile,
            "Invalid explicit strategy should fall through to default detection")
    }

    // MARK: - Target Type Detection

    func testGenericWindowDetectsDesktop() {
        let result = StrategyDetector.detect(
            targetType: "macos-app",
            appName: "Finder")
        XCTAssertEqual(result, .desktop)
    }

    func testIPhoneMirroringDefaultsMobile() {
        let result = StrategyDetector.detect(
            targetType: "iphone-mirroring",
            appName: "Settings")
        XCTAssertEqual(result, .mobile)
    }

    // MARK: - App Name Detection

    func testRedditAppNameDetectsSocial() {
        let result = StrategyDetector.detect(
            targetType: "iphone-mirroring",
            appName: "Reddit")
        XCTAssertEqual(result, .social)
    }

    func testTikTokAppNameDetectsSocial() {
        let result = StrategyDetector.detect(
            targetType: "iphone-mirroring",
            appName: "TikTok")
        XCTAssertEqual(result, .social)
    }

    func testAppNameIsCaseInsensitive() {
        let result = StrategyDetector.detect(
            targetType: "iphone-mirroring",
            appName: "INSTAGRAM")
        XCTAssertEqual(result, .social)
    }

    // MARK: - Default Fallback

    func testUnknownAppDefaultsToMobile() {
        let result = StrategyDetector.detect(
            targetType: "iphone-mirroring",
            appName: "Calculator")
        XCTAssertEqual(result, .mobile)
    }
}
