// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Feature-specific EnvConfig properties (execution, icons, OCR, AI, exploration, app identity).
// ABOUTME: Split from EnvConfig.swift to stay under the 500-line limit.

import Foundation

extension EnvConfig {

    // MARK: - Step Execution

    public static var waitForTimeoutSeconds: Int {
        readInt("waitForTimeoutSeconds", default: TimingConstants.waitForTimeoutSeconds)
    }

    public static var stepSettlingDelayMs: UInt32 {
        readUInt32("stepSettlingDelayMs", default: TimingConstants.stepSettlingDelayMs)
    }

    public static var compiledSleepBufferMs: Int {
        readInt("compiledSleepBufferMs", default: TimingConstants.compiledSleepBufferMs)
    }

    public static var waitForPollIntervalUs: UInt32 {
        readUInt32("waitForPollIntervalUs", default: TimingConstants.waitForPollIntervalUs)
    }

    public static var measurePollIntervalUs: UInt32 {
        readUInt32("measurePollIntervalUs", default: TimingConstants.measurePollIntervalUs)
    }

    public static var settingsLoadUs: UInt32 {
        readUInt32("settingsLoadUs", default: TimingConstants.settingsLoadUs)
    }

    public static var appSwitcherCardOffset: Double {
        readDouble("appSwitcherCardOffset", default: TimingConstants.appSwitcherCardOffset)
    }

    public static var appSwitcherCardXFraction: Double {
        readDouble("appSwitcherCardXFraction", default: TimingConstants.appSwitcherCardXFraction)
    }

    public static var appSwitcherCardYFraction: Double {
        readDouble("appSwitcherCardYFraction", default: TimingConstants.appSwitcherCardYFraction)
    }

    public static var appSwitcherSwipeDistance: Double {
        readDouble("appSwitcherSwipeDistance", default: TimingConstants.appSwitcherSwipeDistance)
    }

    public static var appSwitcherSwipeDurationMs: Int {
        readInt("appSwitcherSwipeDurationMs", default: TimingConstants.appSwitcherSwipeDurationMs)
    }

    public static var appSwitcherMaxSwipes: Int {
        readInt("appSwitcherMaxSwipes", default: TimingConstants.appSwitcherMaxSwipes)
    }

    public static var toolSettlingDelayUs: UInt32 {
        readUInt32("toolSettlingDelayUs", default: TimingConstants.toolSettlingDelayUs)
    }

    // MARK: - Focus Recovery

    /// Y coordinate in window-relative points for the status bar engagement tap.
    /// After a macOS Space switch, a click at this position makes the window
    /// the key window so scroll events are accepted.
    public static var statusBarTapY: Double {
        readDouble("statusBarTapY", default: TimingConstants.statusBarTapY)
    }

    // MARK: - Swipe & Scroll Defaults

    public static var swipeDistanceFraction: Double {
        readDouble("swipeDistanceFraction", default: TimingConstants.swipeDistanceFraction)
    }

    /// Scroll-swipe start Y as a fraction of window height.
    public static var scrollSwipeFromYFraction: Double {
        readDouble("scrollSwipeFromYFraction", default: TimingConstants.scrollSwipeFromYFraction)
    }

    /// Scroll-swipe end Y as a fraction of window height.
    public static var scrollSwipeToYFraction: Double {
        readDouble("scrollSwipeToYFraction", default: TimingConstants.scrollSwipeToYFraction)
    }

    public static var defaultSwipeDurationMs: Int {
        readInt("defaultSwipeDurationMs", default: TimingConstants.defaultSwipeDurationMs)
    }

    public static var defaultScrollMaxAttempts: Int {
        readInt("defaultScrollMaxAttempts", default: TimingConstants.defaultScrollMaxAttempts)
    }

    /// Minimum anchor matches required for anchor-based scroll offset detection.
    public static var scrollAnchorMinCount: Int {
        readInt("scrollAnchorMinCount", default: TimingConstants.scrollAnchorMinCount)
    }

    // MARK: - AI Provider

    public static var openAITimeoutSeconds: Int {
        readInt("openAITimeoutSeconds", default: TimingConstants.openAITimeoutSeconds)
    }

    public static var ollamaTimeoutSeconds: Int {
        readInt("ollamaTimeoutSeconds", default: TimingConstants.ollamaTimeoutSeconds)
    }

    public static var anthropicTimeoutSeconds: Int {
        readInt("anthropicTimeoutSeconds", default: TimingConstants.anthropicTimeoutSeconds)
    }

    public static var embacleTimeoutSeconds: Int {
        readInt("embacleTimeoutSeconds", default: TimingConstants.embacleTimeoutSeconds)
    }

    public static var commandTimeoutSeconds: Int {
        readInt("commandTimeoutSeconds", default: TimingConstants.commandTimeoutSeconds)
    }

    public static var defaultAIMaxTokens: Int {
        readInt("defaultAIMaxTokens", default: TimingConstants.defaultAIMaxTokens)
    }

