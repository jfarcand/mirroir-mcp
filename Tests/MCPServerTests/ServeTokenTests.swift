// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the bearer token file of `mirroir-mcp serve`: creation, the checks before it is trusted, comparison.
// ABOUTME: Every case runs in a temporary directory; no real token file is read or written.

import XCTest
@testable import mirroir_mcp

final class ServeTokenTests: XCTestCase {

    private var directory = ""

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "serve-token-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
    }

    private func write(_ text: String, mode: Int, name: String = "token") throws -> String {
        let path = directory + "/" + name
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return path
    }

    private let valid = String(repeating: "ab", count: ServeToken.minimumLength / 2)

    func testCreateWritesMode600AndRefusesToOverwrite() throws {
        let path = directory + "/nested/token"
        XCTAssertTrue(try ServeToken.create(path: path))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let first = try ServeToken.load(path: path)
        XCTAssertEqual(first.count, ServeToken.generatedByteCount * 2)
        XCTAssertTrue(first.allSatisfy(\.isHexDigit))

        XCTAssertFalse(try ServeToken.create(path: path), "an existing token is kept")
        XCTAssertEqual(try ServeToken.load(path: path), first)
    }

    func testGeneratedTokensDiffer() {
        XCTAssertNotEqual(ServeToken.generate(), ServeToken.generate())
    }

    func testLoadRejectsGroupOrWorldReadable() throws {
        for mode in [0o644, 0o640, 0o604] {
            let path = try write(valid, mode: mode)
            XCTAssertThrowsError(try ServeToken.load(path: path)) {
                XCTAssertEqual($0 as? ServeToken.LoadError, .permissionsTooOpen(path, mode: UInt16(mode)))
            }
        }
        let path = try write(valid, mode: 0o644)
        XCTAssertThrowsError(try ServeToken.load(path: path)) {
            XCTAssertEqual($0.localizedDescription,
                           "\(path) is readable by other users (mode 644). Run: chmod 600 \(path)")
        }
    }

    func testLoadRejectsASymlink() throws {
        let target = try write(valid, mode: 0o600, name: "real")
        let link = directory + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertThrowsError(try ServeToken.load(path: link)) {
            XCTAssertEqual($0 as? ServeToken.LoadError, .notRegularFile(link))
        }
    }

    /// Someone who can write the directory can replace the file, whatever its own mode.
    func testLoadRejectsADirectoryOthersCanWrite() throws {
        let path = try write(valid, mode: 0o600)
        for mode in [0o777, 0o775, 0o757] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory)
            XCTAssertThrowsError(try ServeToken.load(path: path)) {
                XCTAssertEqual($0 as? ServeToken.LoadError, .directoryTooOpen(directory, mode: UInt16(mode)))
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        XCTAssertEqual(try ServeToken.load(path: path), valid, "readable by others is fine; writable is not")
    }

    func testLoadRejectsADirectoryInPlaceOfTheFile() throws {
        let path = directory + "/token"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ServeToken.load(path: path)) {
            XCTAssertEqual($0 as? ServeToken.LoadError, .notRegularFile(path))
        }
    }

    func testLoadRejectsAShortToken() throws {
        let path = try write(String(valid.dropLast()), mode: 0o600)
        XCTAssertThrowsError(try ServeToken.load(path: path)) {
            XCTAssertEqual($0 as? ServeToken.LoadError, .tooShort(path))
        }
    }

    func testLoadReturnsTheTrimmedToken() throws {
        let path = try write("  " + valid + "\n\n", mode: 0o600)
        XCTAssertEqual(try ServeToken.load(path: path), valid)
    }

    func testMissingFileNamesInstallAgent() {
        let path = directory + "/absent"
        XCTAssertThrowsError(try ServeToken.load(path: path)) {
            XCTAssertEqual($0 as? ServeToken.LoadError, .missing(path))
            XCTAssertEqual($0.localizedDescription,
                           "No token file at \(path). Run `mirroir-mcp install-agent`, which creates it.")
        }
    }

    func testMatchesIsExact() {
        XCTAssertTrue(ServeToken.matches(presented: valid, expected: valid))
        XCTAssertFalse(ServeToken.matches(presented: String(valid.dropLast()), expected: valid), "a prefix")
        XCTAssertFalse(ServeToken.matches(presented: valid + "a", expected: valid), "an extension")
        XCTAssertFalse(ServeToken.matches(presented: String(valid.dropLast()) + "c", expected: valid))
        XCTAssertFalse(ServeToken.matches(presented: "", expected: valid))
    }
}
