// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Fails a unit-test run that can see the developer's own settings, permissions or home directory.
// ABOUTME: One guard per test runner, because XCTest and swift-testing run in separate invocations.

import Foundation
import Testing
import XCTest
@testable import HelperLib

/// What a unit-test process must not have picked up from the machine it runs on.
private enum Isolation {

    /// How to run the tests so nothing leaks.
    static let remedy = "Unit tests must run through scripts/unit-tests.sh"

    /// The account's real home, read from the user database rather than from
    /// Foundation, which the script redirects.
    static var accountHome: String? {
        getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) }
    }

    /// The settings keys loaded from a settings.json: none in an isolated run.
    static var leakedSettings: [String] { EnvConfig.settings.keys.sorted() }

    /// Whether `~` resolves somewhere other than the account's real home.
    static var homeIsThrowaway: Bool {
        guard let accountHome else { return false }
        return NSHomeDirectory() != accountHome
            && PermissionPolicy.globalConfigDir.hasPrefix(NSHomeDirectory())
    }

    /// A project-local permissions.json, which no environment variable can
    /// mask because it is read through the working directory.
    static var localPermissionsFile: String? {
        let path = PermissionPolicy.localConfigDir + "/permissions.json"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

final class UnitTestIsolationTests: XCTestCase {

    func testNoSettingsFileIsLoaded() {
        XCTAssertEqual(Isolation.leakedSettings, [],
                       "\(Isolation.remedy): a settings.json set these keys")
    }

    func testTheHomeDirectoryIsAThrowaway() {
        XCTAssertTrue(Isolation.homeIsThrowaway,
                      "\(Isolation.remedy): ~ resolves to \(NSHomeDirectory()), the real home")
    }

    func testNoPermissionsFileIsLoaded() {
        XCTAssertNil(Isolation.localPermissionsFile,
                     "A project-local permissions.json changes test results: move it away")
        XCTAssertNil(PermissionPolicy.loadConfig(),
                     "\(Isolation.remedy): a permissions.json was loaded")
    }
}

@Suite("Unit test isolation")
struct UnitTestIsolationSuite {

    @Test("no settings.json is loaded")
    func noSettingsFileIsLoaded() {
        #expect(Isolation.leakedSettings.isEmpty,
                "\(Isolation.remedy): a settings.json set \(Isolation.leakedSettings)")
    }

    @Test("the home directory is a throwaway")
    func theHomeDirectoryIsAThrowaway() {
        #expect(Isolation.homeIsThrowaway,
                "\(Isolation.remedy): ~ resolves to \(NSHomeDirectory()), the real home")
    }

    @Test("no permissions.json is loaded")
    func noPermissionsFileIsLoaded() {
        #expect(Isolation.localPermissionsFile == nil,
                "A project-local permissions.json changes test results: move it away")
        #expect(PermissionPolicy.loadConfig() == nil,
                "\(Isolation.remedy): a permissions.json was loaded")
    }
}
