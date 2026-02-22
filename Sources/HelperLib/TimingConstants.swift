// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Named constants for all timing delays and non-timing magic numbers used across the project.
// ABOUTME: Provides default values that can be overridden via settings.json through EnvConfig.

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

    /// Scroll wheel pixel-to-tick divisor. Each scroll tick moves approximately
    /// this many pixels in the content. Used to convert pixel distances to scroll
    /// wheel units for swipe gestures.
    public static let scrollPixelScale: Double = 8.0

    /// Maximum characters per HID typing chunk (Karabiner buffer capacity).
    public static let hidTypingChunkSize: Int = 15

    /// macOS built-in staff group ID for socket permissions.
    public static let staffGroupID: UInt32 = 20

    // MARK: - Helper Daemon

    /// Receive timeout (seconds) on client sockets. Prevents the accept loop from
    /// getting stuck when a client disconnects uncleanly.
    public static let clientRecvTimeoutSec: Int = 30

    /// Number of consecutive recv timeouts before dropping an idle client.
    /// With `clientRecvTimeoutSec = 30`, this gives ~120 seconds before disconnect.
    public static let clientIdleMaxTimeouts: Int = 4

    // MARK: - Content Bounds Detection

    /// Brightness threshold for dark pixel detection (0–255).
    public static let brightnessThreshold: UInt8 = 20

    // MARK: - Tap Point Calculation

    /// Max label length for "short label" classification.
    public static let tapMaxLabelLength: Int = 15

    /// Max label width as fraction of window width for "short label".
    public static let tapMaxLabelWidthFraction: Double = 0.4

    /// Minimum gap above to trigger upward offset for icon labels.
    public static let tapMinGapForOffset: Double = 50.0

    /// Minimum short labels in a row to be classified as an icon grid row.
    public static let tapIconRowMinLabels: Int = 3

    /// Fixed upward offset applied to short labels when a gap is detected.
    public static let tapIconOffset: Double = 30.0

    /// Elements within this vertical distance are treated as the same row.
    public static let tapRowTolerance: Double = 10.0

    // MARK: - Grid Overlay

    /// Points between grid lines in the mirroring window's coordinate space.
    public static let gridSpacing: Double = 25.0

    /// Alpha for grid lines.
    public static let gridLineAlpha: Double = 0.3

    /// Font size in points for coordinate labels.
    public static let gridLabelFontSize: Double = 8.0

    /// Show coordinate labels every N grid lines.
    public static let gridLabelEveryN: Int = 2

    // MARK: - Event Classification

    /// Tap distance threshold in points — clicks within this distance are taps.
    public static let eventTapDistanceThreshold: Double = 5.0

    /// Swipe distance threshold in points — drags beyond this distance are swipes.
    public static let eventSwipeDistanceThreshold: Double = 30.0

    /// Long press threshold in seconds.
    public static let eventLongPressThreshold: Double = 0.5

    /// Maximum distance in points for nearest-label lookup during event recording.
    public static let eventLabelMaxDistance: Double = 30.0

    // MARK: - Karabiner Protocol

    /// Heartbeat deadline in milliseconds for the vhidd server.
    public static let karabinerHeartbeatDeadlineMs: UInt32 = 5000

    /// Heartbeat interval in seconds.
    public static let karabinerHeartbeatIntervalSec: Double = 3.0

    /// Server liveness check interval in seconds.
    public static let karabinerServerCheckIntervalSec: Double = 3.0

    /// Timeout for waiting for virtual devices to become ready (seconds).
    public static let karabinerDeviceReadyTimeoutSec: Double = 10.0

    /// Buffer size for socket reads.
    public static let karabinerSocketBufferSize: Int = 1024

    // MARK: - Step Execution

    /// Default timeout in seconds for wait_for steps.
    public static let waitForTimeoutSeconds: Int = 15

    /// Default milliseconds to wait between steps for UI settling.
    public static let stepSettlingDelayMs: UInt32 = 500

    /// Extra milliseconds added to observed delays for compiled replay safety margin.
    public static let compiledSleepBufferMs: Int = 200

    /// Poll interval for wait_for steps (microseconds).
    public static let waitForPollIntervalUs: UInt32 = 1_000_000

    /// Poll interval for measure steps (microseconds).
    public static let measurePollIntervalUs: UInt32 = 500_000

    /// Delay for Settings app to load (microseconds).
    public static let settingsLoadUs: UInt32 = 1_500_000

    /// Vertical offset from the app name label to the card body center in the App Switcher (points).
    /// OCR detects the label above the card preview; this offset moves the swipe start point
    /// down into the card so the dismiss gesture registers reliably.
    public static let appSwitcherCardOffset: Double = 250.0

    /// Swipe distance for dismissing app cards in the App Switcher (points).
    public static let appSwitcherSwipeDistance: Double = 300.0

    /// Swipe duration for dismissing app cards in the App Switcher (milliseconds).
    public static let appSwitcherSwipeDurationMs: Int = 200

    /// Maximum horizontal swipes to search for an app card in the App Switcher carousel.
    /// Covers ~15 apps (3 visible per view × 5 swipes).
    public static let appSwitcherMaxSwipes: Int = 5

    /// UI settling delay after App Switcher or network toggle operations (microseconds).
    public static let toolSettlingDelayUs: UInt32 = 500_000

    // MARK: - Swipe & Scroll Defaults

    /// Swipe distance as a fraction of window height.
    public static let swipeDistanceFraction: Double = 0.3

    /// Default swipe duration in milliseconds.
    public static let defaultSwipeDurationMs: Int = 300

    /// Default maximum scroll attempts before giving up.
    public static let defaultScrollMaxAttempts: Int = 10

    // MARK: - AI Provider

    /// Default timeout for OpenAI API requests (seconds).
    public static let openAITimeoutSeconds: Int = 30

    /// Default timeout for Ollama API requests (seconds).
    public static let ollamaTimeoutSeconds: Int = 120

    /// Default timeout for Anthropic API requests (seconds).
    public static let anthropicTimeoutSeconds: Int = 30

    /// Default timeout for command-based AI agent processes (seconds).
    public static let commandTimeoutSeconds: Int = 60

    /// Default max tokens for AI model responses.
    public static let defaultAIMaxTokens: Int = 1024

    // MARK: - Input Tool Defaults

    /// Default drag duration in milliseconds.
    public static let defaultDragDurationMs: Int = 1000

    /// Default long press duration in milliseconds.
    public static let defaultLongPressDurationMs: Int = 500

    /// Default measure timeout in seconds.
    public static let defaultMeasureTimeoutSeconds: Double = 15.0
}
