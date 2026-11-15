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
// ABOUTME: Stamps a scroll event with the fields that make it read as a real trackpad frame: sender, line and velocity deltas.
// ABOUTME: iOS paging surfaces release and snap a flick only when its events name a real HID device and carry velocity.

import CoreGraphics
import Foundation
import IOKit

/// Scroll velocity for one frame, in the units of a real trackpad trace.
struct TrackpadVelocity: Equatable {
    let axis1: Double
    let axis2: Double

    static let zero = TrackpadVelocity(axis1: 0, axis2: 0)
}

/// Who a trackpad flick says it came from.
struct TrackpadSender: Equatable {
    /// The IORegistry ID of a real HID device, or nil when this Mac has none.
    let registryID: UInt64?

    static func current() -> TrackpadSender {
        let registryID = TrackpadScrollFields.senderDeviceID()
        if registryID == nil {
            DebugLog.log("swipe", "no HID device found; scroll events carry no sender")
        }
        return TrackpadSender(registryID: registryID)
    }
}

/// The undocumented scroll-event fields of a real trackpad frame, measured
/// from flicks through iPhone Mirroring.
///
/// Delta fields alone are not enough: a flick without the sender field parks
/// between pages, and one with the sender but no velocity fields returns to
/// the page it left. A made-up sender also returns to the page it left, so the
/// value has to be the registry ID of a real HID device.
enum TrackpadScrollFields {

    /// Points of scroll per line of the line and fixed-point delta fields.
    static let pointsPerLine: Double = 10.2
    /// A frame moving at least this many points reports one whole line.
    static let minimumPointsForWholeLine: Int32 = 5
    /// Scale of the 16.16 fixed-point delta fields.
    static let fixedPointScale: Double = 65536

    private static let lineDeltaAxis1 = CGEventField(rawValue: 11)!
    private static let lineDeltaAxis2 = CGEventField(rawValue: 12)!
    private static let continuousGesture = CGEventField(rawValue: 45)!
    private static let senderRegistryID = CGEventField(rawValue: 87)!
    private static let fixedDeltaAxis1 = CGEventField(rawValue: 93)!
    private static let fixedDeltaAxis2 = CGEventField(rawValue: 94)!
    private static let trackpadOrigin = CGEventField(rawValue: 137)!
    private static let deviceTimestamp = CGEventField(rawValue: 169)!
    private static let momentumStage = CGEventField(rawValue: 173)!
    private static let lineVelocityAxis2 = CGEventField(rawValue: 175)!
    private static let lineVelocityAxis1 = CGEventField(rawValue: 176)!
    private static let pointVelocityAxis2 = CGEventField(rawValue: 177)!
    private static let pointVelocityAxis1 = CGEventField(rawValue: 178)!

    /// The whole-line delta a real trackpad reports for a frame of `points`.
    static func lineDelta(points: Int32) -> Int64 {
        let whole = Int64((Double(points) / pointsPerLine).rounded(.towardZero))
        guard whole == 0, abs(points) >= minimumPointsForWholeLine else { return whole }
        return points < 0 ? -1 : 1
    }

    /// The 16.16 fixed-point delta a real trackpad reports for a frame of `points`.
    static func fixedDelta(points: Int32) -> Int64 {
        Int64(Double(points) / pointsPerLine * fixedPointScale)
    }

    /// Write the trackpad fields of one frame onto `event`. Velocity fields run
    /// opposite to the deltas, as they do in a real trace.
    static func apply(to event: CGEvent, step: SwipeWheelStep, velocity: TrackpadVelocity,
                      momentumPhase: Int64, senderID: UInt64?) {
        event.flags = []
        event.setIntegerValueField(continuousGesture, value: 1)
        event.setIntegerValueField(trackpadOrigin, value: 1)
        if let senderID {
            event.setIntegerValueField(senderRegistryID, value: Int64(bitPattern: senderID))
        }
        event.setIntegerValueField(deviceTimestamp, value: Int64(mach_absolute_time()))
        event.setIntegerValueField(momentumStage, value: momentumPhase)
        event.setIntegerValueField(lineDeltaAxis1, value: lineDelta(points: step.wheel1))
        event.setIntegerValueField(lineDeltaAxis2, value: lineDelta(points: step.wheel2))
        event.setIntegerValueField(fixedDeltaAxis1, value: fixedDelta(points: step.wheel1))
        event.setIntegerValueField(fixedDeltaAxis2, value: fixedDelta(points: step.wheel2))
        event.setDoubleValueField(lineVelocityAxis1, value: -Double(step.wheel1) / pointsPerLine)
        event.setDoubleValueField(lineVelocityAxis2, value: -Double(step.wheel2) / pointsPerLine)
        event.setDoubleValueField(pointVelocityAxis1, value: -velocity.axis1)
        event.setDoubleValueField(pointVelocityAxis2, value: -velocity.axis2)
    }

    /// IOKit classes whose registry ID a scroll event may name as its sender,
    /// in order of preference. A flick naming none parks between pages; one
    /// naming the built-in keyboard's driver paged 4 of 4 on an XR
    /// (2026-11-14), so a Mac with no trackpad still has a sender (carnet#42).
    static let senderServiceClasses = ["AppleMultitouchDevice", "AppleHIDKeyboardEventDriverV2",
                                       "IOHIDEventService"]

    /// The IORegistry ID of the first service of `senderServiceClasses` this
    /// Mac has, or nil when it has none of them.
    static func senderDeviceID() -> UInt64? {
        for serviceClass in senderServiceClasses {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceClass))
            guard service != IO_OBJECT_NULL else { continue }
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
                return entryID
            }
        }
        return nil
    }
}
