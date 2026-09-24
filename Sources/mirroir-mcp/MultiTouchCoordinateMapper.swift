// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Maps multi_touch coordinates from the mirroring window's point space to the device viewport's points.
// ABOUTME: Scales each axis from the window size to the viewport WebDriverAgent reports, refusing an orientation mismatch.

import CoreGraphics
import Foundation

/// Why window coordinates cannot be placed on the device viewport.
enum MultiTouchMappingError: Error, Equatable, CustomStringConvertible {
    /// A size with a zero, negative or non-finite side.
    case degenerateSize(role: String, size: CGSize)
    /// The mirroring window and the device viewport disagree on orientation.
    case orientationMismatch(window: CGSize, device: CGSize)

    var description: String {
        switch self {
        case .degenerateSize(let role, let size):
            return "The \(role) size \(Int(size.width))x\(Int(size.height)) cannot place a touch."
        case .orientationMismatch(let window, let device):
            let windowOrientation = DeviceOrientation(size: window).rawValue
            let deviceOrientation = DeviceOrientation(size: device).rawValue
            return "The mirroring window is \(windowOrientation) (\(Int(window.width))x"
                + "\(Int(window.height))) but WebDriverAgent reports a \(deviceOrientation) "
                + "viewport (\(Int(device.width))x\(Int(device.height)) points). The screen is "
                + "probably mid-rotation, or the foreground app does not match what Mirroring "
                + "shows; wait for it to settle and call multi_touch again."
        }
    }
}

/// Converts window-relative points (the space `tap` uses) to device points.
///
/// The mirroring window shows the iPhone screen edge to edge at the iPhone's
/// aspect ratio, so a window point maps to the device by scaling each axis
/// from the window size to the viewport size. WebDriverAgent reports the
/// viewport in the foreground app's interface orientation (landscape is
/// wider than tall), the same orientation the mirroring window takes, and
/// interprets action coordinates in that orientation. When the two disagree
/// the mapping would land touches in the wrong place, so it is refused.
enum MultiTouchCoordinateMapper {
    /// Device coordinates are rounded to this many decimal places: far below
    /// a pixel, and it keeps the request body readable.
    static let decimalPlaces = 2

    /// The device point for window point `point`.
    static func devicePoint(_ point: CGPoint, window: CGSize, device: CGSize) -> CGPoint {
        CGPoint(x: round(point.x * device.width / window.width),
                y: round(point.y * device.height / window.height))
    }

    /// `timelines` in device points, checked for orientation first.
    static func map(_ timelines: [FingerTimeline], window: CGSize,
                    device: CGSize) throws(MultiTouchMappingError) -> [FingerTimeline] {
        try checkUsable(window, role: "mirroring window")
        try checkUsable(device, role: "device viewport")
        guard DeviceOrientation(size: window) == DeviceOrientation(size: device) else {
            throw .orientationMismatch(window: window, device: device)
        }
        return timelines.map { timeline in
            timeline.mappingPoints { devicePoint($0, window: window, device: device) }
        }
    }

    private static func checkUsable(_ size: CGSize, role: String) throws(MultiTouchMappingError) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw .degenerateSize(role: role, size: size)
        }
    }

    private static func round(_ value: CGFloat) -> CGFloat {
        let scale = pow(10, CGFloat(decimalPlaces))
        return (value * scale).rounded() / scale
    }
}
