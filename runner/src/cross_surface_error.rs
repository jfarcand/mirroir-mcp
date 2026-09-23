// ABOUTME: Structured errors for the `cross_surface:` parity gate — its captures, its files, and its verdict.
// ABOUTME: Converts into RunnerError via #[from]; every variant carries the fields its message needs.

use thiserror::Error;

use crate::parser::step_args::CaptureSurface;

/// Errors raised while validating or running a `cross_surface:` step.
#[derive(Debug, Error)]
pub enum CrossSurfaceError {
    /// A capture was declared but the block that runs its surface carried no
    /// text for it — its `to` file would be compared stale, or not at all.
    #[error(
        "cross_surface step {index} declared a {surface} capture into `{to}` but the {surface} block's `mirroir-captures` attachment carried no text for it"
    )]
    NotCaptured {
        /// Index of the `cross_surface` step, as the file reads.
        index: usize,
        /// Surface the capture reads.
        surface: CaptureSurface,
        /// The capture's `to` path.
        to: String,
    },

    /// A pair of responses whose fingerprint similarity dropped below the
    /// configured threshold.
    #[error("cross_surface mismatch: `{a}` vs `{b}` similarity {observed:.3} < min {threshold:.3}")]
    Mismatch {
        /// First file path of the mismatching pair.
        a: String,
        /// Second file path of the mismatching pair.
        b: String,
        /// Jaccard similarity actually observed for that pair.
        observed: f64,
        /// Minimum similarity required.
        threshold: f64,
    },

    /// A comparison needs at least two response files.
    #[error("cross_surface: need at least 2 response files, got {count}")]
    TooFewFiles {
        /// How many were supplied.
        count: usize,
    },

    /// A response file fingerprinted to no tokens. Jaccard calls two empty
    /// token sets identical — the documented answer for drift against a
    /// recorded baseline — so a blank surface would clear any threshold
    /// against another blank one and prove nothing. A screen that yielded no
    /// OCR text captures as a lone newline, which is how an empty surface
    /// reaches the check in practice.
    #[error(
        "cross_surface response file `{path}` has no comparable text: an empty surface cannot substantiate an equivalence check"
    )]
    EmptySurface {
        /// The response file whose fingerprint held no tokens.
        path: String,
    },

    /// A capture writes somewhere the step never reads. The capture produces
    /// one of the compared files, so a `to` outside `response_files` — a typo,
    /// usually — would leave the captured text unread and compare a stale or
    /// missing file in its place.
    #[error(
        "cross_surface capture writes to `{to}`, which is not one of response_files {response_files:?}"
    )]
    CaptureTargetNotListed {
        /// Path the capture would have written.
        to: String,
        /// The files the step actually compares.
        response_files: Vec<String>,
    },

    /// A web capture scrapes an element, so it needs the selector naming it.
    #[error("cross_surface step {index}: a `surface: web` capture needs a non-empty `selector`")]
    WebCaptureWithoutSelector {
        /// Index of the `cross_surface` step.
        index: usize,
    },

    /// An iOS capture is the block's final screen, read by OCR; a selector
    /// would suggest an element was scraped when none is.
    #[error(
        "cross_surface step {index}: a `surface: ios` capture is the iOS block's final screen and takes no `selector`"
    )]
    IosCaptureWithSelector {
        /// Index of the `cross_surface` step.
        index: usize,
    },

    /// Two captures write the same file, so one silently overwrites the other.
    #[error("cross_surface step {index}: two captures write `{to}`")]
    DuplicateCaptureTarget {
        /// Index of the `cross_surface` step.
        index: usize,
        /// The path both captures write.
        to: String,
    },

    /// A capture reads a surface the scenario opens no block for.
    #[error(
        "cross_surface step {index} captures the {surface} surface, but the scenario opens no `target: {{ kind: {surface} }}` block"
    )]
    CaptureWithoutBlock {
        /// Index of the `cross_surface` step.
        index: usize,
        /// Surface the capture reads.
        surface: CaptureSurface,
    },
}
