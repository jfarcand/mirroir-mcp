// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: JSON-based configuration overrides for timing and numeric constants.
// ABOUTME: Reads settings.json first, then MIRROIR_* env vars, falling back to TimingConstants.

import Foundation

/// Types that can be decoded from settings.json values and environment variable strings.
/// Each conforming type defines how to extract itself from an `Any` JSON value and
/// how to parse from a string (for env var overrides).
public protocol ConfigDecodable {
    static func decodeFromSettings(_ value: Any) -> Self?
    static func parseFromEnv(_ string: String) -> Self?
}

extension UInt32: ConfigDecodable {
    public static func decodeFromSettings(_ value: Any) -> UInt32? {
        if let intVal = value as? Int, intVal >= 0 { return UInt32(intVal) }
        if let doubleVal = value as? Double, doubleVal >= 0 { return UInt32(doubleVal) }
        return nil
    }

    public static func parseFromEnv(_ string: String) -> UInt32? {
        UInt32(string)
    }
}

extension Int32: ConfigDecodable {
    public static func decodeFromSettings(_ value: Any) -> Int32? {
        if let intVal = value as? Int { return Int32(intVal) }
        if let doubleVal = value as? Double { return Int32(doubleVal) }
        return nil
    }

    public static func parseFromEnv(_ string: String) -> Int32? {
        Int32(string)
    }
}

extension Int: ConfigDecodable {
    public static func decodeFromSettings(_ value: Any) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let doubleVal = value as? Double { return Int(doubleVal) }
        return nil
    }

    public static func parseFromEnv(_ string: String) -> Int? {
        Int(string)
    }
}

extension Double: ConfigDecodable {
    public static func decodeFromSettings(_ value: Any) -> Double? {
        if let doubleVal = value as? Double { return doubleVal }
        if let intVal = value as? Int { return Double(intVal) }
        return nil
    }

    public static func parseFromEnv(_ string: String) -> Double? {
        Double(string)
    }
}

extension String: ConfigDecodable {
    public static func decodeFromSettings(_ value: Any) -> String? {
        value as? String
    }

    public static func parseFromEnv(_ string: String) -> String? {
        string
    }
}

extension UInt8: ConfigDecodable {
    public static func decodeFromSettings(_ value: Any) -> UInt8? {
        if let num = value as? Int, num >= 0, num <= 255 { return UInt8(num) }
        return nil
    }

    public static func parseFromEnv(_ string: String) -> UInt8? {
        guard let num = Int(string), num >= 0, num <= 255 else { return nil }
        return UInt8(num)
    }
}

/// A typed configuration key that captures the settings key name, default value,
/// and optional custom environment variable name.
public struct ConfigKey<T: ConfigDecodable> {
    public let name: String
    public let envVar: String?
    public let defaultValue: T

