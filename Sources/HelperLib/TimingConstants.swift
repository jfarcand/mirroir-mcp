// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Named constants for all timing delays and non-timing magic numbers used across the project.
// ABOUTME: Provides default values that can be overridden via environment variables through EnvConfig.

/// Default values for all timing and numeric constants.
/// Use ``EnvConfig`` to access these values with environment variable overrides.
public enum TimingConstants {
    // MARK: - Cursor & Input Settling

    /// Delay after CGWarpMouseCursorPosition for cursor to settle (microseconds).
    public static let cursorSettleUs: UInt32 = 10_000

    /// Delay after Karabiner nudge for virtual device sync (microseconds).
    public static let nudgeSettleUs: UInt32 = 5_000

    /// Hold duration for a standard click (microseconds).
    public static let clickHoldUs: UInt32 = 80_000

    /// Hold duration per tap in a double-tap gesture (microseconds).
    public static let doubleTapHoldUs: UInt32 = 40_000

    /// Gap between the two taps in a double-tap gesture (microseconds).
    public static let doubleTapGapUs: UInt32 = 50_000

    /// Initial hold before drag movement to trigger iOS drag recognition (microseconds).
    public static let dragModeHoldUs: UInt32 = 150_000

    /// Delay after focus click for keyboard focus to settle (microseconds).
    public static let focusSettleUs: UInt32 = 200_000

    /// Delay between individual keystrokes during typing (microseconds).
    public static let keystrokeDelayUs: UInt32 = 15_000

    // MARK: - App Switching & Navigation

    /// Delay after Space switch for macOS to settle (microseconds).
    public static let spaceSwitchSettleUs: UInt32 = 300_000

    /// Delay for Spotlight UI to appear and accept input (microseconds).
    public static let spotlightAppearanceUs: UInt32 = 800_000

    /// Delay for Spotlight search results to populate (microseconds).
    public static let searchResultsPopulateUs: UInt32 = 1_000_000

    /// Delay for Safari to fully load after launch (microseconds).
    public static let safariLoadUs: UInt32 = 1_500_000

    /// Delay for Safari address bar to activate after Cmd+L (microseconds).
    public static let addressBarActivateUs: UInt32 = 500_000

    /// Delay before pressing Return after typing a URL (microseconds).
    public static let preReturnUs: UInt32 = 300_000

    // MARK: - Process & System Polling

    /// Polling interval when waiting for a process to exit (microseconds).
    public static let processPollUs: UInt32 = 50_000

    /// Delay to detect early process failure (microseconds).
    public static let earlyFailureDetectUs: UInt32 = 500_000

    /// Delay for iPhone Mirroring connection to resume from paused state (microseconds).
    public static let resumeFromPausedUs: UInt32 = 2_000_000

    /// Delay after heartbeat for server to process and settle (microseconds).
    public static let postHeartbeatSettleUs: UInt32 = 100_000

    // MARK: - Karabiner HID

    /// Hold duration for a single key press via Karabiner HID (microseconds).
    public static let keyHoldUs: UInt32 = 20_000

    /// Delay between dead-key trigger and base character for compose sequences (microseconds).
    /// Dead-key input requires the compose state to settle before the base character arrives.
    public static let deadKeyDelayUs: UInt32 = 30_000

    /// Receive timeout for Karabiner socket responses (microseconds).
    public static let recvTimeoutUs: Int32 = 200_000

    // MARK: - Non-Timing Constants

    /// Number of interpolation steps for drag gestures.
    public static let dragInterpolationSteps: Int = 60

    /// Number of interpolation steps for swipe scroll gestures.
    public static let swipeInterpolationSteps: Int = 20

    /// Scale factor converting pixel distance to scroll wheel units.
    public static let scrollPixelScale: Double = 8.0

    /// Maximum characters per HID typing chunk (Karabiner buffer capacity).
    public static let hidTypingChunkSize: Int = 15

    /// macOS built-in staff group ID for socket permissions.
    public static let staffGroupID: UInt32 = 20
}
