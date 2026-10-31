// ABOUTME: Structured error type for the oracle layer — judge scoring plus drift threshold resolution.
// ABOUTME: Converts into RunnerError via #[from]; every variant carries the fields its message needs.

use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::oracle::thresholds::DriftMetric;

/// Errors raised by the LLM judge and the drift detector.
///
/// The oracle layer — profile registry, judge scoring, drift threshold
/// resolution, the last-green baseline store — owns this enum so
/// [`crate::error::RunnerError`] stays the runner-wide surface. Every variant
/// converts into [`crate::error::RunnerError::Oracle`] through `#[from]`, so
/// `?` propagates them unchanged.
#[derive(Debug, Error)]
pub enum OracleError {
    /// Scenario named a judge profile the registry doesn't know.
    #[error("unknown judge profile `{profile}`")]
    UnknownProfile {
        /// Name of the missing profile.
        profile: String,
    },

    /// The judge profile required an environment variable for its API key.
    #[error("judge profile `{profile}` requires env `{env_var}` to be set")]
    MissingApiKey {
        /// The profile that requires the key.
        profile: String,
        /// Name of the environment variable that wasn't found.
        env_var: String,
    },

    /// HTTP transport to the LLM provider failed.
    #[error("judge HTTP transport to `{url}` failed")]
    Transport {
        /// Provider URL that was being contacted.
        url: String,
        /// Underlying `reqwest` error.
        #[source]
        source: reqwest::Error,
    },

    /// The provider responded but the shape was unexpected.
    #[error("judge response decode failed: {reason}")]
    Decode {
        /// Short human-readable description of what was wrong.
        reason: String,
    },

    /// `oracles/profiles.yaml` exists but could not be read or parsed as a
    /// `profiles:` list of judge profiles.
    #[error("failed to load judge profiles from {path}: {reason}")]
    ProfilesParse {
        /// Path to the offending `profiles.yaml`.
        path: PathBuf,
        /// Read or parse error description.
        reason: String,
    },

    /// Scenario pinned a `user_prompt_template_hash` that no longer matches the
    /// current oracle prompt template — the prompt changed, so the scenario's
    /// score calibration is stale and must be re-pinned.
    #[error(
        "judge user_prompt_template_hash mismatch: scenario pinned `{declared}` but current template is `{expected}` — re-pin the scenario"
    )]
    TemplateMismatch {
        /// Hash of the current oracle user-prompt template.
        expected: String,
        /// Hash the scenario declared.
        declared: String,
    },

    /// Judge scored the response below `pass_threshold - tolerance`.
    #[error("judge score {score:.3} below pass_threshold {threshold:.3} (profile `{profile}`)")]
    BelowThreshold {
        /// Profile that ran the scoring.
        profile: String,
        /// Score the judge returned.
        score: f64,
        /// Effective pass threshold (after tolerance subtracted).
        threshold: f64,
    },

    /// A drift metric had to be evaluated and no layer of the threshold
    /// hierarchy declared a value for it. Fail-closed: the runner refuses to
    /// invent a ceiling, because a guessed threshold silently decides whether
    /// a semantic change is a DRIFT verdict or a green run.
    #[error(
        "unspecified drift threshold for {metric} — declare it in the scenario's `drift:` block, the sample's APP.md `drift_defaults:`, or a `drift-defaults.yaml` on the search path"
    )]
    ThresholdUnspecified {
        /// The metric whose threshold could not be resolved.
        metric: DriftMetric,
    },

    /// No `drift-defaults.yaml` exists at any candidate on the search path.
    /// The global layer is required to exist (fail-closed): without it, every
    /// metric a scenario and its APP.md leave undeclared has no threshold, and
    /// the run would only discover that once a comparison is already due.
    #[error(
        "no drift-defaults.yaml found (searched: {}); the global layer is required (fail-closed)",
        display_paths(.searched)
    )]
    ThresholdsMissing {
        /// Every candidate path the loader checked, most specific first.
        searched: Vec<PathBuf>,
    },

    /// A `drift-defaults.yaml` or an APP.md `drift_defaults:` block exists but
    /// could not be read or parsed.
    #[error("failed to load drift thresholds from {path}: {reason}")]
    ThresholdsParse {
        /// Path to the offending file.
        path: PathBuf,
        /// Read or parse error description.
        reason: String,
    },

    /// The last-green baseline store exists but could not be read or parsed.
    #[error("failed to load the last-green baseline at {path}: {reason}")]
    BaselineParse {
        /// Path to the offending `last-green.json`.
        path: PathBuf,
        /// Read or parse error description.
        reason: String,
    },

    /// A `<scenario>.compiled.json` screen reference exists but is not a
    /// compiled skill. A reference that cannot be read cannot be compared
    /// against, so the run refuses rather than skipping the screen check.
    #[error("failed to load the compiled screen reference at {path}: {reason}")]
    CompiledParse {
        /// Path to the offending compiled file.
        path: PathBuf,
        /// Parse error description.
        reason: String,
    },

    /// `mirroir-mcp test` passed an `ios` block it was asked to record, and
    /// left no compiled skill where it was told to write one. The next run
    /// would have no screen reference to compare against, so the run fails
    /// now instead of passing without one.
    #[error(
        "mirroir-mcp passed the ios block but recorded no compiled screen reference at {staged}; nothing was written to {destination}"
    )]
    CompiledNotRecorded {
        /// Where `mirroir-mcp test --compiled-out` was told to write.
        staged: PathBuf,
        /// The reference the run would have recorded.
        destination: PathBuf,
    },
}

/// Render a list of paths as one comma-separated string for an error message.
fn display_paths(paths: &[PathBuf]) -> String {
    paths
        .iter()
        .map(PathBuf::as_path)
        .map(Path::display)
        .map(|path| path.to_string())
        .collect::<Vec<_>>()
        .join(", ")
}
