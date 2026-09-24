// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Stateful multi-touch session: tracks up to five held contacts and emits one digitizer report per change.
// ABOUTME: Guarantees no contact is left down: a failed send, close() and deinit all lift everything still held.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation

/// Drives multi-finger touch on one HID touchscreen service.
///
/// Each call emits one `DigitizerReport` describing every contact currently
/// held, so the device always sees the complete picture: moving one finger
/// re-reports the others where they are, and a lift reports the lifted
/// contact (touch clear) alongside the ones that stay down.
public final class MultiTouchSession {
    /// Produces the report timestamp: monotonic nanoseconds.
    public typealias TimestampSource = () -> UInt64

    private let sender: HIDReportSending
    private let serviceID: UInt64
    private let timestamp: TimestampSource
    private let lock = NSLock()
    /// Held contacts, in the order they went down (their slot order in reports).
    private var held: [TouchContact] = []
    private var closed = false

    /// - Parameters:
    ///   - sender: where reports go.
    ///   - serviceID: the touchscreen service; the main touchscreen by default.
    ///   - timestamp: report clock; defaults to nanoseconds of monotonic uptime.
    public init(sender: HIDReportSending,
                serviceID: UInt64 = UniversalHIDPayload.mainTouchscreenServiceID,
                timestamp: @escaping TimestampSource = { DispatchTime.now().uptimeNanoseconds }) {
        self.sender = sender
        self.serviceID = serviceID
        self.timestamp = timestamp
    }

    /// Lifts anything still held and closes the sender when the session is
    /// released without `close()`. A deinitialiser cannot throw, so a lift
    /// that fails here has no caller to reach; `close()` is the way to see it.
    deinit {
        _ = try? close()
    }

    /// Identifiers of the contacts currently held, in slot order.
    public var heldIdentifiers: [UInt8] {
        lock.withLock { held.map(\.identifier) }
    }

    /// Puts finger `identifier` down at (`x`, `y`).
    public func down(identifier: UInt8, x: UInt16, y: UInt16) throws {
        try withOpenSession {
            guard !held.contains(where: { $0.identifier == identifier }) else {
                throw MultiTouchSessionError.contactAlreadyDown(identifier)
            }
            let next = held + [TouchContact(identifier: identifier, touching: true, x: x, y: y)]
            try apply(described: next, resulting: next)
        }
    }

    /// Moves held finger `identifier` to (`x`, `y`).
    public func move(identifier: UInt8, x: UInt16, y: UInt16) throws {
        try withOpenSession {
            guard let index = held.firstIndex(where: { $0.identifier == identifier }) else {
                throw MultiTouchSessionError.contactNotDown(identifier)
            }
            var next = held
            next[index] = TouchContact(identifier: identifier, touching: true, x: x, y: y)
            try apply(described: next, resulting: next)
        }
    }

    /// Lifts finger `identifier` where it is. Lifting a finger that is not down
    /// sends nothing: a stray release must not desynchronise the device.
    public func lift(identifier: UInt8) throws {
        try withOpenSession {
            guard let index = held.firstIndex(where: { $0.identifier == identifier }) else { return }
            var described = held
            described[index] = Self.lifted(held[index])
            var remaining = held
            remaining.remove(at: index)
            try apply(described: described, resulting: remaining)
        }
    }

    /// Lifts every held finger in one report. A no-op when none is down.
    public func liftAll() throws {
        try withOpenSession {
            guard !held.isEmpty else { return }
            try apply(described: held.map(Self.lifted), resulting: [])
        }
    }

    /// Lifts anything still held, then closes the sender. Idempotent. The
    /// contacts are forgotten even when the lift fails, and the error is
    /// rethrown after the sender is closed.
    public func close() throws {
        let failure: Error? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            defer {
                held.removeAll()
                sender.close()
            }
            guard !held.isEmpty else { return nil }
            do {
                try send(held.map(Self.lifted))
                return nil
            } catch {
                return error
            }
        }
        if let failure { throw failure }
    }

    // MARK: - Internals

    private func withOpenSession(_ body: () throws -> Void) throws {
        try lock.withLock {
            guard !closed else { throw MultiTouchSessionError.closed }
            try body()
        }
    }

    /// Sends a report describing `described` and, once it is written, records
    /// `resulting` as the held set. A report that fails validation never
    /// reached the device and changes nothing. Any other failure leaves the
    /// device's view unknown, so every contact the failed report described
    /// (it always includes every held contact) is lifted at the position that
    /// report carried, and `MultiTouchSendError` reports both outcomes.
    private func apply(described: [TouchContact], resulting: [TouchContact]) throws {
        do {
            try send(described)
        } catch let error as TouchReportError {
            throw error
        } catch {
            let recovery = described.map(Self.lifted)
            held.removeAll()
            var recoveryError: Error?
            do {
                try send(recovery)
            } catch let liftError {
                recoveryError = liftError
            }
            throw MultiTouchSendError(underlying: error, recoveryLift: recovery, recoveryLiftError: recoveryError)
        }
        held = resulting
    }

    private static func lifted(_ contact: TouchContact) -> TouchContact {
        TouchContact(identifier: contact.identifier, touching: false, x: contact.x, y: contact.y)
    }

    private func send(_ contacts: [TouchContact]) throws {
        let report = try TouchscreenReport.build(contacts: contacts, timestamp: timestamp())
        try sender.sendReport(report, serviceID: serviceID)
    }
}
