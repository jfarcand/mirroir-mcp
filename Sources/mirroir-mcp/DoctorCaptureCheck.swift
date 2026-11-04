// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Doctor's end-to-end proof that the iPhone screen can be read: one capture of the mirror, then OCR on it.
// ABOUTME: Catches a Screen Recording grant that is on but not yet in effect, which the permission bit alone reports as fine.

import CoreGraphics
import Foundation

/// A Screen Recording grant takes effect only once the app holding it
/// restarts; until then capture returns nothing or a blank frame while the
/// permission check passes. This check reads the mirror once, the way every
/// tool does, and reports what came back.
enum DoctorCaptureCheck {

    static let name = "Screen read"

    /// Capture the mirror and OCR it, read-only: nothing is tapped or typed.
    static func run(hostApp: String?) -> DoctorCheck {
        let target = IPhoneMirroringTarget.build(config: nil)
        let size = target.bridge.getWindowInfo()?.size
        return verdict(target.ocrDescriber.describe(settleTimeoutUs: 0), windowSize: size, hostApp: hostApp)
    }

    /// The check for what one describe of the mirror returned.
    static func verdict(_ result: ScreenDescriber.DescribeResult?, windowSize: CGSize?,
                        hostApp: String?) -> DoctorCheck {
        let restart = "quit and reopen \(hostApp.map { "\"\($0)\"" } ?? "the app that runs mirroir-mcp"): "
            + "a Screen Recording grant takes effect only after a restart."
        let dimensions = windowSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown size"
        guard let result else {
            return DoctorCheck(name: name, status: .failed, detail: "no frame captured",
                               fixHint: "Screen Recording is on but capture returned nothing: \(restart)")
        }
        if let failure = result.ocrFailure {
            return DoctorCheck(name: name, status: .failed,
                               detail: "capture ok \(dimensions), OCR failed: \(failure)",
                               fixHint: "Text recognition did not run. Run doctor again; if it still "
                                   + "fails, report it with `mirroir-mcp doctor --json`.")
        }
        if result.screenBlank {
            return DoctorCheck(name: name, status: .failed, detail: "blank frame \(dimensions)",
                               fixHint: "The captured frame is empty. If Screen Recording was just "
                                   + "turned on, \(restart) Otherwise wait for the iPhone screen to "
                                   + "draw and run doctor again.")
        }
        if result.elements.isEmpty {
            return DoctorCheck(name: name, status: .warned,
                               detail: "capture ok \(dimensions), OCR found no text",
                               fixHint: "Open an app with text on the iPhone and run doctor again.")
        }
        return DoctorCheck(name: name, status: .passed,
                           detail: "capture ok \(dimensions), OCR \(result.elements.count) boxes",
                           fixHint: nil)
    }
}
