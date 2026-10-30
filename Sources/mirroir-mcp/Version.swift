// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Single source of truth for the mirroir-mcp semantic version string.
// ABOUTME: The release workflow bumps `current` here; MCPServer and tests read it (no per-site literals).

/// Canonical semantic version of the mirroir-mcp server.
///
/// This is the one place the version literal lives in Swift. `MCPServer`'s
/// `initialize` response and the routing test both read `MirroirVersion.current`,
/// so there is no string to drift between them. The release workflow bumps this
/// constant in lockstep with `npm/package.json` and `server.json`.
enum MirroirVersion {
    /// Semantic version (`X.Y.Z`) reported in the MCP `initialize` handshake.
    static let current = "0.42.0"
}
