// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Shared helper for constructing Unix domain socket addresses.
// ABOUTME: Eliminates triplicated sockaddr_un construction across CommandServer, KarabinerClient, and HelperClient.

import Darwin

/// Construct a `sockaddr_un` from a filesystem path.
///
/// Copies the path bytes into `sun_path` with null termination, clamping
/// to the maximum length supported by the platform.
public func makeUnixAddress(path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
        for i in 0..<min(pathBytes.count, sunPath.count - 1) {
            sunPath[i] = pathBytes[i]
        }
        sunPath[min(pathBytes.count, sunPath.count - 1)] = 0
    }
    return addr
}
