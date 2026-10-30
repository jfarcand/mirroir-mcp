// ABOUTME: The last-green baseline store — what the previous PASS run observed, per scenario.
// ABOUTME: Persisted at `.harness/last-green.json`; drift is measured against it, never against a guess.

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use tracing::info;

use crate::error::{Result, RunnerError};
use crate::oracle::error::OracleError;
use crate::parser::version::{self, ArtifactKind, SchemaVersion};

/// Directory the runner keeps its review artifacts in, relative to the
/// directory `mirroir-run` was invoked from.
pub const HARNESS_DIR: &str = ".harness";

/// Filename of the last-green baseline store inside [`HARNESS_DIR`].
pub const LAST_GREEN_FILE: &str = "last-green.json";

/// Root key of the store's `version`.
const VERSION_KEY: &str = "version";

/// Root key of the store's per-scenario baselines.
const SCENARIOS_KEY: &str = "scenarios";

/// Whether a replay measures itself against the recorded baselines or replaces
/// them with what it observes.
///
/// Every ordinary run is [`Self::Compare`]. `mirroir-run accept` is
/// [`Self::Accept`]: the human has reviewed the drift and is saying "this is
/// correct now", so the run re-records instead of reporting. Without that
/// second mode the DRIFT verdict has no exit — the suite's steady state
/// becomes amber and someone deletes it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum BaselineMode {
    /// Compare observations against the recorded baselines.
    #[default]
    Compare,
    /// Re-record every baseline from what this run observes.
    Accept,
}

/// What one scenario's last PASS run observed.
///
/// Judge scores and response texts are keyed by the judge step's index as the
/// scenario file reads; measure latencies by the `measure:` step's `name`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ScenarioBaseline {
    /// Judge score per judge step index.
    #[serde(default)]
    pub judge_scores: BTreeMap<String, f64>,
    /// Judged response text per judge step index.
    #[serde(default)]
    pub responses: BTreeMap<String, String>,
    /// `measure:` latency in milliseconds per measure name.
    #[serde(default)]
    pub metrics: BTreeMap<String, f64>,
}

impl ScenarioBaseline {
    /// True when the run recorded nothing worth comparing next time.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.judge_scores.is_empty() && self.responses.is_empty() && self.metrics.is_empty()
    }
}

/// The whole `.harness/last-green.json` document.
#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GreenStore {
    /// Schema version, gated by [`ArtifactKind::LastGreen`]. Recording a
    /// baseline writes the newer of this and [`ArtifactKind::current`], so a
    /// store from a newer minor keeps the version its extra keys belong to.
    pub version: SchemaVersion,
    /// Per-scenario baselines, keyed by scenario `name`.
    #[serde(default)]
    pub scenarios: BTreeMap<String, ScenarioBaseline>,
}

/// Absolute path of the baseline store under `root`.
#[must_use]
pub fn store_path(root: &Path) -> PathBuf {
    root.join(HARNESS_DIR).join(LAST_GREEN_FILE)
}

/// Load the baseline recorded for `scenario`, if the store has one.
///
/// An absent store is not an error: the first run of a scenario has nothing to
/// compare against, records what it saw, and reports PASS.
///
/// # Errors
///
/// * [`OracleError::BaselineParse`] when the store exists but can't be read or
///   deserialized.
/// * [`RunnerError::UnsupportedVersion`] when its `version:` major is unsupported.
/// * [`RunnerError::UnknownFields`] for keys the store schema does not define.
pub fn load_baseline(root: &Path, scenario: &str) -> Result<Option<ScenarioBaseline>> {
    let path = store_path(root);
    if !path.is_file() {
        return Ok(None);
    }
    let store = read_store(&path)?;
    Ok(store.scenarios.get(scenario).cloned())
}