    // MARK: - Icon Detection

    public static var iconOcrProximityFilter: Double {
        readDouble("iconOcrProximityFilter", default: TimingConstants.iconOcrProximityFilter)
    }

    public static var iconMinZoneHeight: Double {
        readDouble("iconMinZoneHeight", default: TimingConstants.iconMinZoneHeight)
    }

    public static var iconSaliencyMinZone: Double {
        readDouble("iconSaliencyMinZone", default: TimingConstants.iconSaliencyMinZone)
    }

    public static var iconBottomZoneFraction: Double {
        readDouble("iconBottomZoneFraction", default: TimingConstants.iconBottomZoneFraction)
    }

    public static var iconTopZoneFraction: Double {
        readDouble("iconTopZoneFraction", default: TimingConstants.iconTopZoneFraction)
    }

    public static var iconMaxZoneElements: Int {
        readInt("iconMaxZoneElements", default: TimingConstants.iconMaxZoneElements)
    }

    public static var iconNoiseMaxLength: Int {
        readInt("iconNoiseMaxLength", default: TimingConstants.iconNoiseMaxLength)
    }

    public static var iconMaxSaliencySize: Double {
        readDouble("iconMaxSaliencySize", default: TimingConstants.iconMaxSaliencySize)
    }

    public static var iconMinForInterpolation: Int {
        readInt("iconMinForInterpolation", default: TimingConstants.iconMinForInterpolation)
    }

    public static var iconSpacingTolerance: Double {
        readDouble("iconSpacingTolerance", default: TimingConstants.iconSpacingTolerance)
    }

    public static var iconDeduplicationRadius: Double {
        readDouble("iconDeduplicationRadius", default: TimingConstants.iconDeduplicationRadius)
    }

    // MARK: - Icon Cluster Detection

    public static var iconColorThreshold: UInt8 {
        if let value = settings["iconColorThreshold"],
           let num = value as? Int, num >= 0, num <= 255 {
            return UInt8(num)
        }
        if let str = env[envVarName("iconColorThreshold")],
           let num = Int(str), num >= 0, num <= 255 {
            return UInt8(num)
        }
        return TimingConstants.iconColorThreshold
    }

    public static var iconMinColumnDensity: Int {
        readInt("iconMinColumnDensity", default: TimingConstants.iconMinColumnDensity)
    }

    public static var iconMinClusterWidth: Int {
        readInt("iconMinClusterWidth", default: TimingConstants.iconMinClusterWidth)
    }

    public static var iconMaxClusterWidth: Int {
        readInt("iconMaxClusterWidth", default: TimingConstants.iconMaxClusterWidth)
    }

    public static var iconSmoothingWindow: Int {
        readInt("iconSmoothingWindow", default: TimingConstants.iconSmoothingWindow)
    }

    public static var iconCornerInsetPixels: Int {
        readInt("iconCornerInsetPixels", default: TimingConstants.iconCornerInsetPixels)
    }

    public static var iconBarRowBgFraction: Double {
        readDouble("iconBarRowBgFraction", default: TimingConstants.iconBarRowBgFraction)
    }

    // MARK: - Input Tool Defaults

    public static var defaultDragDurationMs: Int {
        readInt("defaultDragDurationMs", default: TimingConstants.defaultDragDurationMs)
    }

    public static var defaultLongPressDurationMs: Int {
        readInt("defaultLongPressDurationMs", default: TimingConstants.defaultLongPressDurationMs)
    }

    public static var defaultMeasureTimeoutSeconds: Double {
        readDouble("defaultMeasureTimeoutSeconds", default: TimingConstants.defaultMeasureTimeoutSeconds)
    }

    // MARK: - OCR Configuration

    /// OCR recognition level: "accurate" or "fast".
    public static var ocrRecognitionLevel: String {
        readString("ocrRecognitionLevel", envVar: "MIRROIR_OCR_RECOGNITION_LEVEL",
                   default: TimingConstants.ocrRecognitionLevel)
    }

    /// Whether to enable language correction during OCR text recognition.
    public static var ocrLanguageCorrection: Bool {
        readBool("ocrLanguageCorrection", envVar: "MIRROIR_OCR_LANGUAGE_CORRECTION",
                 default: TimingConstants.ocrLanguageCorrection)
    }

    // MARK: - YOLO Element Detection

    /// OCR backend selection: "auto", "vision", "yolo", or "both".
    public static var ocrBackend: String {
        readString("ocrBackend", envVar: "MIRROIR_OCR_BACKEND",
                   default: TimingConstants.ocrBackend)
    }

    /// URL to download a YOLO .mlmodel or .mlmodelc from on first use.
    public static var yoloModelURL: String {
        readString("yoloModelURL", envVar: "MIRROIR_YOLO_MODEL_URL",
                   default: TimingConstants.yoloModelURL)
    }

