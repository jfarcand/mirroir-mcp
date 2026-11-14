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
// ABOUTME: Proves the OCR engine can read known text, for check_health to report.
// ABOUTME: Renders a word into an image and asks the configured recognizer to read it back.

import CoreGraphics
import CoreText
import Foundation
import HelperLib

/// Checks that text recognition actually works, using an image whose contents
/// are known in advance.
///
/// The screen itself cannot answer this question: a blank screen and a broken
/// engine both produce zero elements, so a health check that reads the device
/// reports success either way. Recognising a word we drew ourselves separates
/// them — anything other than that word coming back means the engine is at
/// fault, not the screen.
enum TextRecognitionSelfTest {
    /// The word rendered and expected back. Uppercase and dictionary-free, so
    /// language correction cannot rewrite it into something else.
    static let probeText = "MIRROIR"

    /// Rendered large enough for `.accurate` recognition to be reliable.
    private static let imageSize = CGSize(width: 512, height: 160)
    private static let fontSize: CGFloat = 72

    /// Outcome of the probe, in the caller's words rather than an error type:
    /// `check_health` reports a line either way and never throws.
    enum Outcome: Sendable {
        case passed(milliseconds: Int)
        case failed(reason: String)
    }

    /// Render `probeText`, recognize it, and report whether it came back.
    static func run(using recognizer: any TextRecognizing) -> Outcome {
        guard let image = renderProbeImage() else {
            return .failed(reason: "could not render the probe image")
        }

        let start = DispatchTime.now()
        let elements: [RawTextElement]
        do {
            elements = try recognizer.recognizeText(
                in: image,
                windowSize: imageSize,
                contentBounds: CGRect(origin: .zero, size: imageSize)
            )
        } catch {
            return .failed(reason: String(describing: error))
        }
        let elapsed = Int(
            (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        let found = elements.contains { element in
            element.text.uppercased().contains(probeText)
        }
        guard found else {
            let sample = elements.prefix(3).map(\.text).joined(separator: ", ")
            return .failed(reason: elements.isEmpty
                ? "engine ran but read nothing from a known-text image"
                : "engine read \(elements.count) element(s) but not the probe: \(sample)")
        }
        return .passed(milliseconds: elapsed)
    }

    /// Draw `probeText` in black on white — maximum contrast, no dependency on
    /// whatever happens to be on the device's screen.
    private static func renderProbeImage() -> CGImage? {
        let width = Int(imageSize.width)
        let height = Int(imageSize.height)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: imageSize))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: probeText, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(
            x: (imageSize.width - bounds.width) / 2,
            y: (imageSize.height - bounds.height) / 2
        )
        CTLineDraw(line, context)

        return context.makeImage()
    }
}
