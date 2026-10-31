// ABOUTME: The compiled-skill schema mirroir-mcp writes (`<scenario>.compiled.json`, version 5) and its loader.
// ABOUTME: Mirrors Swift CompiledSkill.swift field for field (camelCase); the runner reads its screen fingerprints.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{Result, RunnerError};
use crate::oracle::error::OracleError;
use crate::parser::version::{self, ArtifactKind, SchemaVersion};

/// Suffix that replaces a scenario's last extension to name its compiled
/// reference: `world-clock.ios.yaml` → `world-clock.ios.compiled.json`, the
/// same derivation as Swift `CompiledSkillIO.compiledPath(for:)`.
const COMPILED_EXTENSION: &str = "compiled.json";

/// A compiled skill: what one passing run of a skill recorded about the
/// device and the screens each step left on display.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompiledSkill {
    /// Format version, gated by [`ArtifactKind::CompiledSkill`].
    pub version: SchemaVersion,
    /// The source file the skill was recorded from.
    pub source: SourceInfo,
    /// The mirroring window the run drove.
    pub device: DeviceInfo,
    /// One entry per step the recording run executed.
    pub steps: Vec<CompiledStep>,
    /// The screen the skill started from, read before its first step ran.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub screen_fingerprint: Option<ScreenFingerprint>,
}

/// Structural fingerprint of one screen, as Swift `StructuralFingerprint`
/// builds it: sorted structural texts, an icon count, and the hash of both.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScreenFingerprint {
    /// SHA-256 of the sorted structural texts plus the icon count.
    pub hash: String,
    /// Number of icons detected on the screen.
    pub icon_count: i64,
    /// Sorted structural texts, compared as a set when the hashes differ.
    pub structural_texts: Vec<String>,
}

/// Where the compiled skill came from, for staleness detection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceInfo {
    /// Hex SHA-256 of the source file's bytes when it was recorded.
    pub sha256: String,
    /// ISO 8601 time of the recording.
    pub compiled_at: String,
}

/// The mirroring window a run drove.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    /// Window width in points.
    pub window_width: f64,
    /// Window height in points.
    pub window_height: f64,
    /// `portrait` or `landscape`.
    pub orientation: String,
}

/// One recorded step.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompiledStep {
    /// The step's index in the skill file that was run (0-based).
    pub index: usize,
    /// Canonical step type key (`tap`, `wait_for`, `launch`, …).
    #[serde(rename = "type")]
    pub kind: String,
    /// The step's replay value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// Replay hints; absent for an AI-only step that cannot be compiled.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hints: Option<StepHints>,
}

/// What a recording run cached about one step.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StepHints {
    /// How compiled replay performs the step.
    pub compiled_action: CompiledAction,
    /// Cached tap x coordinate.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tap_x: Option<f64>,
    /// Cached tap y coordinate.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tap_y: Option<f64>,
    /// How the tap target was matched.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub match_strategy: Option<String>,
    /// Observed delay before an assertion, in milliseconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observed_delay_ms: Option<i64>,
    /// Number of scroll gestures a scroll sequence replays.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scroll_count: Option<i64>,
    /// Direction of a scroll sequence.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scroll_direction: Option<String>,
    /// The settled screen the step left on display.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arrival_fingerprint: Option<ScreenFingerprint>,
}

/// The action compiled replay takes for a step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompiledAction {
    /// Tap at cached coordinates.
    Tap,
    /// Sleep the observed delay, then assert live.
    Assertion,
    /// Replay a recorded scroll sequence.
    ScrollSequence,
    /// Run the step live.
    Passthrough,
}

impl CompiledSkill {
    /// The arrival fingerprint recorded for the step at `index`, when the
    /// recording run left one.
    #[must_use]
    pub fn arrival(&self, index: usize) -> Option<&ScreenFingerprint> {
        self.steps
            .iter()
            .filter(|step| step.index == index)
            .find_map(|step| step.hints.as_ref()?.arrival_fingerprint.as_ref())
    }
}

/// The compiled reference that sits next to `scenario`.
#[must_use]
pub fn compiled_path(scenario: &Path) -> PathBuf {
    scenario.with_extension(COMPILED_EXTENSION)
}

