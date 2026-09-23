// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Named constants for all timing delays and non-timing magic numbers used across the project.
// ABOUTME: Provides default values that can be overridden via settings.json through EnvConfig.

/// Default values for all timing and numeric constants.
/// Use ``EnvConfig`` to access these values with environment variable overrides.
public enum TimingConstants {
    // MARK: - Cursor & Input Settling

    // MARK: - App Switching & Navigation

    /// Delay after Space switch for macOS to settle (microseconds).
    public static let spaceSwitchSettleUs: UInt32 = 300_000

    /// Delay for Spotlight UI to appear and accept input (microseconds).
    public static let spotlightAppearanceUs: UInt32 = 800_000

    /// Delay for Spotlight search results to populate (microseconds).
    public static let searchResultsPopulateUs: UInt32 = 1_000_000

    /// Delay after pressing Return in Spotlight before launch_app reads the
    /// screen to confirm Spotlight closed (microseconds).
    public static let launchVerifySettleUs: UInt32 = 1_200_000

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

    /// Number of mouse clicks on a Continuity interruption overlay (camera dialog /
    /// resume button) to attempt before giving up freeing a paused session. The
    /// camera dialog can re-arm, so more than one click may be needed.
    public static let pausedDismissClickAttempts: Int = 3

    /// Delay after heartbeat for server to process and settle (microseconds).
    public static let postHeartbeatSettleUs: UInt32 = 100_000

    // MARK: - CGEvent Keyboard

    /// Delay between dead-key trigger and base character for compose sequences (microseconds).
    /// Dead-key input requires the compose state to settle before the base character arrives.
    public static let deadKeyDelayUs: UInt32 = 30_000

    // MARK: - Non-Timing Constants

    /// Number of interpolation steps for drag gestures.
    public static let dragInterpolationSteps: Int = 60

    /// Number of interpolation steps for swipe scroll gestures.
    public static let swipeInterpolationSteps: Int = 20

    /// Scroll wheel pixel-to-tick divisor. Each scroll tick moves approximately
    /// this many pixels in the content. Used to convert pixel distances to scroll
    /// wheel units for swipe gestures.
    public static let scrollPixelScale: Double = 8.0

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

    /// Fraction of window height defining the bottom zone.
    /// Icon rows in this zone always get the upward tap offset, regardless of gap,
    /// to handle in-app tab bars where content sits close above the tab labels.
    public static let tapBottomZoneFraction: Double = 0.90

    /// Maximum allowed `maxSpacing / minSpacing` ratio between adjacent
    /// elements in a row before it is rejected as an icon-grid row.
    /// Icon grids (home screen, tab bars) have evenly-spaced columns
    /// (observed ratio ≤ 1.2). In-content horizontal toolbars (e.g. Chrome's
    /// download bar) pack variable-width buttons with uneven gaps (observed
    /// ratio ≥ 4.0). 1.5 separates the two cleanly with margin for OCR jitter.
    public static let tapIconRowMaxSpacingRatio: Double = 1.5

    // MARK: - Safe Area

    /// Elements below `screenHeight - safeBottomMarginPt` trigger iOS home gestures
    /// when tapped, so they are excluded from exploration plans.
    public static let safeBottomMarginPt: Double = 62

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

    /// Horizontal position of the current app card in the App Switcher, as a fraction
    /// of window width. Empirically tuned — in the iPhone Mirroring window, after
    /// Spotlight-launching an app then opening App Switcher, the just-launched
    /// card sits at ~75% from the left edge, not visually centered. Do not
    /// "correct" this to 0.5 without testing on a real device — value was
    /// reverted from 0.5 → 0.75 after a regression closed the wrong app.
    public static let appSwitcherCardXFraction: Double = 0.75

    /// Vertical position for the drag start point in the App Switcher, as a fraction
    /// of window height. Targets the middle of the card body.
    public static let appSwitcherCardYFraction: Double = 0.55

