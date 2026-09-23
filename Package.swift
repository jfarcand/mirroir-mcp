// swift-tools-version: 6.0
// ABOUTME: Swift package manifest for the Mirroir MCP server.
// ABOUTME: Deployment target is macOS 14 for API availability; iPhone Mirroring requires macOS 15+ at runtime.

import Foundation
import PackageDescription

// MARK: - Optional embacle FFI

/// Where Homebrew puts `libembacle.a`, Apple Silicon first then Intel.
let embacleLibraryDirectories = [
    "/opt/homebrew/opt/embacle-ffi/lib",
    "/opt/homebrew/lib",
    "/usr/local/opt/embacle-ffi/lib",
    "/usr/local/lib",
]

/// Whether `libembacle.a` is actually installed on this machine.
///
/// The manifest looks for the library rather than assuming it, because the
/// `CEmbacle` module cannot answer the question: its header ships in this
/// repository, so `canImport(CEmbacle)` is true everywhere and its modulemap
/// auto-links `embacle` whether or not the library exists. Deciding here is
/// what makes the no-op stub in `EmbacleFFI.swift` reachable, and a build
/// without embacle installed link and fall back to Apple Vision OCR.
///
/// Set `MIRROIR_DISABLE_EMBACLE=1` to build the OCR-only variant on a machine
/// that does have the library — the configuration most users run, and the one
/// to reproduce their reports in.
let embacleAvailable: Bool = {
    if ProcessInfo.processInfo.environment["MIRROIR_DISABLE_EMBACLE"] == "1" {
        return false
    }
    return embacleLibraryDirectories.contains { directory in
        FileManager.default.fileExists(atPath: directory + "/libembacle.a")
    }
}()

let embacleTargets: [Target] = embacleAvailable
    ? [.systemLibrary(name: "CEmbacle", path: "Sources/CEmbacle")]
    : []

let embacleDependencies: [Target.Dependency] = embacleAvailable ? ["CEmbacle"] : []

/// `-L` search paths, added only when there is a library to find. Passing them
/// unconditionally produces "search path not found" warnings on every machine
/// without embacle.
let embacleLinkerSettings: [LinkerSetting] = embacleAvailable
    ? [.unsafeFlags(embacleLibraryDirectories.map { "-L" + $0 })]
    : []

/// Compiled in only when the library is present; `EmbacleFFI.swift` selects its
/// stub otherwise.
let embacleSwiftSettings: [SwiftSetting] = embacleAvailable ? [.define("EMBACLE")] : []

let package = Package(
    name: "mirroir-mcp",
    platforms: [
        .macOS(.v14)
    ],
    targets: embacleTargets + [
        .target(
            name: "HelperLib",
            path: "Sources/HelperLib",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("CoreText"),
            ]
        ),
        .executableTarget(
            name: "mirroir-mcp",
            dependencies: ["HelperLib"] + embacleDependencies,
            swiftSettings: embacleSwiftSettings,
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreML"),
            ] + embacleLinkerSettings
        ),
        .target(
            name: "MirroirCoreDevice",
            path: "Sources/MirroirCoreDevice",
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedLibrary("z"),
            ]
        ),
        .executableTarget(
            name: "FakeMirroring",
            dependencies: ["HelperLib"],
            path: "Sources/FakeMirroring",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "HelperLibTests",
            dependencies: ["HelperLib"]
        ),
        .testTarget(
            name: "MirroirCoreDeviceTests",
            dependencies: ["MirroirCoreDevice"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "MCPServerTests",
            dependencies: ["mirroir-mcp", "HelperLib"],
            swiftSettings: embacleSwiftSettings
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["mirroir-mcp", "HelperLib"],
            swiftSettings: embacleSwiftSettings,
            linkerSettings: [
                .linkedFramework("Vision"),
            ]
        ),
        .testTarget(
            name: "TestRunnerTests",
            dependencies: ["mirroir-mcp", "HelperLib"],
            swiftSettings: embacleSwiftSettings
        ),
    ]
)
