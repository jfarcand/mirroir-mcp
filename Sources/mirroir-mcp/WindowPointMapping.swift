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
// ABOUTME: Maps a Vision normalized bounding box on a captured frame to window points.
// ABOUTME: Shared by OCR and the icon detector, so text and icons land in the same place.

import CoreGraphics
import Foundation
import HelperLib

/// The transform from a Vision bounding box (normalized, origin bottom-left) on a
/// captured frame to window points (origin top-left).
struct WindowPointMapping {
    let windowWidth: Double
    let windowHeight: Double
    /// The frame's height in points. It may exceed the window's when the capture
    /// includes chrome (rounded corners, home indicator) past the AX-reported size.
    let imagePointHeight: Double
    let xScale: Double
    let yScale: Double
    /// True when the content sits inside dark borders on both axes (Larger display mode).
    let bordersDetected: Bool

    init(imageWidth: Int, imageHeight: Int, windowSize: CGSize, contentBounds: CGRect) {
        windowWidth = Double(windowSize.width)
        windowHeight = Double(windowSize.height)

        // The display backing scale is uniform (same for X and Y on macOS).
        // Derive it from the X dimension, which is reliable — screencapture
        // does not add extra horizontal content beyond the window bounds.
        let backingScale = Double(imageWidth) / max(windowWidth, 1.0)
        imagePointHeight = Double(imageHeight) / max(backingScale, .ulpOfOne)

        // Content-to-window scaling: only applied when ContentBoundsDetector
        // found SIGNIFICANT dark borders (Larger display mode). Small
        // differences (< 5% per axis) are ignored — they come from the
        // phone's rounded corners and home indicator, not from display mode
        // borders. In Larger mode the content is typically 10-20% smaller.
        // A dark app narrows the bounds on one axis only, and must not be scaled.
        let widthMargin = Double(imageWidth) * 0.05
        let heightMargin = Double(imageHeight) * 0.05
        bordersDetected = Double(contentBounds.width) < Double(imageWidth) - widthMargin
            && Double(contentBounds.height) < Double(imageHeight) - heightMargin

        if bordersDetected {
            let contentWidth = Double(contentBounds.width) / backingScale
            let contentHeight = Double(contentBounds.height) / backingScale
            xScale = windowWidth / max(contentWidth, 1.0)
            yScale = windowHeight / max(contentHeight, 1.0)
        } else {
            xScale = 1.0
            yScale = 1.0
        }
    }

    func element(text: String, bbox: CGRect, confidence: Float) -> RawTextElement {
        RawTextElement(
            text: text,
            tapX: (bbox.midX * windowWidth) * xScale,
            textTopY: ((1.0 - bbox.maxY) * imagePointHeight) * yScale,
            textBottomY: ((1.0 - bbox.minY) * imagePointHeight) * yScale,
            bboxWidth: bbox.width * windowWidth * xScale,
            confidence: confidence
        )
    }

    /// Whether the element's tap point falls inside the window.
    func contains(_ element: RawTextElement) -> Bool {
        let midY = (element.textTopY + element.textBottomY) / 2
        return element.tapX >= 0 && element.tapX < windowWidth && midY >= 0 && midY < windowHeight
    }
}
