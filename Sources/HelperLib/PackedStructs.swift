// ABOUTME: Packed C struct definitions for the Karabiner DriverKit virtual HID wire protocol.
// ABOUTME: Shared between the helper daemon (sends reports) and test targets (validates layout).

import Foundation

/// Keyboard initialization parameters (24 bytes).
/// Matches virtual_hid_keyboard_parameters in parameters.hpp.
/// Fields are uint64_t strong_typedefs in C++ (vendor_id, product_id, country_code).
///
/// Uses Apple vendor ID (0x5ac) so macOS attaches AppleHIDKeyboardEventDriver
/// to the virtual device. Non-Apple vendor IDs get AppleUserHIDEventService
/// which does not generate keyboard CGEvents.
public struct KeyboardParameters: Sendable {
    public var vendorID: UInt64 = 0x05ac
    public var productID: UInt64 = 0x0250
    public var countryCode: UInt64 = 0

    public init() {}

    public func toBytes() -> [UInt8] {
        var copy = self
        return withUnsafeBytes(of: &copy) { Array($0) }
    }
}

/// Pointing device input report (8 bytes, packed).
/// Matches pointing_input in pointing_input.hpp.
public struct PointingInput: Sendable {
    public var buttons: UInt32 = 0
    public var x: Int8 = 0
    public var y: Int8 = 0
    public var verticalWheel: Int8 = 0
    public var horizontalWheel: Int8 = 0

    public init() {}

    public func toBytes() -> [UInt8] {
        var copy = self
        return withUnsafeBytes(of: &copy) { Array($0) }
    }
}

/// Keyboard input report (67 bytes when packed, matching C++ __attribute__((packed))).
/// Swift MemoryLayout is 68 bytes due to alignment padding before the keys tuple.
/// The toBytes() method produces the correct 67-byte packed layout.
/// Matches keyboard_input in keyboard_input.hpp.
public struct KeyboardInput: Sendable {
    public var reportID: UInt8 = 1
    public var modifiers: UInt8 = 0
    public var reserved: UInt8 = 0
    public var keys: (
        UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
        UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
        UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16,
        UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    public init() {}

    public mutating func insertKey(_ keyCode: UInt16) {
        withUnsafeMutableBytes(of: &keys) { buf in
            let keysPtr = buf.bindMemory(to: UInt16.self)
            for i in 0..<32 {
                if keysPtr[i] == 0 {
                    keysPtr[i] = keyCode
                    return
                }
            }
        }
    }

    public mutating func clearKeys() {
        keys = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    /// Serialize to 67 bytes matching C++ packed layout (no alignment padding).
    /// C++ layout: [reportID(1), modifiers(1), reserved(1), keys(64)] = 67 bytes.
    /// Swift adds 1 byte padding before keys for UInt16 alignment — we skip it.
    public func toBytes() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(67)
        bytes.append(reportID)
        bytes.append(modifiers)
        bytes.append(reserved)
        var keysCopy = keys
        withUnsafeBytes(of: &keysCopy) { bytes.append(contentsOf: $0) }
        return bytes
    }
}

/// Keyboard modifier flags matching the Karabiner modifier bitmask.
public struct KeyboardModifier: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let leftControl  = KeyboardModifier(rawValue: 0x01)
    public static let leftShift    = KeyboardModifier(rawValue: 0x02)
    public static let leftOption   = KeyboardModifier(rawValue: 0x04)
    public static let leftCommand  = KeyboardModifier(rawValue: 0x08)
    public static let rightControl = KeyboardModifier(rawValue: 0x10)
    public static let rightShift   = KeyboardModifier(rawValue: 0x20)
    public static let rightOption  = KeyboardModifier(rawValue: 0x40)
    public static let rightCommand = KeyboardModifier(rawValue: 0x80)
}
