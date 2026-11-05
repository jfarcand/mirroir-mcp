// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Focus-free clicks and keystrokes for one window, posted as SkyLight event records addressed by window ID.
// ABOUTME: The user's front app and cursor stay where they are; taps, double taps and long presses are built on it.

import CoreGraphics
import Foundation

/// The click sequences every `WindowEventPosting` builds from button
/// presses: a tap, a long press and a double tap. Points are window-local.
extension WindowEventPosting {

    /// Press and lift at `point`, held for `holdUs`.
    func click(at point: CGPoint, holdUs: UInt32, in window: WindowInfo) -> Bool {
        guard postButton(down: true, at: point, clickCount: 1, in: window) else { return false }
        pause(microseconds: holdUs)
        return postButton(down: false, at: point, clickCount: 1, in: window)
    }

    /// Two clicks at `point`, the second numbered 2 so it reads as a double
    /// click; `gapUs` separates the clicks and holds each one.
    func doubleClick(at point: CGPoint, gapUs: UInt32, in window: WindowInfo) -> Bool {
        for clickCount in 1...2 {
            if clickCount > 1 { pause(microseconds: gapUs) }
            guard postButton(down: true, at: point, clickCount: clickCount, in: window) else {
                return false
            }
            pause(microseconds: gapUs)
            guard postButton(down: false, at: point, clickCount: clickCount, in: window) else {
                return false
            }
        }
        return true
    }
}

/// Posts mouse-button records straight to a window through SkyLight's
/// `SLPSPostEventRecordTo`, the call the window server uses to hand a process
/// an event for one of its windows. The record names the window, so the
/// event reaches it wherever the user's focus is and whatever covers it, and
/// the app is never made active. A record whose location is blanked
/// (all-ones) makes the window its app's key window without a click, which
/// is how keystrokes posted to the process find it.
///
/// Measured on macOS 26.5 against iPhone Mirroring and FakeMirroring: taps,
/// double taps, long presses and keystrokes land with another app in front;
/// drag records lose their intermediate points, so drags and swipes stay on
/// the HID path.
final class SkyLightWindowPoster: WindowEventPosting, @unchecked Sendable {

    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias PostEventRecord =
        @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32

    /// The live poster, or nil when this macOS does not export the SkyLight
    /// and Process Manager entry points it calls.
    static let live: SkyLightWindowPoster? = SkyLightWindowPoster()

    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let applicationServicesPath =
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"

    /// Byte layout of the window server's event record.
    private enum Record {
        static let size = 0xf8
        static let lengthOffset = 0x04
        static let typeOffset = 0x08
        static let globalLocationOffset = 0x10
        static let windowLocationOffset = 0x20
        static let windowLocationLength = 0x10
        static let flagsOffset = 0x3a
        static let windowIDOffset = 0x3c
        static let eventNumberOffset = 0x8a
        static let clickStateOffset = 0x8c
        static let pressureOffset = 0x90
        static let mouseDown: UInt8 = 1
        static let mouseUp: UInt8 = 2
        /// Marks the record as addressed to the window in `windowIDOffset`.
        static let windowTargeted: UInt8 = 0x10
        static let fullPressure: UInt8 = 0xff
        static let blankedLocationByte: UInt8 = 0xff
        /// Event numbers wrap inside a positive Int16.
        static let eventNumberMask: Int16 = 0x7fff
    }

    /// Size of a Process Manager serial number (two UInt32).
    private static let processSerialNumberSize = 8

    private let processForPID: ProcessForPID
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Int32
    /// Absent on a macOS without it; swipes then keep the HID path.
    private let setWindowLocation: SetWindowLocation?
    /// The event fields that name the window an event belongs to.
    private static let windowNumberFields = [51, 52, 91].compactMap { CGEventField(rawValue: $0) }
    private let postEventRecord: PostEventRecord
    private let lock = NSLock()
    /// The number of the last mouse-down posted, shared by its mouse-up.
    private var eventNumber: Int16

    private init?() {
        guard let skyLight = dlopen(Self.skyLightPath, RTLD_NOW),
              let services = dlopen(Self.applicationServicesPath, RTLD_NOW),
              let post = dlsym(skyLight, "SLPSPostEventRecordTo"),
              let psn = dlsym(services, "GetProcessForPID") else {
            DebugLog.log("skylight", "event-record entry points unavailable; window input disabled")
            return nil
        }
        setWindowLocation = dlsym(skyLight, "SLEventSetWindowLocation")
            .map { unsafeBitCast($0, to: SetWindowLocation.self) }
        postEventRecord = unsafeBitCast(post, to: PostEventRecord.self)
        processForPID = unsafeBitCast(psn, to: ProcessForPID.self)
        eventNumber = Int16(truncatingIfNeeded: getpid()) & Record.eventNumberMask
    }

