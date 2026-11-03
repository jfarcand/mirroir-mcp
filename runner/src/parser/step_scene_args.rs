// ABOUTME: Argument types for the `scene:` step — a kind:game skill run frame by frame under a hard budget.
// ABOUTME: Every budget field is required and positive (NonZero types), and an unknown key is refused at parse.

use std::num::{NonZeroU32, NonZeroU64};

use serde::Deserialize;

/// Arguments for `scene`:
/// `- scene: { skill: scene-frames-reach, budget: { max_frames, max_tokens, max_seconds } }`.
///
/// The step only runs inside an `ios` block: `mirroir-mcp test` resolves the
/// skill, drives the vision loop and reports the scene's verdict and cost.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SceneArgs {
    /// Stem of the kind:game skill file to run — no path, no extension.
    pub skill: String,
    /// The ceiling this step grants the scene; mirroir-mcp refuses one larger
    /// than the skill's own.
    pub budget: SceneBudget,
}

/// The hard budget of one `scene:` step. A scene that exhausts any field
/// stops with an inconclusive verdict.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SceneBudget {
    /// `max_frames`: most model calls the scene may make.
    #[serde(rename = "max_frames")]
    pub frames: NonZeroU32,
    /// `max_tokens`: most prompt plus completion tokens across every frame.
    #[serde(rename = "max_tokens")]
    pub tokens: NonZeroU64,
    /// `max_seconds`: most wall-clock seconds the scene may run.
    #[serde(rename = "max_seconds")]
    pub seconds: NonZeroU64,
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::num::{NonZeroU32, NonZeroU64};
    use std::result::Result as StdResult;

    use serde_norway::Deserializer;
    use serde_norway::with::singleton_map_recursive;

    use super::{SceneArgs, SceneBudget};
    use crate::parser::step::SkillStep;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn parse(yaml: &str) -> StdResult<SkillStep, serde_norway::Error> {
        singleton_map_recursive::deserialize(Deserializer::from_str(yaml))
    }

    #[test]
    fn a_scene_parses_its_skill_and_budget() -> TestResult {
        let step = parse(
            "scene: { skill: scene-frames-reach, budget: { max_frames: 6, max_tokens: 150000, max_seconds: 60 } }",
        )?;
        let expected = SkillStep::Scene(SceneArgs {
            skill: "scene-frames-reach".to_owned(),
            budget: SceneBudget {
                frames: NonZeroU32::new(6).ok_or("zero")?,
                tokens: NonZeroU64::new(150_000).ok_or("zero")?,
                seconds: NonZeroU64::new(60).ok_or("zero")?,
            },
        });
        assert_eq!(step, expected);
        Ok(())
    }

    /// `max_touches` is not a budget key; a typo must not leave the scene
    /// running on a budget the author never wrote.
    #[test]
    fn an_unknown_budget_key_is_refused() {
        let err = parse(
            "scene: { skill: s, budget: { max_frames: 6, max_tokens: 1000, max_seconds: 60, max_touches: 3 } }",
        );
        assert!(err.is_err(), "max_touches parsed: {err:?}");
        let err = parse(
            "scene: { skill: s, budget: { max_frames: 6, max_tokens: 1000, max_seconds: 60 }, model: x }",
        );
        assert!(err.is_err(), "an unknown scene key parsed: {err:?}");
    }

    #[test]
    fn a_zero_or_missing_budget_field_is_refused() {
        for yaml in [
            "scene: { skill: s, budget: { max_frames: 0, max_tokens: 1000, max_seconds: 60 } }",
            "scene: { skill: s, budget: { max_frames: 6, max_tokens: 0, max_seconds: 60 } }",
            "scene: { skill: s, budget: { max_frames: 6, max_tokens: 1000, max_seconds: 0 } }",
            "scene: { skill: s, budget: { max_frames: 6, max_tokens: 1000 } }",
            "scene: { skill: s, budget: { max_frames: -1, max_tokens: 1000, max_seconds: 60 } }",
            "scene: { skill: s }",
        ] {
            assert!(parse(yaml).is_err(), "{yaml} parsed");
        }
    }
}
