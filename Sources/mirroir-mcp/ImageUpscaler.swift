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
// ABOUTME: Upscales small CGImages to a minimum width for improved OCR accuracy.
// ABOUTME: At small zoom modes the screenshot has too few pixels for Apple Vision to resolve all text.

import CoreGraphics
import HelperLib

/// Upscales screenshots that are below a minimum pixel width so Apple Vision's
/// text recognizer has enough resolution to detect all labels reliably.
enum ImageUpscaler {

    /// Upscale `image` to at least `minWidth` pixels wide, preserving aspect ratio.
    /// Returns the original image unchanged if it is already wide enough.
    static func upscaleIfNeeded(image: CGImage, minWidth: Int) -> CGImage {
        guard image.width < minWidth, image.width > 0, image.height > 0 else {
            return image
        }

        let aspectRatio = Double(image.height) / Double(image.width)
        let targetWidth = minWidth
        let targetHeight = Int(Double(targetWidth) * aspectRatio)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let upscaled = context.makeImage() else {
            return image
        }

        DebugLog.log("OCR", "Upscaled \(image.width)x\(image.height) -> \(targetWidth)x\(targetHeight) (minWidth=\(minWidth))")
        return upscaled
    }
}
