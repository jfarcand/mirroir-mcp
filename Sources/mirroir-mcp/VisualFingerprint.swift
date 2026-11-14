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
// ABOUTME: Perceptual hash (pHash) of screenshots for visual state identity.
// ABOUTME: Secondary fingerprint signal that catches visual-only state changes OCR misses.

import CoreGraphics
import Foundation
import ImageIO

/// Perceptual hashing for screenshot-based visual state comparison.
/// Uses a DCT-based approach: resize to 32x32 grayscale, compute DCT,
/// threshold the low-frequency 8x8 block — excluding the DC coefficient at
/// [0,0] — to produce a compact 63-bit hash.
/// Two hashes can be compared via Hamming distance for visual similarity.
enum VisualFingerprint {

    /// Hamming distance threshold below which two hashes are considered visually similar.
    static let similarityThreshold: Int = 10

    /// Side length of the intermediate grayscale image for DCT computation.
    private static let resizeSize: Int = 32

    /// Side length of the low-frequency DCT block used to derive the hash.
    private static let hashBlockSize: Int = 8

    // MARK: - Public API

    /// Compute a perceptual hash from a base64-encoded screenshot.
    /// Returns 0 if the image cannot be decoded or processed.
    static func compute(screenshotBase64: String) -> UInt64 {
        guard let imageData = Data(base64Encoded: screenshotBase64),
              let cgImage = createCGImage(from: imageData) else {
            return 0
        }
        return computeFromCGImage(cgImage)
    }

    /// Compute the Hamming distance between two perceptual hashes.
    /// Returns the number of bit positions where the hashes differ (0-64).
    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    // MARK: - Core Algorithm

    /// Compute perceptual hash from a CGImage.
    static func computeFromCGImage(_ cgImage: CGImage) -> UInt64 {
        let pixels = resizeToGrayscale(cgImage)
        guard pixels.count == resizeSize * resizeSize else { return 0 }

        let dctCoeffs = computeDCT2D(pixels: pixels, size: resizeSize)

        // Extract the top-left 8x8 low-frequency coefficients (excluding DC at [0,0])
        var coefficients: [Double] = []
        for v in 0..<hashBlockSize {
            for u in 0..<hashBlockSize {
                if u == 0 && v == 0 { continue }  // Skip DC component
                coefficients.append(dctCoeffs[v * resizeSize + u])
            }
        }

        // Compute median
        let sorted = coefficients.sorted()
        let median: Double
        if sorted.isEmpty {
            return 0
        } else if sorted.count % 2 == 0 {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
        } else {
            median = sorted[sorted.count / 2]
        }

        // Build hash: each coefficient above median = 1, below = 0
        var hash: UInt64 = 0
        for (i, coeff) in coefficients.enumerated() {
            if i >= 64 { break }
            if coeff > median {
                hash |= (1 << i)
            }
        }

        return hash
    }

    // MARK: - Image Processing

    /// Resize a CGImage to 32x32 grayscale and return pixel intensities as [0.0, 255.0].
    private static func resizeToGrayscale(_ image: CGImage) -> [Double] {
        let size = resizeSize
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let data = context.data else { return [] }
        let buffer = data.bindMemory(to: UInt8.self, capacity: size * size)

        var pixels: [Double] = []
        pixels.reserveCapacity(size * size)
        for i in 0..<(size * size) {
            pixels.append(Double(buffer[i]))
        }

        return pixels
    }

    /// Create a CGImage from raw image data (PNG or JPEG).
    private static func createCGImage(from data: Data) -> CGImage? {
        guard let dataProvider = CGDataProvider(data: data as CFData),
              let source = CGImageSourceCreateWithDataProvider(dataProvider, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - DCT Computation

    /// Compute 2D DCT-II on a square pixel grid.
    /// DCT(u,v) = C(u)*C(v) * sum_x sum_y pixel(x,y) * cos(pi*(2x+1)*u/(2*N)) * cos(pi*(2y+1)*v/(2*N))
    /// where C(0) = 1/sqrt(N), C(k) = sqrt(2/N) for k > 0.
    private static func computeDCT2D(pixels: [Double], size: Int) -> [Double] {
        let n = Double(size)

        // Precompute cosine table for efficiency
        // cos(pi * (2*x + 1) * u / (2*N)) for all x, u in [0, size)
        var cosTable = [Double](repeating: 0, count: size * size)
        for x in 0..<size {
            for u in 0..<size {
                cosTable[x * size + u] = cos(
                    Double.pi * Double(2 * x + 1) * Double(u) / (2.0 * n)
                )
            }
        }

        // Only compute the top-left hashBlockSize x hashBlockSize coefficients
        // (we don't need the full DCT matrix, just the low frequencies)
        var result = [Double](repeating: 0, count: size * size)
        let blockSize = hashBlockSize

        for v in 0..<blockSize {
            let cv = v == 0 ? 1.0 / sqrt(n) : sqrt(2.0 / n)
            for u in 0..<blockSize {
                let cu = u == 0 ? 1.0 / sqrt(n) : sqrt(2.0 / n)
                var sum = 0.0
                for y in 0..<size {
                    let cosVY = cosTable[y * size + v]
                    for x in 0..<size {
                        sum += pixels[y * size + x] * cosTable[x * size + u] * cosVY
                    }
                }
                result[v * size + u] = cu * cv * sum
            }
        }

        return result
    }
}