/// Record `observed` as `scenario`'s new last-green baseline, merging it into
/// whatever the store already holds for other scenarios.
///
/// The rewrite edits the store's JSON document rather than re-serializing the
/// typed [`GreenStore`]: a store written at a newer minor carries keys this
/// binary does not model, and they survive the rewrite together with the
/// version that defines them. Only `scenarios.<scenario>` is replaced.
///
/// # Errors
///
/// * [`OracleError::BaselineParse`] when an existing store can't be read.
/// * [`RunnerError::Io`] when the store can't be written.
pub fn record_baseline(root: &Path, scenario: &str, observed: &ScenarioBaseline) -> Result<()> {
    if observed.is_empty() {
        return Ok(());
    }
    let path = store_path(root);
    let current = ArtifactKind::LastGreen.current();
    let (version, mut document) = if path.is_file() {
        let (store, document) = read_document(&path)?;
        (store.version.max(current), document)
    } else {
        (current, Map::new())
    };
    // The typed parse in `read_document` proved `scenarios` is absent or an
    // object, so anything else cannot reach this match.
    let mut scenarios = match document.remove(SCENARIOS_KEY) {
        Some(Value::Object(scenarios)) => scenarios,
        _ => Map::new(),
    };
    scenarios.insert(scenario.to_owned(), to_json_value(observed)?);
    document.insert(VERSION_KEY.to_owned(), to_json_value(&version)?);
    document.insert(SCENARIOS_KEY.to_owned(), Value::Object(scenarios));

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| RunnerError::Io {
            context: format!("create {}", parent.display()),
            source,
        })?;
    }
    let json = serde_json::to_string_pretty(&document).map_err(|source| RunnerError::Io {
        context: "serialize the last-green baseline store".to_owned(),
        source: io::Error::other(source.to_string()),
    })?;
    fs::write(&path, json).map_err(|source| RunnerError::Io {
        context: format!("write the last-green baseline at {}", path.display()),
        source,
    })?;
    info!(scenario, path = %path.display(), "recorded the last-green baseline");
    Ok(())
}

fn to_json_value<T: Serialize>(value: &T) -> Result<Value> {
    serde_json::to_value(value).map_err(|source| RunnerError::Io {
        context: "serialize the last-green baseline store".to_owned(),
        source: io::Error::other(source.to_string()),
    })
}

fn read_raw(path: &Path) -> Result<String> {
    Ok(
        fs::read_to_string(path).map_err(|source| OracleError::BaselineParse {
            path: path.to_path_buf(),
            reason: source.to_string(),
        })?,
    )
}

/// The store at `path`, gated and typed, alongside its raw JSON object — the
/// object is what a rewrite edits, so keys the typed shape drops survive.
fn read_document(path: &Path) -> Result<(GreenStore, Map<String, Value>)> {
    let raw = read_raw(path)?;
    let store = parse_store(path, &raw)?;
    let document = serde_json::from_str(&raw).map_err(|source| OracleError::BaselineParse {
        path: path.to_path_buf(),
        reason: source.to_string(),
    })?;
    Ok((store, document))
}

fn read_store(path: &Path) -> Result<GreenStore> {
    parse_store(path, &read_raw(path)?)
}

