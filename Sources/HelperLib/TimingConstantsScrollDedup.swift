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
// ABOUTME: Defaults for deduplicating OCR elements collected across scroll viewports and measuring scroll offsets.
// ABOUTME: Split from TimingConstants.swift to stay under the 500-line limit.

/// How elements seen in more than one scroll viewport are merged, and how
/// the scroll offset between two viewports is measured.
extension TimingConstants {

    /// Default dedup strategy for scroll-collected OCR elements.
    /// Options: "exact", "levenshtein", "proximity".
    public static let scrollDedupStrategy: String = "exact"

    /// Maximum Levenshtein edit distance for fuzzy text dedup.
    public static let scrollDedupLevenshteinMax: Int = 3

    /// Maximum Euclidean distance in points for coordinate proximity dedup.
    public static let scrollDedupProximityPt: Double = 15.0

    /// Maximum X distance (pt) for matching elements across scroll viewports.
    public static let scrollContentMatchXTolerance: Double = 30.0

    /// Maximum Y distance (pt) for filtering outlier deltas during scroll offset measurement.
    public static let scrollContentMatchOutlierThreshold: Double = 20.0

    /// Minimum number of matching content elements required for content-based scroll offset.
    public static let scrollContentMatchMinCount: Int = 2

    /// X quantization bucket size (pt) for composite dedup key. Elements within one bucket
    /// at the same text are considered the same element.
    public static let scrollDedupXBucketSize: Double = 20.0

    /// Maximum absolute Y distance (pt) for two elements to be considered duplicates
    /// in page-absolute coordinate space.
    public static let scrollDedupPageYTolerance: Double = 30.0

    /// Minimum scroll offset (pt) to accept from anchor or content detection.
    /// Offsets below this threshold are treated as OCR jitter, not real scrolling.
    public static let scrollMinOffsetThreshold: Double = 20.0
}
