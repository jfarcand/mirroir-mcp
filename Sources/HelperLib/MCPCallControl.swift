/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: One tool call's cancellation and progress: the client cancels it, the tool checks it and reports progress.
// ABOUTME: Progress only rises, and nothing is reported once the call has finished or was cancelled.

import Foundation

/// The control a running tool call shares with the transport that received it.
///
/// The transport cancels it (a `notifications/cancelled` on stdio, a closed
/// connection on HTTP); the tool checks `isCancelled` between device actions
/// and reports progress with `report`. Progress reaches the client only when
/// it asked for it with a `progressToken`, only while the call runs, and only
/// when the value rises, as the protocol requires.
public final class MCPCallControl: @unchecked Sendable {
    /// Writes one `notifications/progress` params object to the client.
    public typealias Emit = @Sendable (JSONValue) -> Void

    private enum State {
        case running
        case cancelled(reason: String?)
        case finished
    }

    private let lock = NSLock()
    private let progressToken: JSONValue?
    private let emit: Emit?
    private var state = State.running
    private var lastProgress: Double?
    private var cancelHooks: [@Sendable () -> Void] = []

    /// - Parameters:
    ///   - progressToken: The token the client sent in `_meta.progressToken`,
    ///     or nil when it asked for no progress.
    ///   - emit: How a progress notification reaches the client, or nil when
    ///     this transport cannot carry one.
    public init(progressToken: JSONValue? = nil, emit: Emit? = nil) {
        self.progressToken = progressToken
        self.emit = emit
    }

    /// Whether the client cancelled the call.
    public var isCancelled: Bool {
        lock.withLock {
            if case .cancelled = state { return true }
            return false
        }
    }

    /// Why the client cancelled the call, when it said.
    public var cancelReason: String? {
        lock.withLock {
            if case .cancelled(let reason) = state { return reason }
            return nil
        }
    }

    /// Cancel the call. Ignored once it has finished or was already cancelled.
    public func cancel(reason: String?) {
        let hooks: [@Sendable () -> Void] = lock.withLock {
            guard case .running = state else { return [] }
            state = .cancelled(reason: reason)
            defer { cancelHooks = [] }
            return cancelHooks
        }
        hooks.forEach { $0() }
    }

    /// Run `hook` when the call is cancelled, or at once if it already was.
    /// A wait that the cancel must end registers here.
    public func onCancel(_ hook: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            switch state {
            case .running:
                cancelHooks.append(hook)
                return false
            case .cancelled:
                return true
            case .finished:
                return false
            }
        }
        if runNow { hook() }
    }

    /// Report progress. Sent only when the client asked for progress, the call
    /// is still running, and `progress` is above the last value sent.
    public func report(progress: Double, total: Double? = nil, message: String? = nil) {
        lock.withLock {
            guard case .running = state, let progressToken, let emit else { return }
            if let lastProgress, progress <= lastProgress { return }
            lastProgress = progress
            // Emitted under the lock, so no progress can follow `finish()`.
            emit(ProgressNotification.params(
                token: progressToken, progress: progress, total: total, message: message))
        }
    }

    /// Mark the call finished, before its response is written. Returns false
    /// when it was cancelled: a cancelled call gets no response.
    @discardableResult
    public func finish() -> Bool {
        lock.withLock {
            switch state {
            case .running:
                state = .finished
                cancelHooks = []
                return true
            case .cancelled:
                return false
            case .finished:
                return true
            }
        }
    }
}

/// The `notifications/progress` message and the token a request asks for it with.
public enum ProgressNotification {
    /// The notification's method.
    public static let method = "notifications/progress"

    /// The `progressToken` in a request's `_meta`, when it is a string or an
    /// integer, the two forms the protocol allows.
    public static func token(in params: JSONValue?) -> JSONValue? {
        guard let token = params?.member("_meta")?.member("progressToken") else { return nil }
        switch token {
        case .string:
            return token
        case .number(let value) where value.rounded() == value:
            return token
        default:
            return nil
        }
    }

    /// The params of one progress notification.
    public static func params(
        token: JSONValue, progress: Double, total: Double?, message: String?
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "progressToken": token,
            "progress": .number(progress),
        ]
        if let total { fields["total"] = .number(total) }
        if let message { fields["message"] = .string(message) }
        return .object(fields)
    }
}
