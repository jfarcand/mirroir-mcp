// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Environment variable overrides for timing and numeric constants.
// ABOUTME: Reads IPHONE_MIRROIR_<NAME> env vars at access time, falling back to TimingConstants defaults.

import Foundation

/// Reads timing and numeric constants from environment variables, falling back
/// to ``TimingConstants`` defaults when not set.
///
/// Environment variable names follow the pattern `IPHONE_MIRROIR_<CONSTANT_NAME>`.
/// For example, `IPHONE_MIRROIR_CURSOR_SETTLE_US=20000` doubles the cursor settle time.
public enum EnvConfig {
    private static let env = ProcessInfo.processInfo.environment

    // MARK: - Cursor & Input Settling

    public static var cursorSettleUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_CURSOR_SETTLE_US", default: TimingConstants.cursorSettleUs)
    }

    public static var nudgeSettleUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_NUDGE_SETTLE_US", default: TimingConstants.nudgeSettleUs)
    }

    public static var clickHoldUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_CLICK_HOLD_US", default: TimingConstants.clickHoldUs)
    }

    public static var doubleTapHoldUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_DOUBLE_TAP_HOLD_US", default: TimingConstants.doubleTapHoldUs)
    }

    public static var doubleTapGapUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_DOUBLE_TAP_GAP_US", default: TimingConstants.doubleTapGapUs)
    }

    public static var dragModeHoldUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_DRAG_MODE_HOLD_US", default: TimingConstants.dragModeHoldUs)
    }

    public static var focusSettleUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_FOCUS_SETTLE_US", default: TimingConstants.focusSettleUs)
    }

    public static var keystrokeDelayUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_KEYSTROKE_DELAY_US", default: TimingConstants.keystrokeDelayUs)
    }

    // MARK: - App Switching & Navigation

    public static var spaceSwitchSettleUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_SPACE_SWITCH_SETTLE_US", default: TimingConstants.spaceSwitchSettleUs)
    }

    public static var spotlightAppearanceUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_SPOTLIGHT_APPEARANCE_US", default: TimingConstants.spotlightAppearanceUs)
    }

    public static var searchResultsPopulateUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_SEARCH_RESULTS_POPULATE_US", default: TimingConstants.searchResultsPopulateUs)
    }

    public static var safariLoadUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_SAFARI_LOAD_US", default: TimingConstants.safariLoadUs)
    }

    public static var addressBarActivateUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_ADDRESS_BAR_ACTIVATE_US", default: TimingConstants.addressBarActivateUs)
    }

    public static var preReturnUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_PRE_RETURN_US", default: TimingConstants.preReturnUs)
    }

    // MARK: - Process & System Polling

    public static var processPollUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_PROCESS_POLL_US", default: TimingConstants.processPollUs)
    }

    public static var earlyFailureDetectUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_EARLY_FAILURE_DETECT_US", default: TimingConstants.earlyFailureDetectUs)
    }

    public static var resumeFromPausedUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_RESUME_FROM_PAUSED_US", default: TimingConstants.resumeFromPausedUs)
    }

    public static var postHeartbeatSettleUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_POST_HEARTBEAT_SETTLE_US", default: TimingConstants.postHeartbeatSettleUs)
    }

    // MARK: - Karabiner HID

    public static var keyHoldUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_KEY_HOLD_US", default: TimingConstants.keyHoldUs)
    }

    public static var deadKeyDelayUs: UInt32 {
        readUInt32("IPHONE_MIRROIR_DEAD_KEY_DELAY_US", default: TimingConstants.deadKeyDelayUs)
    }

    public static var recvTimeoutUs: Int32 {
        readInt32("IPHONE_MIRROIR_RECV_TIMEOUT_US", default: TimingConstants.recvTimeoutUs)
    }

    // MARK: - Non-Timing Constants

    public static var dragInterpolationSteps: Int {
        readInt("IPHONE_MIRROIR_DRAG_INTERPOLATION_STEPS", default: TimingConstants.dragInterpolationSteps)
    }

    public static var swipeInterpolationSteps: Int {
        readInt("IPHONE_MIRROIR_SWIPE_INTERPOLATION_STEPS", default: TimingConstants.swipeInterpolationSteps)
    }

    public static var scrollPixelScale: Double {
        readDouble("IPHONE_MIRROIR_SCROLL_PIXEL_SCALE", default: TimingConstants.scrollPixelScale)
    }

    public static var hidTypingChunkSize: Int {
        readInt("IPHONE_MIRROIR_HID_TYPING_CHUNK_SIZE", default: TimingConstants.hidTypingChunkSize)
    }

    public static var staffGroupID: UInt32 {
        readUInt32("IPHONE_MIRROIR_STAFF_GROUP_ID", default: TimingConstants.staffGroupID)
    }

    // MARK: - App Identity

    public static var mirroringBundleID: String {
        readString("IPHONE_MIRROIR_BUNDLE_ID", default: "com.apple.ScreenContinuity")
    }

    public static var mirroringProcessName: String {
        readString("IPHONE_MIRROIR_PROCESS_NAME", default: "iPhone Mirroring")
    }

    // MARK: - Private Helpers

    private static func readString(_ key: String, default fallback: String) -> String {
        env[key] ?? fallback
    }

    private static func readUInt32(_ key: String, default fallback: UInt32) -> UInt32 {
        guard let value = env[key], let parsed = UInt32(value) else { return fallback }
        return parsed
    }

    private static func readInt32(_ key: String, default fallback: Int32) -> Int32 {
        guard let value = env[key], let parsed = Int32(value) else { return fallback }
        return parsed
    }

    private static func readInt(_ key: String, default fallback: Int) -> Int {
        guard let value = env[key], let parsed = Int(value) else { return fallback }
        return parsed
    }

    private static func readDouble(_ key: String, default fallback: Double) -> Double {
        guard let value = env[key], let parsed = Double(value) else { return fallback }
        return parsed
    }
}