    public init(_ name: String, envVar: String? = nil, default defaultValue: T) {
        self.name = name
        self.envVar = envVar
        self.defaultValue = defaultValue
    }
}

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

    /// Generic configuration reader. Checks settings.json, then env var, then default.
    private static func read<T: ConfigDecodable>(_ key: ConfigKey<T>) -> T {
        if let value = settings[key.name], let decoded = T.decodeFromSettings(value) {
            return decoded
        }
        let envName = key.envVar ?? envVarName(key.name)
        if let str = env[envName], let parsed = T.parseFromEnv(str) {
            return parsed
        }
        return key.defaultValue
    }

    // MARK: - Cursor & Input Settling

    public static var cursorSettleUs: UInt32 {
        read(ConfigKey("cursorSettleUs", default: TimingConstants.cursorSettleUs))
    }

    public static var nudgeSettleUs: UInt32 {
        read(ConfigKey("nudgeSettleUs", default: TimingConstants.nudgeSettleUs))
    }

    public static var clickHoldUs: UInt32 {
        read(ConfigKey("clickHoldUs", default: TimingConstants.clickHoldUs))
    }

    public static var doubleTapHoldUs: UInt32 {
        read(ConfigKey("doubleTapHoldUs", default: TimingConstants.doubleTapHoldUs))
    }

    public static var doubleTapGapUs: UInt32 {
        read(ConfigKey("doubleTapGapUs", default: TimingConstants.doubleTapGapUs))
    }

    public static var dragModeHoldUs: UInt32 {
        read(ConfigKey("dragModeHoldUs", default: TimingConstants.dragModeHoldUs))
    }

    public static var focusSettleUs: UInt32 {
        read(ConfigKey("focusSettleUs", default: TimingConstants.focusSettleUs))
    }

    public static var keystrokeDelayUs: UInt32 {
        read(ConfigKey("keystrokeDelayUs", default: TimingConstants.keystrokeDelayUs))
    }

    // MARK: - App Switching & Navigation

    public static var spaceSwitchSettleUs: UInt32 {
        read(ConfigKey("spaceSwitchSettleUs", default: TimingConstants.spaceSwitchSettleUs))
    }

    public static var spotlightAppearanceUs: UInt32 {
        read(ConfigKey("spotlightAppearanceUs", default: TimingConstants.spotlightAppearanceUs))
    }

    public static var searchResultsPopulateUs: UInt32 {
        read(ConfigKey("searchResultsPopulateUs", default: TimingConstants.searchResultsPopulateUs))
    }

    public static var safariLoadUs: UInt32 {
        read(ConfigKey("safariLoadUs", default: TimingConstants.safariLoadUs))
    }

    public static var addressBarActivateUs: UInt32 {
        read(ConfigKey("addressBarActivateUs", default: TimingConstants.addressBarActivateUs))
    }

    public static var preReturnUs: UInt32 {
        read(ConfigKey("preReturnUs", default: TimingConstants.preReturnUs))
    }

    // MARK: - Process & System Polling

    public static var processPollUs: UInt32 {
        read(ConfigKey("processPollUs", default: TimingConstants.processPollUs))
    }

    public static var earlyFailureDetectUs: UInt32 {
        read(ConfigKey("earlyFailureDetectUs", default: TimingConstants.earlyFailureDetectUs))
    }

    public static var resumeFromPausedUs: UInt32 {
        read(ConfigKey("resumeFromPausedUs", default: TimingConstants.resumeFromPausedUs))
    }

    public static var postHeartbeatSettleUs: UInt32 {
        read(ConfigKey("postHeartbeatSettleUs", default: TimingConstants.postHeartbeatSettleUs))
    }

    // MARK: - Karabiner HID

    public static var keyHoldUs: UInt32 {
        read(ConfigKey("keyHoldUs", default: TimingConstants.keyHoldUs))
    }

    public static var deadKeyDelayUs: UInt32 {
        read(ConfigKey("deadKeyDelayUs", default: TimingConstants.deadKeyDelayUs))
    }

    public static var recvTimeoutUs: Int32 {
        read(ConfigKey("recvTimeoutUs", default: TimingConstants.recvTimeoutUs))
    }

    // MARK: - Non-Timing Constants

    public static var dragInterpolationSteps: Int {
        read(ConfigKey("dragInterpolationSteps", default: TimingConstants.dragInterpolationSteps))
    }

    public static var swipeInterpolationSteps: Int {
        read(ConfigKey("swipeInterpolationSteps", default: TimingConstants.swipeInterpolationSteps))
    }

    public static var scrollPixelScale: Double {
        read(ConfigKey("scrollPixelScale", default: TimingConstants.scrollPixelScale))
    }

    public static var hidTypingChunkSize: Int {
        read(ConfigKey("hidTypingChunkSize", default: TimingConstants.hidTypingChunkSize))
    }

    public static var staffGroupID: UInt32 {
        read(ConfigKey("staffGroupID", default: TimingConstants.staffGroupID))
    }

    // MARK: - Helper Daemon

    /// Receive timeout (seconds) on client sockets. When recv() blocks longer than
    /// this without data, it returns EAGAIN so the accept loop can detect dead clients.
    public static var clientRecvTimeoutSec: Int {
        read(ConfigKey("clientRecvTimeoutSec", default: TimingConstants.clientRecvTimeoutSec))
    }

    /// Number of consecutive recv timeouts before dropping an idle client.
    /// With `clientRecvTimeoutSec = 30`, the default of 4 gives ~120 seconds.
    public static var clientIdleMaxTimeouts: Int {
        read(ConfigKey("clientIdleMaxTimeouts", default: TimingConstants.clientIdleMaxTimeouts))
    }

    // MARK: - Content Bounds Detection

    public static var brightnessThreshold: UInt8 {
        read(ConfigKey("brightnessThreshold", default: TimingConstants.brightnessThreshold))
    }

    // MARK: - Tap Point Calculation

    public static var tapMaxLabelLength: Int {
        read(ConfigKey("tapMaxLabelLength", default: TimingConstants.tapMaxLabelLength))
    }

    public static var tapMaxLabelWidthFraction: Double {
        read(ConfigKey("tapMaxLabelWidthFraction", default: TimingConstants.tapMaxLabelWidthFraction))
    }

    public static var tapMinGapForOffset: Double {
        read(ConfigKey("tapMinGapForOffset", default: TimingConstants.tapMinGapForOffset))
    }

    public static var tapIconRowMinLabels: Int {
        read(ConfigKey("tapIconRowMinLabels", default: TimingConstants.tapIconRowMinLabels))
    }

    public static var tapIconOffset: Double {
        read(ConfigKey("tapIconOffset", default: TimingConstants.tapIconOffset))
    }

    public static var tapRowTolerance: Double {
        read(ConfigKey("tapRowTolerance", default: TimingConstants.tapRowTolerance))
    }

    // MARK: - Grid Overlay

    public static var gridSpacing: Double {
        read(ConfigKey("gridSpacing", default: TimingConstants.gridSpacing))
    }

    public static var gridLineAlpha: Double {
        read(ConfigKey("gridLineAlpha", default: TimingConstants.gridLineAlpha))
    }

    public static var gridLabelFontSize: Double {
        read(ConfigKey("gridLabelFontSize", default: TimingConstants.gridLabelFontSize))
    }

    public static var gridLabelEveryN: Int {
        read(ConfigKey("gridLabelEveryN", default: TimingConstants.gridLabelEveryN))
    }

    // MARK: - Event Classification

    public static var eventTapDistanceThreshold: Double {
        read(ConfigKey("eventTapDistanceThreshold", default: TimingConstants.eventTapDistanceThreshold))
    }

    public static var eventSwipeDistanceThreshold: Double {
        read(ConfigKey("eventSwipeDistanceThreshold", default: TimingConstants.eventSwipeDistanceThreshold))
    }

    public static var eventLongPressThreshold: Double {
        read(ConfigKey("eventLongPressThreshold", default: TimingConstants.eventLongPressThreshold))
    }

    public static var eventLabelMaxDistance: Double {
        read(ConfigKey("eventLabelMaxDistance", default: TimingConstants.eventLabelMaxDistance))
    }

    // MARK: - Karabiner Protocol

    public static var karabinerHeartbeatDeadlineMs: UInt32 {
        read(ConfigKey("karabinerHeartbeatDeadlineMs", default: TimingConstants.karabinerHeartbeatDeadlineMs))
    }

    public static var karabinerHeartbeatIntervalSec: Double {
        read(ConfigKey("karabinerHeartbeatIntervalSec", default: TimingConstants.karabinerHeartbeatIntervalSec))
    }

    public static var karabinerServerCheckIntervalSec: Double {
        read(ConfigKey("karabinerServerCheckIntervalSec", default: TimingConstants.karabinerServerCheckIntervalSec))
    }

    public static var karabinerDeviceReadyTimeoutSec: Double {
        read(ConfigKey("karabinerDeviceReadyTimeoutSec", default: TimingConstants.karabinerDeviceReadyTimeoutSec))
    }

    public static var karabinerSocketBufferSize: Int {
        read(ConfigKey("karabinerSocketBufferSize", default: TimingConstants.karabinerSocketBufferSize))
    }

    // MARK: - Step Execution

    public static var waitForTimeoutSeconds: Int {
        read(ConfigKey("waitForTimeoutSeconds", default: TimingConstants.waitForTimeoutSeconds))
    }

    public static var stepSettlingDelayMs: UInt32 {
        read(ConfigKey("stepSettlingDelayMs", default: TimingConstants.stepSettlingDelayMs))
    }

    public static var compiledSleepBufferMs: Int {
        read(ConfigKey("compiledSleepBufferMs", default: TimingConstants.compiledSleepBufferMs))
    }

    public static var waitForPollIntervalUs: UInt32 {
        read(ConfigKey("waitForPollIntervalUs", default: TimingConstants.waitForPollIntervalUs))
    }

    public static var measurePollIntervalUs: UInt32 {
        read(ConfigKey("measurePollIntervalUs", default: TimingConstants.measurePollIntervalUs))
    }

    public static var settingsLoadUs: UInt32 {
        read(ConfigKey("settingsLoadUs", default: TimingConstants.settingsLoadUs))
    }

    public static var appSwitcherCardOffset: Double {
        read(ConfigKey("appSwitcherCardOffset", default: TimingConstants.appSwitcherCardOffset))
    }

    public static var appSwitcherSwipeDistance: Double {
        read(ConfigKey("appSwitcherSwipeDistance", default: TimingConstants.appSwitcherSwipeDistance))
    }

    public static var appSwitcherSwipeDurationMs: Int {
        read(ConfigKey("appSwitcherSwipeDurationMs", default: TimingConstants.appSwitcherSwipeDurationMs))
    }

    public static var toolSettlingDelayUs: UInt32 {
        read(ConfigKey("toolSettlingDelayUs", default: TimingConstants.toolSettlingDelayUs))
    }

    // MARK: - Swipe & Scroll Defaults

    public static var swipeDistanceFraction: Double {
        read(ConfigKey("swipeDistanceFraction", default: TimingConstants.swipeDistanceFraction))
    }

    public static var defaultSwipeDurationMs: Int {
        read(ConfigKey("defaultSwipeDurationMs", default: TimingConstants.defaultSwipeDurationMs))
    }

    public static var defaultScrollMaxAttempts: Int {
        read(ConfigKey("defaultScrollMaxAttempts", default: TimingConstants.defaultScrollMaxAttempts))
    }

    // MARK: - AI Provider

    public static var openAITimeoutSeconds: Int {
        read(ConfigKey("openAITimeoutSeconds", default: TimingConstants.openAITimeoutSeconds))
    }

    public static var ollamaTimeoutSeconds: Int {
        read(ConfigKey("ollamaTimeoutSeconds", default: TimingConstants.ollamaTimeoutSeconds))
    }

    public static var anthropicTimeoutSeconds: Int {
        read(ConfigKey("anthropicTimeoutSeconds", default: TimingConstants.anthropicTimeoutSeconds))
    }

    public static var commandTimeoutSeconds: Int {
        read(ConfigKey("commandTimeoutSeconds", default: TimingConstants.commandTimeoutSeconds))
    }

    public static var defaultAIMaxTokens: Int {
        read(ConfigKey("defaultAIMaxTokens", default: TimingConstants.defaultAIMaxTokens))
    }

    // MARK: - Input Tool Defaults

    public static var defaultDragDurationMs: Int {
        read(ConfigKey("defaultDragDurationMs", default: TimingConstants.defaultDragDurationMs))
    }

    public static var defaultLongPressDurationMs: Int {
        read(ConfigKey("defaultLongPressDurationMs", default: TimingConstants.defaultLongPressDurationMs))
    }

    public static var defaultMeasureTimeoutSeconds: Double {
        read(ConfigKey("defaultMeasureTimeoutSeconds", default: TimingConstants.defaultMeasureTimeoutSeconds))
    }

    // MARK: - App Identity

    public static var mirroringBundleID: String {
        read(ConfigKey("mirroringBundleID", envVar: "MIRROIR_BUNDLE_ID",
                       default: "com.apple.ScreenContinuity"))
    }

    public static var mirroringProcessName: String {
        read(ConfigKey("mirroringProcessName", envVar: "MIRROIR_PROCESS_NAME",
                       default: "iPhone Mirroring"))
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
}
