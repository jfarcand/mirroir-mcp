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
// ABOUTME: Merges results from multiple TextRecognizing backends into a single element list.
// ABOUTME: Decorator pattern — wraps N backends, concatenates their RawTextElement arrays.

import CoreGraphics
import Foundation
import HelperLib

/// Combines results from multiple `TextRecognizing` backends (e.g. Apple Vision OCR
/// and YOLO element detection) by running each and flat-mapping their outputs.
struct CompositeTextRecognizer: Sendable {
    private let backends: [any TextRecognizing]

    init(backends: [any TextRecognizing]) {
        self.backends = backends
    }

    /// Run every backend and merge their elements.
    ///
    /// A failing backend fails the whole call rather than quietly contributing
    /// nothing: a half-empty element list is indistinguishable from a screen
    /// that genuinely holds less text, which is how a broken engine hides.
    func recognizeText(
        in image: CGImage,
        windowSize: CGSize,
        contentBounds: CGRect
    ) throws -> [RawTextElement] {
        var elements: [RawTextElement] = []
        for backend in backends {
            do {
                elements += try backend.recognizeText(
                    in: image, windowSize: windowSize, contentBounds: contentBounds)
            } catch {
                throw TextRecognitionError.backendFailed(
                    name: String(describing: type(of: backend)), underlying: error)
            }
        }
        return elements
    }
}
