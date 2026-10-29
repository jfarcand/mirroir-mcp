// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that project-local and global settings.json merge key by key.
// ABOUTME: A project file must not hide global keys it does not set (e.g. keyboardLayout).

import XCTest
@testable import HelperLib

final class EnvConfigSettingsMergeTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvConfigSettingsMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ json: String, named name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testGlobalKeyAbsentFromProjectFileStillApplies() throws {
        let global = try write(#"{"keyboardLayout": "Canadian-CSA", "agent": "global-agent"}"#, named: "global.json")
        let local = try write(#"{"agent": "embacle", "screenDescriberMode": "ocr"}"#, named: "local.json")

        let merged = EnvConfig.mergedSettings(localPath: local, globalPath: global)

        XCTAssertEqual(merged["keyboardLayout"] as? String, "Canadian-CSA")
        XCTAssertEqual(merged["screenDescriberMode"] as? String, "ocr")
    }

    func testProjectKeyOverridesGlobalKey() throws {
        let global = try write(#"{"agent": "global-agent"}"#, named: "global.json")
        let local = try write(#"{"agent": "embacle"}"#, named: "local.json")

        let merged = EnvConfig.mergedSettings(localPath: local, globalPath: global)

        XCTAssertEqual(merged["agent"] as? String, "embacle")
    }

    func testMissingFilesContributeNothing() throws {
        let global = try write(#"{"keyboardLayout": "Canadian-CSA"}"#, named: "global.json")
        let missing = directory.appendingPathComponent("absent.json").path

        XCTAssertEqual(EnvConfig.mergedSettings(localPath: missing, globalPath: global)["keyboardLayout"] as? String,
                       "Canadian-CSA")
        XCTAssertTrue(EnvConfig.mergedSettings(localPath: missing, globalPath: missing).isEmpty)
    }

    func testMalformedProjectFileKeepsGlobalKeys() throws {
        let global = try write(#"{"keyboardLayout": "Canadian-CSA"}"#, named: "global.json")
        let local = try write("[1, 2, 3]", named: "local.json")

        let merged = EnvConfig.mergedSettings(localPath: local, globalPath: global)

        XCTAssertEqual(merged["keyboardLayout"] as? String, "Canadian-CSA")
    }
}
