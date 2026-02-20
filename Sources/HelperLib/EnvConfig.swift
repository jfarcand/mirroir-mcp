// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: JSON-based configuration overrides for timing and numeric constants.
// ABOUTME: Reads settings.json from config directories, falling back to TimingConstants defaults.

import Foundation

/// Reads timing and numeric constants from a `settings.json` config file, falling back
/// to ``TimingConstants`` defaults when not set.
///
/// Config file resolution order (first found wins):
/// 1. `<cwd>/.iphone-mirroir-mcp/settings.json` (project-local)
/// 2. `~/.iphone-mirroir-mcp/settings.json` (global)
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

    public static var nudgeSettleUs: UInt32 {
        readUInt32("nudgeSettleUs", default: TimingConstants.nudgeSettleUs)
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

    // MARK: - Karabiner HID

    public static var keyHoldUs: UInt32 {
        readUInt32("keyHoldUs", default: TimingConstants.keyHoldUs)
    }

    public static var deadKeyDelayUs: UInt32 {
        readUInt32("deadKeyDelayUs", default: TimingConstants.deadKeyDelayUs)
    }

    public static var recvTimeoutUs: Int32 {
        readInt32("recvTimeoutUs", default: TimingConstants.recvTimeoutUs)
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

    public static var hidTypingChunkSize: Int {
        readInt("hidTypingChunkSize", default: TimingConstants.hidTypingChunkSize)
    }

    public static var staffGroupID: UInt32 {
        readUInt32("staffGroupID", default: TimingConstants.staffGroupID)
    }

    // MARK: - Vision & Interactive Region Detection

    public static var regionMinSizePt: Double {
        readDouble("regionMinSizePt", default: TimingConstants.regionMinSizePt)
    }

    public static var regionMaxSizePt: Double {
        readDouble("regionMaxSizePt", default: TimingConstants.regionMaxSizePt)
    }

    public static var ocrOverlapThresholdPt: Double {
        readDouble("ocrOverlapThresholdPt", default: TimingConstants.ocrOverlapThresholdPt)
    }

    public static var regionEdgeMarginPt: Double {
        readDouble("regionEdgeMarginPt", default: TimingConstants.regionEdgeMarginPt)
    }

    public static var regionMaxCount: Int {
        readInt("regionMaxCount", default: TimingConstants.regionMaxCount)
    }

    public static var visionMinimumSize: Double {
        readDouble("visionMinimumSize", default: TimingConstants.visionMinimumSize)
    }

    public static var visionMaximumObservations: Int {
        readInt("visionMaximumObservations", default: TimingConstants.visionMaximumObservations)
    }

    public static var visionMinimumAspectRatio: Double {
        readDouble("visionMinimumAspectRatio", default: TimingConstants.visionMinimumAspectRatio)
    }

    public static var visionMaximumAspectRatio: Double {
        readDouble("visionMaximumAspectRatio", default: TimingConstants.visionMaximumAspectRatio)
    }

    public static var visionMinimumConfidence: Double {
        readDouble("visionMinimumConfidence", default: TimingConstants.visionMinimumConfidence)
    }

    public static var visionQuadratureTolerance: Double {
        readDouble("visionQuadratureTolerance", default: TimingConstants.visionQuadratureTolerance)
    }

    // MARK: - Content Bounds Detection

    public static var brightnessThreshold: UInt8 {
        guard let value = settings["brightnessThreshold"],
              let num = value as? Int, num >= 0, num <= 255 else {
            return TimingConstants.brightnessThreshold
        }
        return UInt8(num)
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

    // MARK: - Karabiner Protocol

    public static var karabinerHeartbeatDeadlineMs: UInt32 {
        readUInt32("karabinerHeartbeatDeadlineMs", default: TimingConstants.karabinerHeartbeatDeadlineMs)
    }

    public static var karabinerHeartbeatIntervalSec: Double {
        readDouble("karabinerHeartbeatIntervalSec", default: TimingConstants.karabinerHeartbeatIntervalSec)
    }

    public static var karabinerServerCheckIntervalSec: Double {
        readDouble("karabinerServerCheckIntervalSec", default: TimingConstants.karabinerServerCheckIntervalSec)
    }

    public static var karabinerDeviceReadyTimeoutSec: Double {
        readDouble("karabinerDeviceReadyTimeoutSec", default: TimingConstants.karabinerDeviceReadyTimeoutSec)
    }

    public static var karabinerSocketBufferSize: Int {
        readInt("karabinerSocketBufferSize", default: TimingConstants.karabinerSocketBufferSize)
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

    public static var appSwitcherSwipeDistance: Double {
        readDouble("appSwitcherSwipeDistance", default: TimingConstants.appSwitcherSwipeDistance)
    }

    public static var appSwitcherSwipeDurationMs: Int {
        readInt("appSwitcherSwipeDurationMs", default: TimingConstants.appSwitcherSwipeDurationMs)
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

    // MARK: - App Identity

    public static var mirroringBundleID: String {
        readString("mirroringBundleID", default: "com.apple.ScreenContinuity")
    }

    public static var mirroringProcessName: String {
        readString("mirroringProcessName", default: "iPhone Mirroring")
    }

    // MARK: - Settings File Loading

    /// Load settings from the first available settings.json file.
    /// Resolution order: project-local → global → empty dictionary.
    private static func loadSettings() -> [String: Any] {
        let configDirName = ".iphone-mirroir-mcp"
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

    private static func readString(_ key: String, default fallback: String) -> String {
        (settings[key] as? String) ?? fallback
    }

    private static func readUInt32(_ key: String, default fallback: UInt32) -> UInt32 {
        guard let value = settings[key] else { return fallback }
        if let intVal = value as? Int, intVal >= 0 { return UInt32(intVal) }
        if let doubleVal = value as? Double, doubleVal >= 0 { return UInt32(doubleVal) }
        return fallback
    }

    private static func readInt32(_ key: String, default fallback: Int32) -> Int32 {
        guard let value = settings[key] else { return fallback }
        if let intVal = value as? Int { return Int32(intVal) }
        if let doubleVal = value as? Double { return Int32(doubleVal) }
        return fallback
    }

    private static func readInt(_ key: String, default fallback: Int) -> Int {
        guard let value = settings[key] else { return fallback }
        if let intVal = value as? Int { return intVal }
        if let doubleVal = value as? Double { return Int(doubleVal) }
        return fallback
    }

    private static func readDouble(_ key: String, default fallback: Double) -> Double {
        guard let value = settings[key] else { return fallback }
        if let doubleVal = value as? Double { return doubleVal }
        if let intVal = value as? Int { return Double(intVal) }
        return fallback
    }
}
