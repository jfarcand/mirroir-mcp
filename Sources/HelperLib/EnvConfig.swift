// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: JSON-based configuration overrides for timing and numeric constants.
// ABOUTME: Reads settings.json first, then MIRROIR_* env vars, falling back to TimingConstants.

import Foundation

/// Reads timing and numeric constants from a `settings.json` config file, falling back
/// to `MIRROIR_*` environment variables, then to ``TimingConstants`` defaults.
///
/// Resolution order for each key (first found wins):
/// 1. `settings.json` value (project-local `<cwd>/.mirroir-mcp/settings.json`,
///    then global `~/.mirroir-mcp/settings.json`)
/// 2. `MIRROIR_<SCREAMING_SNAKE_CASE>` environment variable
/// 3. ``TimingConstants`` default
///
/// Example `settings.json`:
/// ```json
/// {
///   "cursorSettleUs": 20000,
///   "clickHoldUs": 100000,
///   "mirroringBundleID": "com.apple.ScreenContinuity"
/// }
/// ```
public enum EnvConfig {
    /// Loaded settings dictionary. Lazily initialized once from settings.json.
    nonisolated(unsafe) private static let settings: [String: Any] = loadSettings()

    // MARK: - Cursor & Input Settling

    public static var cursorSettleUs: UInt32 {
        readUInt32("cursorSettleUs", default: TimingConstants.cursorSettleUs)
    }

    public static var clickHoldUs: UInt32 {
        readUInt32("clickHoldUs", default: TimingConstants.clickHoldUs)
    }

    public static var doubleTapHoldUs: UInt32 {
        readUInt32("doubleTapHoldUs", default: TimingConstants.doubleTapHoldUs)
    }

    public static var doubleTapGapUs: UInt32 {
        readUInt32("doubleTapGapUs", default: TimingConstants.doubleTapGapUs)
    }

    public static var dragModeHoldUs: UInt32 {
        readUInt32("dragModeHoldUs", default: TimingConstants.dragModeHoldUs)
    }

    public static var focusSettleUs: UInt32 {
        readUInt32("focusSettleUs", default: TimingConstants.focusSettleUs)
    }

    public static var keystrokeDelayUs: UInt32 {
        readUInt32("keystrokeDelayUs", default: TimingConstants.keystrokeDelayUs)
    }

    // MARK: - App Switching & Navigation

    public static var spaceSwitchSettleUs: UInt32 {
        readUInt32("spaceSwitchSettleUs", default: TimingConstants.spaceSwitchSettleUs)
    }

    public static var spotlightAppearanceUs: UInt32 {
        readUInt32("spotlightAppearanceUs", default: TimingConstants.spotlightAppearanceUs)
    }

    public static var searchResultsPopulateUs: UInt32 {
        readUInt32("searchResultsPopulateUs", default: TimingConstants.searchResultsPopulateUs)
    }

    public static var safariLoadUs: UInt32 {
        readUInt32("safariLoadUs", default: TimingConstants.safariLoadUs)
    }

    public static var addressBarActivateUs: UInt32 {
        readUInt32("addressBarActivateUs", default: TimingConstants.addressBarActivateUs)
    }

    public static var preReturnUs: UInt32 {
        readUInt32("preReturnUs", default: TimingConstants.preReturnUs)
    }

    // MARK: - Process & System Polling

    public static var processPollUs: UInt32 {
        readUInt32("processPollUs", default: TimingConstants.processPollUs)
    }

    public static var earlyFailureDetectUs: UInt32 {
        readUInt32("earlyFailureDetectUs", default: TimingConstants.earlyFailureDetectUs)
    }

    public static var resumeFromPausedUs: UInt32 {
        readUInt32("resumeFromPausedUs", default: TimingConstants.resumeFromPausedUs)
    }

    public static var postHeartbeatSettleUs: UInt32 {
        readUInt32("postHeartbeatSettleUs", default: TimingConstants.postHeartbeatSettleUs)
    }

    // MARK: - CGEvent Keyboard

    public static var deadKeyDelayUs: UInt32 {
        readUInt32("deadKeyDelayUs", default: TimingConstants.deadKeyDelayUs)
    }

