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

    /// Write `json` as the settings.json of a new config directory, and return the directory.
    private func configDir(_ name: String, settings json: String) throws -> String {
        let dir = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent(EnvConfig.settingsFileName),
                       atomically: true, encoding: .utf8)
        return dir.path
    }

    func testWithoutTheVariableLocalOverridesGlobal() throws {
        let global = try configDir("global", settings: #"{"agent": "global-agent", "keyboardLayout": "German"}"#)
        let local = try configDir("local", settings: #"{"agent": "embacle"}"#)

        let loaded = EnvConfig.loadSettings(environment: [:], localConfigDir: local, globalConfigDir: global)

        XCTAssertEqual(loaded["agent"] as? String, "embacle")
        XCTAssertEqual(loaded["keyboardLayout"] as? String, "German")
    }

    func testSettingsFileVariableReplacesBothFiles() throws {
        let global = try configDir("global", settings: #"{"keyboardLayout": "German"}"#)
        let local = try configDir("local", settings: #"{"agent": "embacle"}"#)
        let only = try write(#"{"screenDescriberMode": "ocr"}"#, named: "only.json")

        let loaded = EnvConfig.loadSettings(
            environment: [EnvConfig.settingsFileVariable: only],
            localConfigDir: local, globalConfigDir: global)

        XCTAssertEqual(loaded.keys.sorted(), ["screenDescriberMode"])
    }

    func testSettingsFileVariableNamingAMissingFileLoadsNothing() throws {
        let global = try configDir("global", settings: #"{"keyboardLayout": "German"}"#)
        let local = try configDir("local", settings: #"{"agent": "embacle"}"#)
        let absent = directory.appendingPathComponent("absent.json").path

        let loaded = EnvConfig.loadSettings(
            environment: [EnvConfig.settingsFileVariable: absent],
            localConfigDir: local, globalConfigDir: global)

        XCTAssertTrue(loaded.isEmpty)
    }

    func testEmptySettingsFileVariableIsIgnored() throws {
        let global = try configDir("global", settings: #"{"keyboardLayout": "German"}"#)
        let local = try configDir("local", settings: #"{"agent": "embacle"}"#)

        let loaded = EnvConfig.loadSettings(
            environment: [EnvConfig.settingsFileVariable: ""],
            localConfigDir: local, globalConfigDir: global)

        XCTAssertEqual(loaded.keys.sorted(), ["agent", "keyboardLayout"])
    }
}
