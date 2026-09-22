// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Builds and posts the CGEvent trackpad gesture events (type 29) that pinch and rotate need.
// ABOUTME: Stamps each event with the multitouch trackpad sender ID so iPhone Mirroring accepts it.

import CoreGraphics
import Foundation

/// Live `GestureEventPosting`: the measured trackpad gesture recipe.
///
/// A real trackpad pinch or rotate is a stream of CGEvent type 29 events. Each
/// sub-gesture event carries its subtype, phase and delta in undocumented
/// fields, and every event (including the bare container event before each
/// sub-gesture event, and the pointer move that sets the gesture centre) names
/// the trackpad's HID service as its sender. iPhone Mirroring ignores a gesture
/// whose sender is 0. The field numbers below were measured from a real
/// trackpad; they have no public CGEventField names.
struct CGEventGesturePoster: GestureEventPosting, CGEventPointerEngaging {

    /// Event type of a trackpad gesture (kCGSEventGesture).
    static let gestureEventType: UInt32 = 29
    /// Registry entry ID of the HID service that produced the event.
    static let senderIDField: UInt32 = 87
    /// Set to 1 on every event a real trackpad gesture posts.
    static let trackpadMarkerField: UInt32 = 45
    /// Value of `trackpadMarkerField` on trackpad gesture events.
    static let trackpadMarkerValue: Int64 = 1
    /// Gesture subtype (`GestureKind`: 8 zoom, 5 rotate).
    static let subtypeField: UInt32 = 110
    /// Gesture phase (`GesturePhase`: 1 began, 2 changed, 4 ended).
    static let phaseField: UInt32 = 132
    /// Fields that carry the delta as a double.
    static let deltaDoubleFields: [UInt32] = [113, 114, 116, 118]
    /// Fields that carry the delta as the bit pattern of a 32-bit float.
    static let deltaFloatBitsFields: [UInt32] = [115, 117, 164]

    func post(_ event: GestureEvent, at centre: CGPoint, senderID: UInt64,
              targetPID: pid_t?) -> Bool {
        guard let cgEvent = Self.makeEvent(event, at: centre, senderID: senderID) else {
            return false
        }
        CGEventInput.post(cgEvent, targetPID: targetPID)
        return true
    }

    func pause(microseconds: UInt32) {
        usleep(microseconds)
    }

    /// Build the CGEvent for one gesture event, or nil when CoreGraphics
    /// hands back no event or rejects a field number.
    static func makeEvent(_ event: GestureEvent, at centre: CGPoint,
                          senderID: UInt64) -> CGEvent? {
        let cgEvent: CGEvent
        switch event {
        case .pointerMove:
            guard let move = CGEventInput.makeMouseEvent(.mouseMoved, at: centre) else { return nil }
            cgEvent = move
        case .container, .gesture:
            guard let bare = CGEvent(source: nil),
                  let type = CGEventType(rawValue: gestureEventType) else { return nil }
            bare.type = type
            bare.location = centre
            guard set(bare, trackpadMarkerField, trackpadMarkerValue) else { return nil }
            cgEvent = bare
        }
        guard set(cgEvent, senderIDField, Int64(bitPattern: senderID)) else { return nil }

        if case .gesture(let kind, let phase, let delta) = event {
            guard set(cgEvent, subtypeField, kind.rawValue),
                  set(cgEvent, phaseField, phase.rawValue) else { return nil }
            for field in deltaDoubleFields {
                guard let cgField = CGEventField(rawValue: field) else { return nil }
                cgEvent.setDoubleValueField(cgField, value: delta)
            }
            let floatBits = Int64(Float(delta).bitPattern)
            for field in deltaFloatBitsFields {
                guard set(cgEvent, field, floatBits) else { return nil }
            }
        }
        return cgEvent
    }

    private static func set(_ event: CGEvent, _ field: UInt32, _ value: Int64) -> Bool {
        guard let cgField = CGEventField(rawValue: field) else { return false }
        event.setIntegerValueField(cgField, value: value)
        return true
    }
}