    /// Swipe distance for dismissing app cards in the App Switcher (points).
    /// Large enough to flick the card off the top: the just-launched (current)
    /// app's card is centered and larger than the peeking side cards, so a short
    /// drag that dismisses an edge card leaves the bigger center card on screen.
    public static let appSwitcherSwipeDistance: Double = 600.0

    /// Swipe duration for dismissing app cards in the App Switcher (milliseconds).
    /// Calibration history: ~120ms force-quit on earlier iOS while 200ms did
    /// not; after the trackpad-faithful gesture synthesis changes, 120ms drags
    /// post successfully but iOS 26 no longer takes the dismissal ("card still
    /// in the App Switcher"), while ~400ms deliberate drags dismissed reliably
    /// (verified on-device against iOS 26.5.1, three consecutive dismissals).
    /// A vertical drag at this duration does not scroll the carousel — the
    /// carousel pans horizontally.
    public static let appSwitcherSwipeDurationMs: Int = 400

    /// Minimum window-relative Y (points) where a card-dismiss drag may end.
    /// Window y=0 is the macOS title-bar edge — releasing a drag there is a
    /// cancelled touch to iOS and the card snaps back. 80pt keeps the release
    /// inside the mirrored content (device-verified dismissal end point).
    public static let appSwitcherSwipeTopMarginPt: Double = 80.0

    /// Minimum OCR elements for a foreground capture to serve as a card-match
    /// fingerprint. A cold-launch splash screen yields fewer; real app UIs
    /// render well above this.
    public static let appForegroundReadyMinElements: Int = 5

    /// Attempts to capture a content-rich foreground fingerprint before
    /// giving up (cold launches render within 2-4 seconds).
    public static let appForegroundReadyRetries: Int = 4

    /// Settle delay after opening the App Switcher before capturing OCR for
    /// card location (microseconds). On iOS 26 the just-foregrounded app's
    /// card enters centered and then slides to its resting slot right of
    /// center while the previous app settles in the middle; OCR captured
    /// mid-slide aims the dismiss drag at a position the card has already
    /// left (device-verified: ~1s after opening the card still reads near
    /// center; the settled layout is what the drag must target).
    public static let appSwitcherOpenSettleUs: UInt32 = 2_500_000

    /// Maximum horizontal swipes to search for an app card in the App Switcher carousel.
    /// Covers ~15 apps (3 visible per view × 5 swipes).
    public static let appSwitcherMaxSwipes: Int = 5

    /// UI settling delay after App Switcher or network toggle operations (microseconds).
    public static let toolSettlingDelayUs: UInt32 = 500_000

    // MARK: - Focus Recovery

    /// Y coordinate in window-relative points for the status bar engagement tap.
    /// After a macOS Space switch, scroll events require the window to be the
    /// key window. A click at this Y engages the window; the iOS status bar
    /// is a safe tap target (most apps scroll to top, no navigation changes).
    public static let statusBarTapY: Double = 30.0

    // MARK: - Swipe & Scroll Defaults

    /// Swipe distance as a fraction of window height.
    public static let swipeDistanceFraction: Double = 0.3

    /// Scroll-swipe start Y as a fraction of window height.
    /// Scroll wheel events require the cursor midpoint to be in the upper
    /// content area of iPhone Mirroring. Default produces fromY≈500 on 898px.
    public static let scrollSwipeFromYFraction: Double = 0.56

    /// Scroll-swipe end Y as a fraction of window height.
    /// Default produces toY≈100 on 898px, giving midpoint≈300.
    public static let scrollSwipeToYFraction: Double = 0.11

    /// Default swipe duration in milliseconds.
    public static let defaultSwipeDurationMs: Int = 300

    /// Default maximum scroll attempts before giving up.
    public static let defaultScrollMaxAttempts: Int = 10

    /// Minimum number of matching anchors required for anchor-based scroll offset.
    /// When fewer anchors match, falls back to text-set deduplication.
    public static let scrollAnchorMinCount: Int = 1

    // MARK: - AI Provider

    /// Default timeout for OpenAI API requests (seconds).
    public static let openAITimeoutSeconds: Int = 30