/// Hex SHA-256 of `bytes`, as Swift `CompiledSkillIO.sha256(of:)` spells it.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// Read and version-gate the compiled skill at `path`.
///
/// # Errors
///
/// * [`RunnerError::Io`] when the file can't be read.
/// * [`OracleError::CompiledParse`] when it is not a compiled skill.
/// * [`RunnerError::UnsupportedVersion`] for a major other than 5.
/// * [`RunnerError::UnknownFields`] for keys the schema does not define.
pub fn load_compiled(path: &Path) -> Result<CompiledSkill> {
    let raw = fs::read_to_string(path).map_err(|source| RunnerError::Io {
        context: format!("read the compiled reference {}", path.display()),
        source,
    })?;
    let label = path.display().to_string();
    version::from_json_str(ArtifactKind::CompiledSkill, &label, &raw, |source| {
        OracleError::CompiledParse {
            path: path.to_path_buf(),
            reason: source.to_string(),
        }
        .into()
    })
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::path::Path;
    use std::result::Result as StdResult;

    use serde_json::Value;
    use tempfile::TempDir;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    /// Byte-exact `mirroir-mcp test --compiled-out` output, regenerated by the
    /// Swift `CompiledDriftContractTests`.
    const FIXTURE: &str =
        include_str!("../../tests/fixtures/compiled/world-clock.ios.compiled.json");

    /// Every number as an `f64`, so `898` written by Swift and `898.0` written
    /// back by serde compare equal.
    fn normalized(value: Value) -> Value {
        match value {
            Value::Number(n) => n.as_f64().map_or(Value::Null, Value::from),
            Value::Array(items) => Value::Array(items.into_iter().map(normalized).collect()),
            Value::Object(map) => {
                Value::Object(map.into_iter().map(|(k, v)| (k, normalized(v))).collect())
            }
            other => other,
        }
    }

    #[test]
    fn the_swift_fixture_round_trips_key_for_key() -> TestResult {
        let dir = TempDir::new()?;
        let path = dir.path().join("world-clock.ios.compiled.json");
        fs::write(&path, FIXTURE)?;
        let compiled = load_compiled(&path)?;
        assert_eq!(compiled.version, SchemaVersion::new(5, 0));
        assert_eq!(compiled.steps.len(), 4);
        let written = serde_json::to_value(&compiled)?;
        let original: Value = serde_json::from_str(FIXTURE)?;
        assert_eq!(normalized(written), normalized(original));
        let tap = compiled
            .arrival(2)
            .ok_or("step 2 has no arrival fingerprint")?;
        assert!(tap.structural_texts.contains(&"Cupertino".to_owned()));
        assert_eq!(
            compiled
                .steps
                .get(2)
                .and_then(|s| s.hints.as_ref())
                .map(|h| h.compiled_action),
            Some(CompiledAction::Passthrough)
        );
        Ok(())
    }

    #[test]
    fn a_major_other_than_five_is_refused() -> TestResult {
        let dir = TempDir::new()?;
        let path = dir.path().join("old.compiled.json");
        fs::write(&path, FIXTURE.replace("\"version\" : 5", "\"version\" : 4"))?;
        match load_compiled(&path) {
            Err(RunnerError::UnsupportedVersion { artifact, .. }) => {
                assert_eq!(artifact, ArtifactKind::CompiledSkill);
                Ok(())
            }
            other => Err(format!("expected UnsupportedVersion, got {other:?}").into()),
        }
    }

    /// At the known minor, a key the schema does not define is a typo.
    #[test]
    fn an_unknown_key_at_the_known_minor_is_refused_by_path() -> TestResult {
        let dir = TempDir::new()?;
        let path = dir.path().join("typo.compiled.json");
        fs::write(
            &path,
            FIXTURE.replace("\"iconCount\" : 0,", "\"iconCount\" : 0, \"iconCont\" : 0,"),
        )?;
        match load_compiled(&path) {
            Err(RunnerError::UnknownFields { artifact, keys, .. }) => {
                assert_eq!(artifact, ArtifactKind::CompiledSkill);
                assert!(keys.iter().all(|k| k.ends_with("iconCont")), "{keys:?}");
                Ok(())
            }
            other => Err(format!("expected UnknownFields, got {other:?}").into()),
        }
    }

    #[test]
    fn the_reference_sits_next_to_the_scenario_with_its_last_extension_replaced() {
        assert_eq!(
            compiled_path(Path::new("apps/clock/world-clock.ios.yaml")),
            Path::new("apps/clock/world-clock.ios.compiled.json")
        );
    }

    #[test]
    fn the_digest_matches_the_one_swift_recorded_for_the_fixture_scenario() {
        let scenario = include_bytes!("../../tests/fixtures/compiled/world-clock.ios.yaml");
        assert_eq!(
            sha256_hex(scenario),
            "25d7b824f0025090b86ffc87e4b696cf26293783963c89af5c23ff2e8cd27d1d"
        );
    }
}
