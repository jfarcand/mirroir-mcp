// ABOUTME: The `mirroir-captures` attachment body — what a block's run attached for the runner-side checks.
// ABOUTME: Web blocks attach metrics, judge and parity text; ios blocks add screens, the device, and scene reports.

use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;

use serde::Deserialize;

use crate::parser::compiled::{DeviceInfo, ScreenFingerprint};

/// Values a block attached under
/// [`crate::compile::report::CAPTURES_ATTACHMENT`].
///
/// `metrics` is keyed by the `measure:` step's `name` and holds milliseconds.
/// `judge` and `cross_surface` are keyed by the *step index* the capture was
/// emitted for, as the scenario file reads — a scenario may carry several of
/// each, and the index is the only collision-free key.
///
/// When a scenario runs across several browser projects each project attaches
/// its own captures; they merge in reporter order, so the last project's
/// values win for a key every project wrote.
#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
pub struct RunCaptures {
    /// `measure:` latencies in milliseconds, keyed by measure name.
    #[serde(default)]
    pub metrics: BTreeMap<String, f64>,
    /// `judge:` response text, keyed by step index.
    #[serde(default)]
    pub judge: BTreeMap<String, String>,
    /// `cross_surface:` capture text, keyed by step index.
    #[serde(default)]
    pub cross_surface: BTreeMap<String, String>,
    /// Uncaught exceptions the page raised during the run, newest last. The
    /// spec asserts this is empty, so a non-empty value here means the run
    /// already failed — it carries the detail.
    #[serde(default)]
    pub page_errors: Vec<String>,
    /// `<status> <method> <url>` for every failed response to a resource the
    /// page depends on.
    #[serde(default)]
    pub failed_requests: Vec<String>,
    /// The screens an `ios` block left, keyed `start` (before step 0) and by
    /// the block step index each followed. Only `mirroir-mcp test` writes it.
    #[serde(default)]
    pub screens: BTreeMap<String, ScreenFingerprint>,
    /// The mirroring window an `ios` block drove.
    #[serde(default)]
    pub device: Option<DeviceInfo>,
    /// What each `scene:` step of an `ios` block concluded and spent, keyed
    /// by the step's index in the block (its `target:` is `0`), the way
    /// `screens` is. Only `mirroir-mcp test` writes it, and only for a block
    /// that ran a scene.
    #[serde(default)]
    pub scenes: BTreeMap<String, SceneCapture>,
}

impl RunCaptures {
    /// Fold another block's captures in; a key both carry takes `other`'s.
    pub fn merge(&mut self, other: Self) {
        self.metrics.extend(other.metrics);
        self.judge.extend(other.judge);
        self.cross_surface.extend(other.cross_surface);
        self.page_errors.extend(other.page_errors);
        self.failed_requests.extend(other.failed_requests);
        self.screens.extend(other.screens);
        if other.device.is_some() {
            self.device = other.device;
        }
        self.scenes.extend(other.scenes);
    }
}

/// One `scene:` step's report, as `mirroir-mcp test` writes it.
///
/// Written for every verdict: a scene that failed or ran out of budget still
/// says how far it got and what it spent, and where its evidence is.
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SceneCapture {
    /// The kind:game skill the scene ran.
    pub skill: String,
    /// What the scene concluded.
    pub verdict: SceneVerdict,
    /// Why the scene stopped.
    pub reason: SceneReason,
    /// Model calls the scene made.
    pub frames: u32,
    /// Frames it took to see the success predicate; only a passing scene has
    /// one.
    #[serde(default)]
    pub frames_to_predicate: Option<u32>,
    /// Prompt tokens, summed over every frame.
    pub prompt_tokens: u64,
    /// Completion tokens, summed over every frame.
    pub completion_tokens: u64,
    /// Prompt plus completion tokens — the figure `max_tokens` caps.
    pub total_tokens: u64,
    /// Wall-clock seconds the scene ran.
    pub seconds: f64,
    /// The model id the scene's route requested — the drift key, so a scene
    /// is only ever compared with runs of the same model.
    pub model: String,
    /// The model id the API reported answering with, when it reported one.
    #[serde(default)]
    pub response_model: Option<String>,
    /// Replies that named no allowed control; each still cost a frame.
    pub rejected_replies: u32,
    /// Where the scene's per-frame screenshots and replies were written.
    pub evidence_dir: PathBuf,
}

