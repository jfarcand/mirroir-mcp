// ABOUTME: Structured errors for a `scene:` step's verdict — failed, inconclusive, or never reported.
// ABOUTME: Converts into RunnerError via #[from]; an inconclusive scene is the one error that exits 66.

use thiserror::Error;

use crate::compile::captures::SceneReason;

/// What a `scene:` step concluded, when it was not a pass.
///
/// Every variant is a failure of the scenario. [`SceneError::Inconclusive`]
/// is told apart from the others because the scene proved nothing either way
/// — its budget ran out first — and a CI lane may want to tell "the game beat
/// the model" from "the model ran out of money".
#[derive(Debug, Error)]
pub enum SceneError {
    /// The scene's budget ran out before either predicate showed.
    #[error(
        "scene step {index} (`{skill}`) is inconclusive: {reason} after {frames} frame(s), {total_tokens} tokens and {seconds:.1}s with `{model}`; neither predicate showed inside the budget"
    )]
    Inconclusive {
        /// Index of the `scene:` step, as the scenario file reads.
        index: usize,
        /// The kind:game skill the scene ran.
        skill: String,
        /// Which budget field ran out.
        reason: SceneReason,
        /// Model calls the scene made.
        frames: u32,
        /// Prompt plus completion tokens the scene spent.
        total_tokens: u64,
        /// Wall-clock seconds the scene ran.
        seconds: f64,
        /// The model the scene's route requested.
        model: String,
    },

    /// The fail predicate showed, or the scene could not perceive a frame or
    /// account for its cost.
    #[error(
        "scene step {index} (`{skill}`) failed: {reason} after {frames} frame(s), {total_tokens} tokens and {seconds:.1}s with `{model}`"
    )]
    Failed {
        /// Index of the `scene:` step, as the scenario file reads.
        index: usize,
        /// The kind:game skill the scene ran.
        skill: String,
        /// Why the scene stopped.
        reason: SceneReason,
        /// Model calls the scene made.
        frames: u32,
        /// Prompt plus completion tokens the scene spent.
        total_tokens: u64,
        /// Wall-clock seconds the scene ran.
        seconds: f64,
        /// The model the scene's route requested.
        model: String,
    },

    /// The block passed, yet its report carries no entry for this scene. A
    /// scene with no verdict proved nothing, so the pass is refused.
    #[error(
        "scene step {index} (`{skill}`) passed its block but mirroir-mcp reported no verdict for it; a scene with no report is not a pass"
    )]
    NotReported {
        /// Index of the `scene:` step, as the scenario file reads.
        index: usize,
        /// The kind:game skill the step names.
        skill: String,
    },
}