    // MARK: - Non-Timing Constants

    public static var dragInterpolationSteps: Int {
        readInt("dragInterpolationSteps", default: TimingConstants.dragInterpolationSteps)
    }

    public static var swipeInterpolationSteps: Int {
        readInt("swipeInterpolationSteps", default: TimingConstants.swipeInterpolationSteps)
    }

    public static var scrollPixelScale: Double {
        readDouble("scrollPixelScale", default: TimingConstants.scrollPixelScale)
    }

    // MARK: - Content Bounds Detection

    public static var brightnessThreshold: UInt8 {
        if let value = settings["brightnessThreshold"],
           let num = value as? Int, num >= 0, num <= 255 {
            return UInt8(num)
        }
        if let str = env[envVarName("brightnessThreshold")],
           let num = Int(str), num >= 0, num <= 255 {
            return UInt8(num)
        }
        return TimingConstants.brightnessThreshold
    }

    // MARK: - Tap Point Calculation

    public static var tapMaxLabelLength: Int {
        readInt("tapMaxLabelLength", default: TimingConstants.tapMaxLabelLength)
    }

    public static var tapMaxLabelWidthFraction: Double {
        readDouble("tapMaxLabelWidthFraction", default: TimingConstants.tapMaxLabelWidthFraction)
    }

    public static var tapMinGapForOffset: Double {
        readDouble("tapMinGapForOffset", default: TimingConstants.tapMinGapForOffset)
    }

    public static var tapIconRowMinLabels: Int {
        readInt("tapIconRowMinLabels", default: TimingConstants.tapIconRowMinLabels)
    }

    public static var tapIconOffset: Double {
        readDouble("tapIconOffset", default: TimingConstants.tapIconOffset)
    }

    public static var tapRowTolerance: Double {
        readDouble("tapRowTolerance", default: TimingConstants.tapRowTolerance)
    }

    public static var tapBottomZoneFraction: Double {
        readDouble("tapBottomZoneFraction", default: TimingConstants.tapBottomZoneFraction)
    }

    // MARK: - Grid Overlay

    public static var gridSpacing: Double {
        readDouble("gridSpacing", default: TimingConstants.gridSpacing)
    }

    public static var gridLineAlpha: Double {
        readDouble("gridLineAlpha", default: TimingConstants.gridLineAlpha)
    }

    public static var gridLabelFontSize: Double {
        readDouble("gridLabelFontSize", default: TimingConstants.gridLabelFontSize)
    }

    public static var gridLabelEveryN: Int {
        readInt("gridLabelEveryN", default: TimingConstants.gridLabelEveryN)
    }

    // MARK: - Event Classification

    public static var eventTapDistanceThreshold: Double {
        readDouble("eventTapDistanceThreshold", default: TimingConstants.eventTapDistanceThreshold)
    }

    public static var eventSwipeDistanceThreshold: Double {
        readDouble("eventSwipeDistanceThreshold", default: TimingConstants.eventSwipeDistanceThreshold)
    }

    public static var eventLongPressThreshold: Double {
        readDouble("eventLongPressThreshold", default: TimingConstants.eventLongPressThreshold)
    }

    public static var eventLabelMaxDistance: Double {
        readDouble("eventLabelMaxDistance", default: TimingConstants.eventLabelMaxDistance)
    }

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

    // MARK: - Swipe & Scroll Defaults

    public static var swipeDistanceFraction: Double {
        readDouble("swipeDistanceFraction", default: TimingConstants.swipeDistanceFraction)
    }

    public static var defaultSwipeDurationMs: Int {
        readInt("defaultSwipeDurationMs", default: TimingConstants.defaultSwipeDurationMs)
    }

