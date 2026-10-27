// ABOUTME: Scenario top-level YAML structure — the document type emitted by mirroir's recorder.
// ABOUTME: Wraps a version-gated list of SkillStep entries plus optional name/description/tags.

use serde::Deserialize;

use crate::oracle::thresholds::DriftThresholds;
use crate::parser::step::SkillStep;

/// Highest version of the `Scenario` schema this binary understands.
///
/// Major-version mismatch is a hard load error (per the design doc — load-bearing
/// `version: 1` field). Minor versions stay forward-tolerant by adding `#[serde(default)]`
/// to new optional fields rather than bumping the major.
pub const SCHEMA_VERSION: u32 = 1;

/// Top-level shape of a scenario YAML file.
///
/// Mirrors the `name / app / description / tags / steps` keys mirroir emits, plus the
/// `version` integer the runner gates on.
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Scenario {
    /// Schema major version. Currently always `1`.
    pub version: u32,
    /// Human-readable scenario title.
    pub name: String,
    /// Optional app identifier — typically references an `APP.md` filename slug.
    #[serde(default)]
    pub app: Option<String>,
    /// Optional multi-line description.
    #[serde(default)]
    pub description: Option<String>,
    /// Optional tag list used for filtering and reporting.
    #[serde(default)]
    pub tags: Vec<String>,
    /// Optional `drift:` block — the most specific layer of the drift
    /// threshold hierarchy, above the sample's `APP.md` `drift_defaults:` and
    /// the `drift-defaults.yaml` on the search path.
    #[serde(default)]
    pub drift: Option<DriftThresholds>,
    /// Ordered list of steps the runner executes.
    #[serde(with = "serde_norway::with::singleton_map_recursive")]
    pub steps: Vec<SkillStep>,
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;
    use crate::oracle::thresholds::DriftMetric;
    use crate::parser::step::SkillStep;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn fail<T>(reason: String) -> StdResult<T, Box<dyn StdError>> {
        Err(reason.into())
    }

    #[test]
    fn parses_minimal_scenario() -> TestResult {
        let yaml = r#"
version: 1
name: smoke
steps:
  - launch: "App"
"#;
        let scenario: Scenario = serde_norway::from_str(yaml)?;
        assert_eq!(scenario.version, SCHEMA_VERSION);
        assert_eq!(scenario.name, "smoke");
        assert_eq!(scenario.steps.len(), 1);
        let SkillStep::Launch(app) = &scenario.steps[0] else {
            return fail("expected Launch as first step".to_owned());
        };
        assert_eq!(app, "App");
        Ok(())
    }

    /// The scenario layer of the drift hierarchy parses, and a scenario that
    /// declares nothing leaves the layer empty rather than inventing values.
    #[test]
    fn parses_the_scenario_drift_block() -> TestResult {
        let yaml = r"
version: 1
name: drifty
drift:
  fingerprint_similarity: { min: 0.9 }
  response_levenshtein_pct: { max: 0.1 }
steps:
  - report: pass
";
        let scenario: Scenario = serde_norway::from_str(yaml)?;
        let thresholds = scenario.drift.ok_or("drift block was dropped")?;
        assert_eq!(
            thresholds.get(DriftMetric::FingerprintSimilarity),
            Some(0.9)
        );
        assert_eq!(thresholds.get(DriftMetric::JudgeScoreSwing), None);

        let bare: Scenario =
            serde_norway::from_str("version: 1\nname: plain\nsteps:\n  - report: pass\n")?;
        assert!(bare.drift.is_none());
        Ok(())
    }

    #[test]
    fn parses_full_scenario_with_optional_fields() -> TestResult {
        let yaml = r#"
version: 1
name: streaming smoke
app: spring-boot-ai-chat
description: |
  Boot, drive UI, judge reply.
tags: ["smoke", "streaming"]
steps:
  - target: { kind: web, browsers: [chrome], url: "http://localhost:8081/" }
  - wait_for: "Connected"
  - tap: "prompt-input"
  - type: "hello"
  - tap: "send"
"#;
        let scenario: Scenario = serde_norway::from_str(yaml)?;
        assert_eq!(scenario.app.as_deref(), Some("spring-boot-ai-chat"));
        assert_eq!(
            scenario.tags,
            vec!["smoke".to_owned(), "streaming".to_owned()]
        );
        assert_eq!(scenario.steps.len(), 5);
        Ok(())
    }
}
