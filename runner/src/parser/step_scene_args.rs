// ABOUTME: Argument types for the `scene:` step — a kind:game skill run frame by frame under a hard budget.
// ABOUTME: Budget fields are required and positive, an optional decider names a non-blank move picker command.

use std::num::{NonZeroU32, NonZeroU64};
use std::path::{Component, Path, PathBuf};

use serde::Deserialize;

use crate::scene_error::SceneError;

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
    /// The move picker mirroir-mcp asks for each frame's action, for a skill
    /// that declares `decider: required`. Only a scenario names one, never a
    /// skill.
    #[serde(default)]
    pub decider: Option<SceneDecider>,
}

/// A move picker command line: a program, then its arguments, split on
/// whitespace by mirroir-mcp with no shell. Never blank.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(try_from = "String")]
pub struct SceneDecider(String);

impl TryFrom<String> for SceneDecider {
    type Error = SceneError;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.trim().is_empty() {
            return Err(SceneError::BlankDecider);
        }
        Ok(Self(value))
    }
}

impl SceneDecider {
    /// The command line with its program made runnable from any directory.
    ///
    /// A program written as a relative path (it holds a `/` and does not
    /// start with one) is joined onto `scenario_dir`, the directory of the
    /// scenario file, with `.` components dropped. An absolute path, and a
    /// bare name the child looks up on `PATH`, are kept. The arguments after
    /// the program are kept exactly as written.
    ///
    /// # Errors
    ///
    /// [`SceneError::DeciderPathNotUtf8`] when the joined path is not UTF-8,
    /// so it cannot be written into the block's text.
    pub fn resolved_against(&self, scenario_dir: &Path) -> Result<String, SceneError> {
        let line = self.0.trim();
        let (program, arguments) = line
            .find(char::is_whitespace)
            .map_or((line, ""), |at| line.split_at(at));
        let path = Path::new(program);
        if !program.contains('/') || path.is_absolute() {
            return Ok(line.to_owned());
        }
        let joined: PathBuf = scenario_dir
            .join(path)
            .components()
            .filter(|component| *component != Component::CurDir)
            .collect();
        let Some(joined) = joined.to_str() else {
            return Err(SceneError::DeciderPathNotUtf8 { path: joined });
        };
        Ok(format!("{joined}{arguments}"))
    }
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

    use std::path::Path;

    use super::{SceneArgs, SceneBudget, SceneDecider};
    use crate::parser::step::SkillStep;
    use crate::scene_error::SceneError;

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
            decider: None,
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

    fn decider(yaml_value: &str) -> StdResult<SceneDecider, Box<dyn StdError>> {
        let step = parse(&format!(
            "scene: {{ skill: s, budget: {{ max_frames: 1, max_tokens: 1, max_seconds: 1 }}, decider: {yaml_value} }}"
        ))?;
        match step {
            SkillStep::Scene(SceneArgs {
                decider: Some(decider),
                ..
            }) => Ok(decider),
            other => Err(format!("no decider parsed: {other:?}").into()),
        }
    }

    #[test]
    fn a_decider_parses_as_written() -> TestResult {
        let parsed = decider("\"./tools/sf.sh --depth 12\"")?;
        assert_eq!(
            parsed,
            SceneDecider::try_from("./tools/sf.sh --depth 12".to_owned())?
        );
        Ok(())
    }

    /// A blank decider names no program; it is refused rather than read as
    /// "no decider", which would run the skill without its move picker.
    #[test]
    fn a_blank_decider_is_refused() -> TestResult {
        for blank in ["\"\"", "\"   \"", "\"\\t\""] {
            match decider(blank) {
                Err(err) if err.to_string().contains("blank") => {}
                other => {
                    return Err(format!("{blank}: expected a blank refusal, got {other:?}").into());
                }
            }
        }
        assert!(matches!(
            SceneDecider::try_from(" ".to_owned()),
            Err(SceneError::BlankDecider)
        ));
        Ok(())
    }

    #[test]
    fn a_relative_program_resolves_against_the_scenario_dir() -> TestResult {
        let dir = Path::new("/work/scenarios");
        let cases = [
            (
                "./tools/sf.sh --depth 12",
                "/work/scenarios/tools/sf.sh --depth 12",
            ),
            ("tools/sf.sh", "/work/scenarios/tools/sf.sh"),
            ("../bin/pick  a\tb", "/work/scenarios/../bin/pick  a\tb"),
            ("  ./sf.sh x  ", "/work/scenarios/sf.sh x"),
        ];
        for (written, expected) in cases {
            let resolved = SceneDecider::try_from(written.to_owned())?.resolved_against(dir)?;
            assert_eq!(resolved, expected, "{written}");
        }
        Ok(())
    }

    #[test]
    fn an_absolute_or_bare_program_is_kept() -> TestResult {
        let dir = Path::new("/work/scenarios");
        for written in [
            "/opt/sf/bin/sf --depth 12",
            "stockfish-pick --depth 12",
            "pick",
        ] {
            let resolved = SceneDecider::try_from(written.to_owned())?.resolved_against(dir)?;
            assert_eq!(resolved, written);
        }
        Ok(())
    }
}
