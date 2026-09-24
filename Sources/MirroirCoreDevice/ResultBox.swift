// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Lock-guarded single-assignment slot bridging a framework callback to a caller blocked on a semaphore.
// ABOUTME: Shared by the RTP sink (Network.framework) and the CoreDeviceService connection (libxpc).

import Foundation

/// A lock-guarded slot a callback fills once and the blocked caller reads
/// after its semaphore fires. Later results are ignored.
final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func set(_ result: Result<Value, Error>) {
        lock.withLock {
            if stored == nil { stored = result }
        }
    }

    var value: Result<Value, Error>? {
        lock.withLock { stored }
    }
}