    /// Local filesystem path to a pre-compiled .mlmodelc directory.
    public static var yoloModelPath: String {
        readString("yoloModelPath", envVar: "MIRROIR_YOLO_MODEL_PATH",
                   default: TimingConstants.yoloModelPath)
    }

    /// Minimum confidence threshold for YOLO element detections.
    public static var yoloConfidenceThreshold: Double {
        readDouble("yoloConfidenceThreshold", default: TimingConstants.yoloConfidenceThreshold)
    }

    // MARK: - Scroll Deduplication

    /// Dedup strategy for scroll-collected OCR elements.
    /// Options: "exact" (default), "levenshtein", "proximity".
    public static var scrollDedupStrategy: String {
        readString("scrollDedupStrategy", envVar: "MIRROIR_SCROLL_DEDUP_STRATEGY",
                   default: TimingConstants.scrollDedupStrategy)
    }

    /// Maximum Levenshtein edit distance for fuzzy text dedup.
    public static var scrollDedupLevenshteinMax: Int {
        readInt("scrollDedupLevenshteinMax", default: TimingConstants.scrollDedupLevenshteinMax)
    }

    /// Maximum Euclidean distance in points for coordinate proximity dedup.
    public static var scrollDedupProximityPt: Double {
        readDouble("scrollDedupProximityPt", default: TimingConstants.scrollDedupProximityPt)
    }

    // MARK: - Keyboard Layout

    /// iPhone keyboard layout name for character substitution.
    /// Empty string means US QWERTY (no substitution needed).
    /// Set via `mirroir-mcp configure` which saves to settings.json.
    public static var keyboardLayout: String {
        readString("keyboardLayout", envVar: "IPHONE_KEYBOARD_LAYOUT", default: "")
    }

    // MARK: - Exploration Budget

    public static var explorationMaxDepth: Int {
        readInt("explorationMaxDepth", default: TimingConstants.explorationMaxDepth)
    }

    public static var explorationMaxScreens: Int {
        readInt("explorationMaxScreens", default: TimingConstants.explorationMaxScreens)
    }

    public static var explorationMaxTimeSeconds: Int {
        readInt("explorationMaxTimeSeconds", default: TimingConstants.explorationMaxTimeSeconds)
    }

    // MARK: - Compiled Safety

    /// Minimum confidence threshold for compiled taps. Below this, fall back to live OCR.
    public static var compiledTapMinConfidence: Double {
        readDouble("compiledTapMinConfidence", default: TimingConstants.compiledTapMinConfidence)
    }

    /// When true, compiled taps are followed by a verification OCR call.
    public static var verifyTaps: Bool {
        readBool("verifyTaps", envVar: "MIRROIR_VERIFY_TAPS", default: false)
    }

    // MARK: - Calibration Validation

    /// When true, exploration fails if too many elements are unclassified after calibration.
    public static var calibrationStrict: Bool {
        readBool("calibrationStrict", envVar: "MIRROIR_CALIBRATION_STRICT", default: TimingConstants.calibrationStrict)
    }

    /// Maximum fraction of content-zone elements that can be unclassified (0.0–1.0).
    public static var calibrationUnclassifiedThreshold: Double {
        readDouble("calibrationUnclassifiedThreshold", default: TimingConstants.calibrationUnclassifiedThreshold)
    }

    // MARK: - Component Detection

    /// Component detection mode for BFS exploration.
    /// Controls how OCR elements are grouped into UI components.
    ///
    /// Values:
    /// - `heuristic`: Phase 1 only — component.md match rules, no LLM calls.
    /// - `llm_first_screen`: (DEFAULT) LLM classifies first screen, heuristics for rest.
    /// - `llm_every_screen`: LLM classifies every new screen.
    /// - `llm_fallback`: Heuristics first, LLM when no confident match.
    public static var componentDetection: String {
        readString("componentDetection", envVar: "MIRROIR_COMPONENT_DETECTION",
                   default: "llm_first_screen")
    }

    // MARK: - App Identity

    public static var mirroringBundleID: String {
        readString("mirroringBundleID", envVar: "MIRROIR_BUNDLE_ID",
                   default: "com.apple.ScreenContinuity")
    }

    public static var mirroringProcessName: String {
        readString("mirroringProcessName", envVar: "MIRROIR_PROCESS_NAME",
                   default: "iPhone Mirroring")
    }

    /// Post mouse events directly to the target PID via `postToPid` instead
    /// of global HID posting. Works for regular macOS apps (e.g. FakeMirroring)
    /// but NOT for iPhone Mirroring — per-process injection does not register
    /// taps; only global HID events (`event.post(tap: .cghidEventTap)`) work,
    /// and those inherently move the system cursor. Enables local integration
    /// tests without cursor interference.
    public static var cursorFreeInput: Bool {
        readBool("cursorFreeInput", envVar: "MIRROIR_CURSOR_FREE", default: false)
    }
}