    public static var defaultScrollMaxAttempts: Int {
        readInt("defaultScrollMaxAttempts", default: TimingConstants.defaultScrollMaxAttempts)
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

    // MARK: - Config Dump

    /// Returns a formatted two-column dump of all effective configuration values,
    /// grouped by section. Suitable for startup logging.
    public static func formattedConfigDump() -> String {
        let sections: [(String, [(String, String)])] = [
            ("Cursor & Input", [
                ("cursorSettleUs", "\(cursorSettleUs)"),
                ("clickHoldUs", "\(clickHoldUs)"),
                ("doubleTapHoldUs", "\(doubleTapHoldUs)"),
                ("doubleTapGapUs", "\(doubleTapGapUs)"),
                ("dragModeHoldUs", "\(dragModeHoldUs)"),
                ("focusSettleUs", "\(focusSettleUs)"),
                ("keystrokeDelayUs", "\(keystrokeDelayUs)"),
            ]),
            ("App Switching", [
                ("spaceSwitchSettleUs", "\(spaceSwitchSettleUs)"),
                ("spotlightAppearanceUs", "\(spotlightAppearanceUs)"),
                ("searchResultsPopulateUs", "\(searchResultsPopulateUs)"),
                ("safariLoadUs", "\(safariLoadUs)"),
                ("addressBarActivateUs", "\(addressBarActivateUs)"),
                ("preReturnUs", "\(preReturnUs)"),
            ]),
            ("Process & Polling", [
                ("processPollUs", "\(processPollUs)"),
                ("earlyFailureDetectUs", "\(earlyFailureDetectUs)"),
                ("resumeFromPausedUs", "\(resumeFromPausedUs)"),
                ("postHeartbeatSettleUs", "\(postHeartbeatSettleUs)"),
            ]),
            ("Keyboard", [
                ("deadKeyDelayUs", "\(deadKeyDelayUs)"),
                ("keyboardLayout", "\(keyboardLayout.isEmpty ? "(none)" : keyboardLayout)"),
            ]),
            ("Drag & Swipe", [
                ("dragInterpolationSteps", "\(dragInterpolationSteps)"),
                ("swipeInterpolationSteps", "\(swipeInterpolationSteps)"),
                ("scrollPixelScale", "\(scrollPixelScale)"),
                ("swipeDistanceFraction", "\(swipeDistanceFraction)"),
                ("defaultSwipeDurationMs", "\(defaultSwipeDurationMs)"),
                ("defaultDragDurationMs", "\(defaultDragDurationMs)"),
                ("defaultLongPressDurationMs", "\(defaultLongPressDurationMs)"),
                ("defaultScrollMaxAttempts", "\(defaultScrollMaxAttempts)"),
            ]),
            ("OCR", [
                ("ocrBackend", ocrBackend),
                ("ocrRecognitionLevel", ocrRecognitionLevel),
                ("ocrLanguageCorrection", "\(ocrLanguageCorrection)"),
            ]),
            ("YOLO", [
                ("yoloModelURL", yoloModelURL.isEmpty ? "(none)" : yoloModelURL),
                ("yoloModelPath", yoloModelPath.isEmpty ? "(none)" : yoloModelPath),
                ("yoloConfidenceThreshold", "\(yoloConfidenceThreshold)"),
            ]),
            ("Scroll Dedup", [
                ("scrollDedupStrategy", scrollDedupStrategy),
                ("scrollDedupLevenshteinMax", "\(scrollDedupLevenshteinMax)"),
                ("scrollDedupProximityPt", "\(scrollDedupProximityPt)"),
            ]),
            ("Content Bounds", [
                ("brightnessThreshold", "\(brightnessThreshold)"),
            ]),
            ("Tap Point", [
                ("tapMaxLabelLength", "\(tapMaxLabelLength)"),
                ("tapMaxLabelWidthFraction", "\(tapMaxLabelWidthFraction)"),
                ("tapMinGapForOffset", "\(tapMinGapForOffset)"),
                ("tapIconRowMinLabels", "\(tapIconRowMinLabels)"),
                ("tapIconOffset", "\(tapIconOffset)"),
                ("tapRowTolerance", "\(tapRowTolerance)"),
                ("tapBottomZoneFraction", "\(tapBottomZoneFraction)"),
            ]),
            ("Safe Area", [
                ("safeBottomMarginPt", "\(TimingConstants.safeBottomMarginPt)"),
            ]),
            ("Grid Overlay", [
                ("gridSpacing", "\(gridSpacing)"),
                ("gridLineAlpha", "\(gridLineAlpha)"),
                ("gridLabelFontSize", "\(gridLabelFontSize)"),
                ("gridLabelEveryN", "\(gridLabelEveryN)"),
            ]),
            ("Event Classification", [
                ("eventTapDistanceThreshold", "\(eventTapDistanceThreshold)"),
                ("eventSwipeDistanceThreshold", "\(eventSwipeDistanceThreshold)"),
                ("eventLongPressThreshold", "\(eventLongPressThreshold)"),
                ("eventLabelMaxDistance", "\(eventLabelMaxDistance)"),
            ]),
            ("Step Execution", [
                ("waitForTimeoutSeconds", "\(waitForTimeoutSeconds)"),
                ("stepSettlingDelayMs", "\(stepSettlingDelayMs)"),
                ("compiledSleepBufferMs", "\(compiledSleepBufferMs)"),
                ("waitForPollIntervalUs", "\(waitForPollIntervalUs)"),
                ("measurePollIntervalUs", "\(measurePollIntervalUs)"),
                ("defaultMeasureTimeoutSeconds", "\(defaultMeasureTimeoutSeconds)"),
                ("settingsLoadUs", "\(settingsLoadUs)"),
            ]),
            ("App Switcher", [
                ("appSwitcherCardOffset", "\(appSwitcherCardOffset)"),
                ("appSwitcherCardXFraction", "\(appSwitcherCardXFraction)"),
                ("appSwitcherCardYFraction", "\(appSwitcherCardYFraction)"),
                ("appSwitcherSwipeDistance", "\(appSwitcherSwipeDistance)"),
                ("appSwitcherSwipeDurationMs", "\(appSwitcherSwipeDurationMs)"),
                ("appSwitcherMaxSwipes", "\(appSwitcherMaxSwipes)"),
                ("toolSettlingDelayUs", "\(toolSettlingDelayUs)"),
            ]),
            ("Icon Detection", [
                ("iconOcrProximityFilter", "\(iconOcrProximityFilter)"),
                ("iconMinZoneHeight", "\(iconMinZoneHeight)"),
                ("iconSaliencyMinZone", "\(iconSaliencyMinZone)"),
                ("iconBottomZoneFraction", "\(iconBottomZoneFraction)"),
                ("iconTopZoneFraction", "\(iconTopZoneFraction)"),
                ("iconMaxZoneElements", "\(iconMaxZoneElements)"),
                ("iconNoiseMaxLength", "\(iconNoiseMaxLength)"),
                ("iconMaxSaliencySize", "\(iconMaxSaliencySize)"),
                ("iconMinForInterpolation", "\(iconMinForInterpolation)"),
                ("iconSpacingTolerance", "\(iconSpacingTolerance)"),
                ("iconDeduplicationRadius", "\(iconDeduplicationRadius)"),
            ]),
            ("Icon Clusters", [
                ("iconColorThreshold", "\(iconColorThreshold)"),
                ("iconMinColumnDensity", "\(iconMinColumnDensity)"),
                ("iconMinClusterWidth", "\(iconMinClusterWidth)"),
                ("iconMaxClusterWidth", "\(iconMaxClusterWidth)"),
                ("iconSmoothingWindow", "\(iconSmoothingWindow)"),
                ("iconCornerInsetPixels", "\(iconCornerInsetPixels)"),
                ("iconBarRowBgFraction", "\(iconBarRowBgFraction)"),
            ]),
            ("AI Provider", [
                ("openAITimeoutSeconds", "\(openAITimeoutSeconds)"),
                ("ollamaTimeoutSeconds", "\(ollamaTimeoutSeconds)"),
                ("anthropicTimeoutSeconds", "\(anthropicTimeoutSeconds)"),
                ("commandTimeoutSeconds", "\(commandTimeoutSeconds)"),
                ("defaultAIMaxTokens", "\(defaultAIMaxTokens)"),
            ]),
            ("Component Detection", [
                ("componentDetection", componentDetection),
            ]),
            ("App Identity", [
                ("mirroringBundleID", mirroringBundleID),
                ("mirroringProcessName", mirroringProcessName),
            ]),
        ]

        var lines = [String]()
        let keyWidth = 30
        let columnWidth = 60

        for (section, entries) in sections {
            lines.append("  [\(section)]")
            // Lay out entries in two columns
            var i = 0
            while i < entries.count {
                let (k1, v1) = entries[i]
                let left = "    \(k1.padding(toLength: keyWidth, withPad: " ", startingAt: 0)) \(v1)"
                if i + 1 < entries.count {
                    let (k2, v2) = entries[i + 1]
                    // Pad with spaces; never truncate long values
                    let gap = max(columnWidth - left.count, 2)
                    let padding = String(repeating: " ", count: gap)
                    lines.append("\(left)\(padding)\(k2.padding(toLength: keyWidth, withPad: " ", startingAt: 0)) \(v2)")
                    i += 2
                } else {
                    lines.append(left)
                    i += 1
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Settings File Loading

    /// Load settings from the first available settings.json file.
    /// Resolution order: project-local → global → empty dictionary.
    private static func loadSettings() -> [String: Any] {
        let configDirName = ".mirroir-mcp"
        let fileName = "settings.json"

        let localPath = FileManager.default.currentDirectoryPath + "/" + configDirName + "/" + fileName
        let globalPath = ("~/" + configDirName + "/" + fileName as NSString).expandingTildeInPath

        let path: String
        if FileManager.default.fileExists(atPath: localPath) {
            path = localPath
        } else if FileManager.default.fileExists(atPath: globalPath) {
            path = globalPath
        } else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fputs("Warning: settings.json at \(path) is not a JSON object\n", stderr)
                return [:]
            }
            return json
        } catch {
            fputs("Warning: Failed to parse settings.json at \(path): \(error.localizedDescription)\n", stderr)
            return [:]
        }
    }

    // MARK: - Private Helpers

    private static let env = ProcessInfo.processInfo.environment

    /// Convert camelCase key to MIRROIR_SCREAMING_SNAKE_CASE for env var lookup.
    private static func envVarName(_ key: String) -> String {
        var result = "MIRROIR_"
        for char in key {
            if char.isUppercase {
                result += "_"
            }
            result += String(char).uppercased()
        }
        return result
    }

    private static func readString(_ key: String, envVar: String? = nil,
                                    default fallback: String) -> String {
        if let val = settings[key] as? String { return val }
        if let val = env[envVar ?? envVarName(key)] { return val }
        return fallback
    }

    private static func readUInt32(_ key: String, default fallback: UInt32) -> UInt32 {
        if let value = settings[key] {
            if let intVal = value as? Int, intVal >= 0 { return UInt32(intVal) }
            if let doubleVal = value as? Double, doubleVal >= 0 { return UInt32(doubleVal) }
        }
        if let str = env[envVarName(key)], let parsed = UInt32(str) { return parsed }
        return fallback
    }

    private static func readInt(_ key: String, default fallback: Int) -> Int {
        if let value = settings[key] {
            if let intVal = value as? Int { return intVal }
            if let doubleVal = value as? Double { return Int(doubleVal) }
        }
        if let str = env[envVarName(key)], let parsed = Int(str) { return parsed }
        return fallback
    }

    private static func readBool(_ key: String, envVar: String? = nil,
                                   default fallback: Bool) -> Bool {
        if let value = settings[key] as? Bool { return value }
        // JSON numbers: 0 = false, non-zero = true
        if let value = settings[key] as? Int { return value != 0 }
        if let str = env[envVar ?? envVarName(key)] {
            return ["true", "1", "yes"].contains(str.lowercased())
        }
        return fallback
    }

    private static func readDouble(_ key: String, default fallback: Double) -> Double {
        if let value = settings[key] {
            if let doubleVal = value as? Double { return doubleVal }
            if let intVal = value as? Int { return Double(intVal) }
        }
        if let str = env[envVarName(key)], let parsed = Double(str) { return parsed }
        return fallback
    }
}
