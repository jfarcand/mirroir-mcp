// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for `mirroir-mcp bundle-app`: its command line, the extension bundle's names, its icon PNG and signature.
// ABOUTME: Builds in a temporary directory around a copy of /usr/bin/true; the signature test runs the real codesign ad hoc.

import ImageIO
import XCTest
@testable import mirroir_mcp

final class BundleAppCommandTests: XCTestCase {

    private var directory = ""
    private var binary = ""
    private var app: String { directory + "/server/mirroir-mcp.app" }
    private var icon: String { directory + "/icon.png" }

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "bundle-app-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        binary = directory + "/mirroir-mcp"
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: binary)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
    }

    func testTheCommandLineNeedsAnAppPathEndingInApp() throws {
        XCTAssertEqual(try BundleAppCommand.parseArguments(["--app", "a/mirroir-mcp.app", "--icon", "i.png"]),
                       BundleAppConfig(appPath: "a/mirroir-mcp.app", iconPath: "i.png"))
        XCTAssertEqual(try BundleAppCommand.parseArguments(["--app", "x.app"]),
                       BundleAppConfig(appPath: "x.app", iconPath: nil))
        XCTAssertThrowsError(try BundleAppCommand.parseArguments([])) {
            XCTAssertEqual($0 as? CLIArgumentError, .missingArgument("--app <path.app>", command: "bundle-app"))
        }
        XCTAssertThrowsError(try BundleAppCommand.parseArguments(["--app", "server/mirroir-mcp"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .invalidValue(
                flag: "--app", value: "server/mirroir-mcp", expected: "a path ending in .app"))
        }
        XCTAssertThrowsError(try BundleAppCommand.parseArguments(["--icon"])) {
            XCTAssertEqual($0 as? CLIArgumentError, .missingValue(flag: "--icon"))
        }
    }

    /// The panes list the bundle as "mirroir-mcp" under its own identifier,
    /// never the serve agent's, and the manifest's paths point into it.
    func testTheExtensionBundleCarriesItsOwnNamesAndAnIcon() throws {
        try BundleAppCommand.build(config: BundleAppConfig(appPath: app, iconPath: icon),
                                   executable: binary, version: "0.48.0") { _ in nil }

        let executable = app + "/Contents/MacOS/mirroir-mcp"
        XCTAssertEqual(ServeAppBundle.executablePath(in: app, spec: .extensionServer), executable)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable))
        let data = try Data(contentsOf: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "dev.mirroir.mcp")
        XCTAssertNotEqual(plist["CFBundleIdentifier"] as? String, ServeAppBundle.identifier)
        XCTAssertEqual(plist["CFBundleName"] as? String, "mirroir-mcp")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "mirroir-mcp")
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "0.48.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app + "/Contents/Resources/AppIcon.icns"))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: icon) as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, BundleAppCommand.iconPixels)
        XCTAssertEqual(image.height, BundleAppCommand.iconPixels)
    }

    func testTheAdHocSignatureOverTheExtensionBundleVerifies() throws {
        try BundleAppCommand.build(config: BundleAppConfig(appPath: app, iconPath: nil),
                                   executable: binary, version: "0.48.0") {
            ServeSigningIdentity.sign($0, fingerprint: BundleAppCommand.adHocIdentity)
        }
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", app]
        try verify.run()
        verify.waitUntilExit()
        XCTAssertEqual(verify.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: icon), "no icon unless asked")
    }

    /// The manifest the release packs points at the executable this command writes.
    func testTheManifestStartsTheBundledExecutableAndNamesTheIcon() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("mcpb/manifest.json")
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let server = try XCTUnwrap(manifest["server"] as? [String: Any])
        XCTAssertEqual(server["entry_point"] as? String, "server/mirroir-mcp.app/Contents/MacOS/mirroir-mcp")
        XCTAssertEqual(manifest["icon"] as? String, "icon.png")
        let longDescription = try XCTUnwrap(manifest["long_description"] as? String)
        XCTAssertFalse(longDescription.contains("host app"), "the grants go to mirroir-mcp, not Claude")
    }
}