fn parse_store(path: &Path, raw: &str) -> Result<GreenStore> {
    version::from_json_str(
        ArtifactKind::LastGreen,
        &path.display().to_string(),
        raw,
        |source| {
            OracleError::BaselineParse {
                path: path.to_path_buf(),
                reason: source.to_string(),
            }
            .into()
        },
    )
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use tempfile::tempdir;

    use super::*;

    type TestResult = StdResult<(), String>;

    fn baseline(score: f64, text: &str) -> ScenarioBaseline {
        let mut b = ScenarioBaseline::default();
        b.judge_scores.insert("4".to_owned(), score);
        b.responses.insert("4".to_owned(), text.to_owned());
        b
    }

    #[test]
    fn a_missing_store_yields_no_baseline() -> TestResult {
        let dir = tempdir().map_err(|e| e.to_string())?;
        match load_baseline(dir.path(), "anything") {
            Ok(None) => Ok(()),
            other => Err(format!("expected None, got {other:?}")),
        }
    }

    #[test]
    fn recorded_baselines_round_trip_and_do_not_clobber_each_other() -> TestResult {
        let dir = tempdir().map_err(|e| e.to_string())?;
        record_baseline(dir.path(), "alpha", &baseline(0.9, "the alpha reply"))
            .map_err(|e| format!("record alpha: {e}"))?;
        record_baseline(dir.path(), "beta", &baseline(0.4, "the beta reply"))
            .map_err(|e| format!("record beta: {e}"))?;

        let alpha = load_baseline(dir.path(), "alpha")
            .map_err(|e| format!("load alpha: {e}"))?
            .ok_or("alpha baseline vanished")?;
        if alpha.responses.get("4").map(String::as_str) != Some("the alpha reply") {
            return Err(format!("alpha response wrong: {alpha:?}"));
        }
        let beta = load_baseline(dir.path(), "beta")
            .map_err(|e| format!("load beta: {e}"))?
            .ok_or("beta baseline was clobbered by alpha")?;
        if beta.judge_scores.get("4").copied() != Some(0.4) {
            return Err(format!("beta score wrong: {beta:?}"));
        }
        Ok(())
    }

    #[test]
    fn a_run_that_observed_nothing_writes_no_store() -> TestResult {
        let dir = tempdir().map_err(|e| e.to_string())?;
        record_baseline(dir.path(), "empty", &ScenarioBaseline::default())
            .map_err(|e| format!("record: {e}"))?;
        if store_path(dir.path()).exists() {
            return Err("an empty observation should not create a baseline store".to_owned());
        }
        Ok(())
    }

    #[test]
    fn recording_into_a_newer_minor_store_keeps_its_unknown_keys_and_version() -> TestResult {
        let dir = tempdir().map_err(|e| e.to_string())?;
        let path = store_path(dir.path());
        fs::create_dir_all(path.parent().ok_or("no parent")?).map_err(|e| e.to_string())?;
        let newer = r#"{
            "version": "1.3",
            "retention": {"keep": 5},
            "scenarios": {
                "beta": {"judge_scores": {"4": 0.4}, "flakiness": 0.1}
            }
        }"#;
        fs::write(&path, newer).map_err(|e| e.to_string())?;

        record_baseline(dir.path(), "alpha", &baseline(0.9, "the alpha reply"))
            .map_err(|e| format!("record alpha: {e}"))?;

        let written: Value =
            serde_json::from_str(&fs::read_to_string(&path).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
        if written["version"] != "1.3" {
            return Err(format!("the store's newer minor was lost: {written}"));
        }
        if written["retention"]["keep"] != 5 {
            return Err(format!("an unknown top-level key was dropped: {written}"));
        }
        if written["scenarios"]["beta"]["flakiness"] != 0.1 {
            return Err(format!(
                "another scenario's unknown key was dropped: {written}"
            ));
        }
        let alpha = load_baseline(dir.path(), "alpha")
            .map_err(|e| format!("load alpha: {e}"))?
            .ok_or("alpha baseline was not recorded")?;
        if alpha.judge_scores.get("4").copied() != Some(0.9) {
            return Err(format!("alpha score wrong: {alpha:?}"));
        }
        Ok(())
    }

    #[test]
    fn a_fresh_store_is_written_at_the_current_version() -> TestResult {
        let dir = tempdir().map_err(|e| e.to_string())?;
        record_baseline(dir.path(), "alpha", &baseline(0.9, "the alpha reply"))
            .map_err(|e| format!("record alpha: {e}"))?;
        let written: Value = serde_json::from_str(
            &fs::read_to_string(store_path(dir.path())).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        let expected =
            serde_json::to_value(ArtifactKind::LastGreen.current()).map_err(|e| e.to_string())?;
        if written["version"] != expected {
            return Err(format!("expected version {expected}, got {written}"));
        }
        Ok(())
    }

    #[test]
    fn a_store_from_a_future_schema_is_rejected() -> TestResult {
        let dir = tempdir().map_err(|e| e.to_string())?;
        let path = store_path(dir.path());
        fs::create_dir_all(path.parent().ok_or("no parent")?).map_err(|e| e.to_string())?;
        fs::write(&path, r#"{"version": 99, "scenarios": {}}"#).map_err(|e| e.to_string())?;
        match load_baseline(dir.path(), "x") {
            Err(RunnerError::UnsupportedVersion { found, .. }) if found.major == 99 => Ok(()),
            other => Err(format!("expected UnsupportedVersion, got {other:?}")),
        }
    }
}
