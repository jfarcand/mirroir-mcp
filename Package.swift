// swift-tools-version: 6.0
// ABOUTME: Swift package manifest for the iPhone Mirroring MCP server.
// ABOUTME: Deployment target is macOS 14 for API availability; iPhone Mirroring requires macOS 15+ at runtime.

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
                .linkedFramework("CoreText"),
            ]
        ),
        .executableTarget(
            name: "iphone-mirroir-mcp",
            dependencies: ["HelperLib"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("Vision"),
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
        .executableTarget(
            name: "FakeMirroring",
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
            name: "MCPServerTests",
            dependencies: ["iphone-mirroir-mcp", "HelperLib"]
        ),
        .testTarget(
            name: "HelperDaemonTests",
            dependencies: ["iphone-mirroir-helper", "HelperLib"]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["iphone-mirroir-mcp", "HelperLib"],
            linkerSettings: [
                .linkedFramework("Vision"),
            ]
        ),
        .testTarget(
            name: "TestRunnerTests",
            dependencies: ["iphone-mirroir-mcp", "HelperLib"]
        ),
    ]
)
