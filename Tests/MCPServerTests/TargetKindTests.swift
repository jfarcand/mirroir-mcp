// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
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
