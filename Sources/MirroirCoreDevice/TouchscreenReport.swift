// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Builds the UniversalHID DigitizerReport (report ID 9, 58 bytes) for one to five touch contacts.
// ABOUTME: Field map from the host UniversalHID report descriptor (ipb descriptors.txt); single contact matches go-ios.
//
// Portions derived from go-ios (https://github.com/danielpaulus/go-ios),
// Copyright (c) 2019 danielpaulus, MIT License. See THIRD_PARTY_NOTICES.md.

import Foundation

/// One finger on the touchscreen within a digitizer report.
public struct TouchContact: Equatable, Sendable {
    /// Contact identifier; the descriptor's logical range is 0...4.
    public let identifier: UInt8
    /// Whether the finger is on the glass. `false` reports the lift.
    public let touching: Bool
    /// Horizontal position, 0...65535 across the screen whatever its pixel size.
    public let x: UInt16
    /// Vertical position, 0...65535 down the screen.
    public let y: UInt16

    public init(identifier: UInt8, touching: Bool, x: UInt16, y: UInt16) {
        self.identifier = identifier
        self.touching = touching
        self.x = x
        self.y = y
    }
}

/// The touchscreen `DigitizerReport`, as the host `UniversalHID` descriptor
/// defines it (464 bits, dumped in ipb `Experiments/hid-descriptors`):
///
/// | bytes  | field |
/// | ------ | ----- |
/// | 0      | report ID 9 |
/// | 1      | ContactCount: contacts described by this report, at most 5 |
/// | 2      | ContactCountMaximum: 5 |
/// | 3..27  | five 40-bit finger slots at byte 3 + 5i: id (5 bits), resting, touch, inRange, X u16 LE, Y u16 LE |
/// | 28..39 | embedded scroll collection, left zero |
/// | 40..44 | per-contact identity, one byte per slot (usage 0xff1a/0xe0f4) |
/// | 45..52 | `remoteTimestamp`, 8 bytes LE (AppleVendor 0x102) |
/// | 53..57 | swipe flags and padding, left zero |
///
/// go-ios (`ios/hid/report.go`) writes a 6-byte timestamp at byte 44. The
/// descriptor puts byte 44 inside the identity field (slot 4's identity) and
/// the timestamp at 45..52, so this builder follows the descriptor. The two
/// layouts agree on every other byte of a single-contact report.
public enum TouchscreenReport {
    /// Report ID of the digitizer report.
    public static let reportID: UInt8 = 0x09
    /// Total report size in bytes; the device rejects any other size.
    public static let length = 58
    /// Contacts one report can describe (the descriptor's ContactCount maximum).
    public static let maximumContacts = 5
    /// Highest contact identifier the descriptor accepts (logical maximum 4).
    public static let maximumIdentifier: UInt8 = 4

    static let contactCountOffset = 1
    static let contactCountMaximumOffset = 2
    static let firstSlotOffset = 3
    static let slotLength = 5
    static let slotXOffset = 1
    static let slotYOffset = 3
    static let identityOffset = 40
    static let timestampOffset = 45
    static let timestampLength = 8

    static let identifierMask: UInt8 = 0x1F
    static let restingBit: UInt8 = 1 << 5
    static let touchBit: UInt8 = 1 << 6
    static let inRangeBit: UInt8 = 1 << 7

    /// Value written to each described contact's identity byte. go-ios writes
    /// 0x02 for its single contact; 2 is `kIOHIDDigitizerTransducerTypeFinger`,
    /// which is the reading adopted here. The descriptor names the usage but not
    /// its values, so whether the device reads it per contact is unverified.
    public static let fingerIdentity: UInt8 = 0x02

    /// Builds one report describing `contacts`, stamped with `timestamp`
    /// (monotonic nanoseconds: the device reads ordering and deltas only).
    ///
    /// Every contact passed is described, lifted ones included: ContactCount is
    /// the number of contacts in this report, not the number still touching, so
    /// a lift is only seen if the lifted contact is in the report that lifts it.
    public static func build(contacts: [TouchContact], timestamp: UInt64) throws -> Data {
        try validate(contacts)
        var report = [UInt8](repeating: 0, count: length)
        report[0] = reportID
        report[contactCountOffset] = UInt8(contacts.count)
        report[contactCountMaximumOffset] = UInt8(maximumContacts)
        for (slot, contact) in contacts.enumerated() {
            let base = firstSlotOffset + slot * slotLength
            report[base] = stateByte(for: contact)
            write(contact.x, into: &report, at: base + slotXOffset)
            write(contact.y, into: &report, at: base + slotYOffset)
            report[identityOffset + slot] = fingerIdentity
        }
        var stamp: [UInt8] = []
        stamp.appendUInt64LE(timestamp)
        report.replaceSubrange(timestampOffset..<(timestampOffset + timestampLength), with: stamp)
        return Data(report)
    }

    /// The first byte of a finger slot: identifier in the low five bits, then
    /// resting (never set), touch, and inRange. A touching finger is in range;
    /// a lifted one is neither, matching go-ios's 0xC2 / 0x02 for contact 2.
    static func stateByte(for contact: TouchContact) -> UInt8 {
        var state = contact.identifier & identifierMask
        if contact.touching {
            state |= touchBit | inRangeBit
        }
        return state
    }

    private static func write(_ value: UInt16, into report: inout [UInt8], at offset: Int) {
        var bytes: [UInt8] = []
        bytes.appendUInt16LE(value)
        report.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private static func validate(_ contacts: [TouchContact]) throws {
        guard (1...maximumContacts).contains(contacts.count) else {
            throw TouchReportError.contactCountOutOfRange(count: contacts.count, maximum: maximumContacts)
        }
        var seen = Set<UInt8>()
        for contact in contacts {
            guard contact.identifier <= maximumIdentifier else {
                throw TouchReportError.contactIdentifierOutOfRange(
                    identifier: contact.identifier, maximum: maximumIdentifier)
            }
            guard seen.insert(contact.identifier).inserted else {
                throw TouchReportError.duplicateContactIdentifier(contact.identifier)
            }
        }
    }
}
