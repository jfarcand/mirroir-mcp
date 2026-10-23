// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Warn-once utility: prints each distinct warning message at most once per process.
// ABOUTME: Used by EnvConfig accessors, which re-read settings on every access, to report a bad value once.

import Foundation

/// Prints each distinct warning once per process. Settings are re-read on every
/// access, so without this a bad value would warn on every request.
final class OnceWarner: @unchecked Sendable {
    /// Shared across every EnvConfig accessor; the lock guards `printed`.
    static let shared = OnceWarner()

    private let lock = NSLock()
    private var printed: Set<String> = []
    private let sink: @Sendable (String) -> Void

    /// - Parameter sink: where a first-time message goes; stderr by default.
    init(sink: @escaping @Sendable (String) -> Void = { fputs($0, stderr) }) {
        self.sink = sink
    }

    /// Send `message` to the sink unless it was sent before.
    func warn(_ message: String) {
        lock.lock()
        let isFirst = printed.insert(message).inserted
        lock.unlock()
        if isFirst { sink(message) }
    }
}
