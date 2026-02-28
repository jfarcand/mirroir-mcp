// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
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

    func recognizeText(
        in image: CGImage,
        windowSize: CGSize,
        contentBounds: CGRect
    ) -> [RawTextElement] {
        backends.flatMap { backend in
            backend.recognizeText(in: image, windowSize: windowSize, contentBounds: contentBounds)
        }
    }
}