/// What a scene concluded.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SceneVerdict {
    /// The success predicate became visible.
    Pass,
    /// The fail predicate became visible, or the scene could not perceive a
    /// frame, account for its cost, or post its touch.
    Fail,
    /// The budget ran out first: the scene proved neither outcome.
    Inconclusive,
}

/// Why a scene stopped.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SceneReason {
    /// The success predicate became visible.
    Success,
    /// The fail predicate became visible.
    Fail,
    /// `max_frames` model calls were made.
    MaxFrames,
    /// The next frame would have spent past `max_tokens`.
    MaxTokens,
    /// `max_seconds` of wall clock ran out.
    MaxSeconds,
    /// The model's reply carried no token usage, so the budget could not be
    /// kept.
    UsageMissing,
    /// A frame could not be read back from the screen.
    PerceptionFailed,
    /// The touch the model chose could not be posted to the device.
    InputFailed,
}

impl SceneReason {
    /// The reason as the report spells it.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::Fail => "fail",
            Self::MaxFrames => "max_frames",
            Self::MaxTokens => "max_tokens",
            Self::MaxSeconds => "max_seconds",
            Self::UsageMissing => "usage_missing",
            Self::PerceptionFailed => "perception_failed",
            Self::InputFailed => "input_failed",
        }
    }
}

impl fmt::Display for SceneReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use super::{RunCaptures, SceneCapture, SceneReason, SceneVerdict};

    type TestResult = StdResult<(), serde_json::Error>;

    const SCENE: &str = r#"{"completion_tokens":150,"evidence_dir":"\/w\/scene-2","frames":3,"frames_to_predicate":null,"model":"m","prompt_tokens":72000,"reason":"max_frames","rejected_replies":0,"response_model":null,"seconds":12.5,"skill":"s","total_tokens":72150,"verdict":"inconclusive"}"#;

    #[test]
    fn a_scene_report_decodes_with_null_optionals() -> TestResult {
        let scene: SceneCapture = serde_json::from_str(SCENE)?;
        assert_eq!(scene.verdict, SceneVerdict::Inconclusive);
        assert_eq!(scene.reason, SceneReason::MaxFrames);
        assert_eq!(scene.reason.to_string(), "max_frames");
        assert_eq!(scene.frames_to_predicate, None);
        assert_eq!(scene.evidence_dir.to_str(), Some("/w/scene-2"));
        Ok(())
    }

    /// The scene report is a contract with the Swift writer: a key it does
    /// not define, or a reason it does not know, is refused rather than read
    /// past.
    #[test]
    fn an_unknown_key_or_reason_is_refused() {
        let extra = SCENE.replace("\"skill\"", "\"cost\":1,\"skill\"");
        assert!(serde_json::from_str::<SceneCapture>(&extra).is_err());
        let reason = SCENE.replace("max_frames", "max_touches");
        assert!(serde_json::from_str::<SceneCapture>(&reason).is_err());
        let input = SCENE.replace("max_frames", "input_failed");
        assert!(serde_json::from_str::<SceneCapture>(&input).is_ok());
    }

    #[test]
    fn scenes_merge_with_the_rest_of_the_captures() -> TestResult {
        let mut merged = RunCaptures::default();
        let other: RunCaptures = serde_json::from_str(&format!(r#"{{"scenes":{{"2":{SCENE}}}}}"#))?;
        merged.merge(other);
        assert_eq!(merged.scenes.keys().collect::<Vec<_>>(), ["2"]);
        Ok(())
    }
}
