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
// ABOUTME: Unit tests for TargetKind: the config-type strings targets.json accepts.
// ABOUTME: Each target kind registers exactly one name, with the profile that name maps to.

import XCTest
@testable import mirroir_mcp

final class TargetKindTests: XCTestCase {

    func testEachTargetKindRegistersOneConfigTypeName() {
        let expected: Set<String> = [
            IPhoneMirroringTarget.configTypeName,
            MacOSAppTarget.configTypeName,
        ]
        XCTAssertEqual(Set(TargetKind.builders.keys), expected)
        XCTAssertEqual(Set(TargetKind.profiles.keys), expected)
    }

    func testMacOSAppConfigTypeMapsToTheDesktopProfile() {
        let profile = TargetKind.profile(for: "macos-app")
        XCTAssertEqual(profile.name, MacOSAppTarget.configTypeName)
        XCTAssertEqual(profile.coordinateSystem, .desktop)
    }

    func testIPhoneMirroringConfigTypeMapsToTheMobileProfile() {
        let profile = TargetKind.profile(for: "iphone-mirroring")
        XCTAssertEqual(profile.coordinateSystem, .mobile)
    }

    /// A Mac app entry still typed "generic-window" is told the one field to change.
    func testAGenericWindowEntryIsToldToBecomeMacOSApp() {
        let message = TargetKind.unknownTypeMessage(type: "generic-window", name: "claude")
        XCTAssertEqual(message, "target 'claude' is skipped: its type 'generic-window' is unknown. "
            + "Change its \"type\" to \"macos-app\" in targets.json, then restart mirroir-mcp.")
    }

    func testAnyOtherUnknownTypeIsGivenTheAcceptedTypes() {
        let message = TargetKind.unknownTypeMessage(type: "android", name: "pixel")
        XCTAssertTrue(message.contains("its type 'android' is unknown"), message)
        XCTAssertTrue(message.contains("'iphone-mirroring' or 'macos-app'"), message)
    }
}