    /// Default timeout for Ollama API requests (seconds).
    public static let ollamaTimeoutSeconds: Int = 120

    /// Default timeout for Anthropic API requests (seconds).
    public static let anthropicTimeoutSeconds: Int = 30

    /// Default timeout for embacle-server API requests (seconds).
    /// Higher than direct API providers because embacle spawns CLI subprocesses.
    public static let embacleTimeoutSeconds: Int = 60

    /// Default timeout for command-based AI agent processes (seconds).
    public static let commandTimeoutSeconds: Int = 60

    /// Default max tokens for AI model responses.
    public static let defaultAIMaxTokens: Int = 1024

    /// Default max tokens for vision screen description responses.
    /// Higher than defaultAIMaxTokens because home screens with 20+ elements
    /// produce JSON arrays that easily exceed 4096 tokens.
    public static let visionMaxTokens: Int = 8192

    /// Override the model name sent in vision chat completion requests.
    /// Empty string means use the provider default (e.g. "copilot_headless" for embacle).
    /// Set to a specific model (e.g. "gpt-4.1") to route through the configured provider.
    public static let visionModel: String = ""

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

    // MARK: - OCR Configuration

    /// OCR recognition level: "accurate" (higher quality, slower) or "fast" (lower quality, faster).
    public static let ocrRecognitionLevel: String = "accurate"

    /// Whether to enable language correction during OCR text recognition.
    public static let ocrLanguageCorrection: Bool = true

    /// Minimum screenshot pixel width for OCR. Images narrower than this are
    /// upscaled before text recognition so Apple Vision can resolve small labels.
    /// 600 ensures "Smaller" zoom mode (~424px @2x) is upscaled to match
    /// "Actual Size" resolution (~636px @2x) while larger modes pass through.
    public static let ocrMinImageWidth: Int = 600

    // MARK: - YOLO Element Detection

    /// OCR backend selection: "auto" (use both if a YOLO model is installed, vision otherwise),
    /// "vision" (Apple Vision text only), "yolo" (CoreML element detection only),
    /// or "both" (merge results from both backends).
    public static let ocrBackend: String = "auto"

    /// URL to download a YOLO .mlmodel or .mlmodelc from on first use.
    public static let yoloModelURL: String = ""

    /// Local filesystem path to a pre-compiled .mlmodelc directory. Overrides download.
    public static let yoloModelPath: String = ""

    /// Minimum confidence threshold for YOLO element detections (0.0–1.0).
    public static let yoloConfidenceThreshold: Double = 0.3

    // MARK: - Scroll Deduplication

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

    // MARK: - Exploration Budget

    /// Maximum DFS depth before forcing backtrack.
    public static let explorationMaxDepth: Int = 6

    /// Maximum distinct screens before stopping exploration.
    public static let explorationMaxScreens: Int = 30

    /// Maximum wall-clock seconds before stopping exploration.
    public static let explorationMaxTimeSeconds: Int = 300

    // MARK: - Calibration Validation

    /// When true, exploration fails with a diagnostic report if too many elements
    /// are unclassified after calibration. When false, logs a warning and continues.
    /// Default false: real apps have charts, calendars, and other elements that don't
    /// match component definitions. Strict mode is for debugging component definitions.
    public static let calibrationStrict: Bool = false

    /// Maximum fraction of content-zone elements that can be unclassified before
    /// calibration validation fails (0.0–1.0). Only checked when calibrationStrict is true.
    public static let calibrationUnclassifiedThreshold: Double = 0.5

    // MARK: - Compiled Safety

    /// Minimum confidence threshold for compiled taps (0.0–1.0).
    /// Taps below this threshold fall back to live OCR.
    public static let compiledTapMinConfidence: Double = 0.7

    // MARK: - Input Tool Defaults

    /// Default drag duration in milliseconds.
    public static let defaultDragDurationMs: Int = 1000

    /// Default long press duration in milliseconds.
    public static let defaultLongPressDurationMs: Int = 500

    /// Default measure timeout in seconds.
    public static let defaultMeasureTimeoutSeconds: Double = 15.0
}
