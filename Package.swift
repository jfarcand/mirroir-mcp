// swift-tools-version: 6.2
// ABOUTME: Swift package manifest for the iPhone Mirroring MCP server.
// ABOUTME: Targets macOS 14+ for AXUIElement, CGEvent, and CGWindowImage APIs.

import PackageDescription

let package = Package(
    name: "iphone-mirroir-mcp",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "iphone-mirroir-mcp",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "iphone-mirroir-helper",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
