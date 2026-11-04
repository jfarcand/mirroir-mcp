// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Icon detection, tab-anchor synthesis and icon-cluster defaults for finding unlabeled controls.
// ABOUTME: Split from TimingConstants.swift to stay under the 500-line limit.

/// Thresholds for locating icons that OCR cannot read: zone sizes, saliency
/// and column-projection clustering, and evenly spaced tab-bar anchors.
extension TimingConstants {
    // MARK: - Icon Detection

    /// Points; skip detected icons within this distance of an OCR TapPoint.
    public static let iconOcrProximityFilter: Double = 20.0

    /// Minimum zone height in points to scan for icons.
    public static let iconMinZoneHeight: Double = 40.0

    /// Minimum zone height in points to attempt saliency fallback.
    public static let iconSaliencyMinZone: Double = 60.0

    /// Fraction of window height for the bottom zone (tab bar area).
    public static let iconBottomZoneFraction: Double = 0.08

    /// Fraction of window height for the top zone (nav bar area).
    public static let iconTopZoneFraction: Double = 0.12

    /// Maximum meaningful TapPoints in a zone for it to be considered "empty".
    public static let iconMaxZoneElements: Int = 1

    /// OCR results with text this short are likely icon shape misreads.
    public static let iconNoiseMaxLength: Int = 1

    /// Maximum icon dimension in points for saliency results.
    public static let iconMaxSaliencySize: Double = 60.0

    /// Minimum detected icons to attempt spacing interpolation.
    public static let iconMinForInterpolation: Int = 2

    /// Maximum gap deviation ratio for spacing to be considered "even".
    public static let iconSpacingTolerance: Double = 0.3

    /// Distance in points within which two icon detections are considered duplicates.
    public static let iconDeduplicationRadius: Double = 25.0

    // MARK: - Tab Anchor Synthesis

    /// Minimum detected elements in the tab-bar band required to treat the band
    /// as a tab bar and synthesize evenly-spaced anchor points. Baseline `1`: a
    /// single detected icon in the band is enough evidence of a tab bar; raise it
    /// to suppress phantom anchors on screens whose bottom band is not a tab bar.
    public static let tabSynthesisMinZoneEvidence: Int = 1

    // MARK: - Icon Cluster Detection

    /// Pixel-to-background RGB difference to count as foreground.
    public static let iconColorThreshold: UInt8 = 30

    /// Minimum foreground pixels in a column to count as part of an icon.
    public static let iconMinColumnDensity: Int = 1

    /// Minimum peak width in pixels to qualify as an icon.
    public static let iconMinClusterWidth: Int = 10

    /// Maximum peak width in pixels to qualify as an icon.
    public static let iconMaxClusterWidth: Int = 80

    /// Box filter window size for smoothing column projections.
    public static let iconSmoothingWindow: Int = 5

    /// Inset from window edges to avoid rounded corner pixels when sampling background.
    public static let iconCornerInsetPixels: Int = 40

    /// Minimum fraction of pixels in a row that must match background to qualify as a "bar row".
    public static let iconBarRowBgFraction: Double = 0.60
}
