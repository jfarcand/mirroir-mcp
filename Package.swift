// swift-tools-version: 6.0
// ABOUTME: Swift package manifest for the iPhone Mirroring MCP server.
// ABOUTME: Targets macOS 14+ for AXUIElement, CGEvent, and CGWindowImage APIs.

import PackageDescription

let package = Package(
    name: "iphone-mirroir-mcp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "HelperLib",
            path: "Sources/HelperLib",
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "iphone-mirroir-mcp",
            dependencies: ["HelperLib"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "iphone-mirroir-helper",
            dependencies: ["HelperLib"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .testTarget(
            name: "HelperLibTests",
            dependencies: ["HelperLib"]
        ),
    ]
)