    func postButton(down: Bool, at point: CGPoint, clickCount: Int, in window: WindowInfo) -> Bool {
        let number = down ? nextEventNumber() : currentEventNumber()
        return post(to: window) { record in
            record.storeBytes(of: down ? Record.mouseDown : Record.mouseUp,
                              toByteOffset: Record.typeOffset, as: UInt8.self)
            record.storeBytes(of: Double(window.position.x + point.x),
                              toByteOffset: Record.globalLocationOffset, as: Double.self)
            record.storeBytes(of: Double(window.position.y + point.y),
                              toByteOffset: Record.globalLocationOffset + 8, as: Double.self)
            record.storeBytes(of: Double(point.x),
                              toByteOffset: Record.windowLocationOffset, as: Double.self)
            record.storeBytes(of: Double(point.y),
                              toByteOffset: Record.windowLocationOffset + 8, as: Double.self)
            record.storeBytes(of: number, toByteOffset: Record.eventNumberOffset, as: Int16.self)
            record.storeBytes(of: Int32(clickCount), toByteOffset: Record.clickStateOffset, as: Int32.self)
            record.storeBytes(of: down ? Record.fullPressure : 0,
                              toByteOffset: Record.pressureOffset, as: UInt8.self)
        }
    }

    func focusKeys(in window: WindowInfo) -> Bool {
        [Record.mouseDown, Record.mouseUp].allSatisfy { type in
            post(to: window) { record in
                record.storeBytes(of: type, toByteOffset: Record.typeOffset, as: UInt8.self)
                for offset in 0..<Record.windowLocationLength {
                    record.storeBytes(of: Record.blankedLocationByte,
                                      toByteOffset: Record.windowLocationOffset + offset, as: UInt8.self)
                }
            }
        }
    }

    func pause(microseconds: UInt32) {
        usleep(microseconds)
    }

    var canStampEvents: Bool { setWindowLocation != nil }

    /// Without the window fields, a posted event finds no window and is dropped.
    /// Setting an event's location clears its window location, so that comes last.
    func stamp(_ event: CGEvent, at point: CGPoint, in window: WindowInfo) {
        event.location = CGPoint(x: window.position.x + point.x, y: window.position.y + point.y)
        for field in Self.windowNumberFields {
            event.setIntegerValueField(field, value: Int64(window.windowID))
        }
        _ = setWindowLocation?(event, point)
        event.timestamp = mach_absolute_time()
    }

    // MARK: - Private

    /// Build one record addressed to `window`, let `fill` set its event
    /// fields, and post it to the window's process.
    private func post(to window: WindowInfo, fill: (UnsafeMutableRawPointer) -> Void) -> Bool {
        let record = UnsafeMutableRawPointer.allocate(byteCount: Record.size, alignment: 8)
        defer { record.deallocate() }
        record.initializeMemory(as: UInt8.self, repeating: 0, count: Record.size)
        record.storeBytes(of: UInt8(Record.size), toByteOffset: Record.lengthOffset, as: UInt8.self)
        record.storeBytes(of: Record.windowTargeted, toByteOffset: Record.flagsOffset, as: UInt8.self)
        record.storeBytes(of: UInt32(window.windowID), toByteOffset: Record.windowIDOffset, as: UInt32.self)
        fill(record)

        let psn = UnsafeMutableRawPointer.allocate(byteCount: Self.processSerialNumberSize, alignment: 4)
        defer { psn.deallocate() }
        psn.initializeMemory(as: UInt8.self, repeating: 0, count: Self.processSerialNumberSize)
        guard processForPID(window.pid, psn) == noErr else {
            DebugLog.log("skylight", "no process serial number for pid \(window.pid)")
            return false
        }
        let status = postEventRecord(psn, record)
        if status != 0 { DebugLog.log("skylight", "post failed: \(status)") }
        return status == 0
    }

    private func nextEventNumber() -> Int16 {
        lock.lock()
        defer { lock.unlock() }
        eventNumber = (eventNumber &+ 1) & Record.eventNumberMask
        return eventNumber
    }

    private func currentEventNumber() -> Int16 {
        lock.lock()
        defer { lock.unlock() }
        return eventNumber
    }
}
