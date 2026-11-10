// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the serve agent's app bundle: its layout, Info.plist, copied binary, icon and signature.
// ABOUTME: Builds in a temporary directory; the signature test runs the real /usr/bin/codesign on a copy of /usr/bin/true.

import ImageIO
import XCTest
@testable import mirroir_mcp

final class ServeAppBundleTests: XCTestCase {

    private var directory = ""
    private var binary = ""
    private var bundle: String { directory + "/mirroir serve.app" }

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "serve-bundle-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        binary = directory + "/mirroir-mcp"
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: binary)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
    }

    private func info() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: bundle + "/Contents/Info.plist"))
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheBundleHoldsACopyOfTheBinaryAnInfoPlistAndTheIcon() throws {
        try ServeAppBundle.build(at: bundle, executable: binary, version: "1.2.3") { _ in nil }

        let copied = ServeAppBundle.executablePath(in: bundle)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: copied, andPath: binary))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: copied))
        let plist = try info()
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "dev.mirroir.serve")
        XCTAssertEqual(plist["CFBundleName"] as? String, "mirroir serve")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "mirroir serve", "Login Items shows this name")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "1.2.3")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true, "a background agent: no Dock icon")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle + "/Contents/Resources/AppIcon.icns"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory).sorted(),
                       ["mirroir serve.app", "mirroir-mcp"], "no staging folder is left behind")
    }

    /// One signature over the built bundle seals the Info.plist and the icon
    /// with the executable. The test signs ad hoc: the certificate install-agent
    /// uses lives in the login keychain, which a test must not touch.
    func testARealSignatureOverTheBundleVerifies() throws {
        try ServeAppBundle.build(at: bundle, executable: binary, version: "1.2.3") {
            ServeSigningIdentity.sign($0, fingerprint: "-")
        }
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", bundle]
        try verify.run()
        verify.waitUntilExit()
        XCTAssertEqual(verify.terminationStatus, 0)
        XCTAssertTrue(ServeSigningIdentity.isAdHocSigned(bundle))
    }

    func testAFailedSignatureLeavesThePreviousBundle() throws {
        try ServeAppBundle.build(at: bundle, executable: binary, version: "1.0.0") { _ in nil }
        XCTAssertThrowsError(
            try ServeAppBundle.build(at: bundle, executable: binary, version: "2.0.0") { _ in "no signer" }
        ) {
            XCTAssertEqual($0.localizedDescription, "the app bundle could not be signed: no signer")
        }
        XCTAssertEqual(try info()["CFBundleShortVersionString"] as? String, "1.0.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory).sorted(),
                       ["mirroir serve.app", "mirroir-mcp"])
    }

    func testARebuildReplacesTheBundle() throws {
        try ServeAppBundle.build(at: bundle, executable: binary, version: "1.0.0") { _ in nil }
        try ServeAppBundle.build(at: bundle, executable: binary, version: "2.0.0") { _ in nil }
        XCTAssertEqual(try info()["CFBundleShortVersionString"] as? String, "2.0.0")
    }

    func testAMissingBinaryIsNamed() {
        XCTAssertThrowsError(
            try ServeAppBundle.build(at: bundle, executable: directory + "/nothing", version: "1") { _ in nil }
        ) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("the app bundle could not be built"),
                          $0.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle))
    }

    func testTheIconHoldsEverySizeAndIsNotBlank() throws {
        let path = directory + "/AppIcon.icns"
        try ServeAppIcon.writeICNS(to: path)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let widths = (0..<CGImageSourceGetCount(source)).compactMap {
            CGImageSourceCreateImageAtIndex(source, $0, nil)?.width
        }
        XCTAssertEqual(Set(widths), Set(ServeAppIcon.pixelSizes))

        // The robot's left eye (viewBox 50,60) is green; the frame's corner is transparent.
        let image = try XCTUnwrap(ServeAppIcon.image(pixels: 128))
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        func rgba(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = y * image.bytesPerRow + x * 4
            return Array(pixels[offset..<offset + 4])
        }
        let eye = rgba(50, 60)
        XCTAssertGreaterThan(eye[1], eye[0], "green over red: \(eye)")
        XCTAssertEqual(eye[3], 255)
        XCTAssertEqual(rgba(1, 1)[3], 0, "outside the rounded frame")
    }
}
