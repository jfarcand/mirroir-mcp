// ABOUTME: Drift threshold hierarchy — scenario `drift:` → APP.md `drift_defaults:` → drift-defaults.yaml.
// ABOUTME: Fail-closed: a metric no layer declares is an error, never a built-in default value.

use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use tracing::info;

use crate::error::{Result, RunnerError};
use crate::oracle::error::OracleError;
use crate::parser::sample::extract_yaml_block;
use crate::parser::version::{self, ArtifactKind};

/// Filename of the global drift threshold file, at every layer of the search.
pub const DRIFT_DEFAULTS_FILE: &str = "drift-defaults.yaml";

/// The drift metrics the runner compares against a last-green baseline.
///
/// Every metric is resolved through the same three-layer hierarchy and every
/// one of them is fail-closed: see [`DriftPolicy::resolve`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DriftMetric {
    /// Jaccard similarity of the response's token-set fingerprint. A floor:
    /// an observation *below* the resolved value is drift.
    FingerprintSimilarity,
    /// Absolute change in the judge's score against the same baseline. A
    /// ceiling on `|current - baseline|`.
    JudgeScoreSwing,
    /// Normalized Levenshtein distance of the response text. A ceiling.
    ResponseLevenshteinPct,
    /// Fractional increase of a `measure:` latency over its baseline. A
    /// ceiling on `(current - baseline) / baseline`.
    StepLatencyPctIncrease,
}

impl DriftMetric {
    /// The metric's key, spelled exactly as the YAML layers spell it.
    #[must_use]
    pub const fn key(self) -> &'static str {
        match self {
            Self::FingerprintSimilarity => "fingerprint_similarity",
            Self::JudgeScoreSwing => "judge_score_swing",
            Self::ResponseLevenshteinPct => "response_levenshtein_pct",
            Self::StepLatencyPctIncrease => "step_latency_pct_increase",
        }
    }

    /// Every metric, for exhaustive reporting and tests.
    #[must_use]
    pub const fn all() -> [Self; 4] {
        [
            Self::FingerprintSimilarity,
            Self::JudgeScoreSwing,
            Self::ResponseLevenshteinPct,
            Self::StepLatencyPctIncrease,
        ]
    }
}

impl fmt::Display for DriftMetric {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.key())
    }
}

/// A floor threshold — observations below `min` are drift.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq)]
pub struct MinThreshold {
    /// Lowest acceptable observation.
    pub min: f64,
}

/// A ceiling threshold — observations above `max` are drift.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq)]
pub struct MaxThreshold {
    /// Highest acceptable observation.
    pub max: f64,
}

/// A ceiling on absolute change — swings above `max_delta` are drift.
#[derive(Debug, Clone, Copy, Deserialize, PartialEq)]
pub struct MaxDeltaThreshold {
    /// Highest acceptable absolute change from the baseline.
    pub max_delta: f64,
}

/// One layer of the drift threshold hierarchy.
///
/// Every field is optional: a layer declares only the metrics it wants to own
/// and leaves the rest to the layer below it.
#[derive(Debug, Clone, Copy, Default, Deserialize, PartialEq)]
pub struct DriftThresholds {
    /// `fingerprint_similarity: { min: … }`.
    #[serde(default)]
    pub fingerprint_similarity: Option<MinThreshold>,
    /// `judge_score_swing: { max_delta: … }`.
    #[serde(default)]
    pub judge_score_swing: Option<MaxDeltaThreshold>,
    /// `response_levenshtein_pct: { max: … }`.
    #[serde(default)]
    pub response_levenshtein_pct: Option<MaxThreshold>,
    /// `step_latency_pct_increase: { max: … }`.
    #[serde(default)]
    pub step_latency_pct_increase: Option<MaxThreshold>,
}

impl DriftThresholds {
    /// This layer's value for `metric`, if it declares one.
    #[must_use]
    pub fn get(&self, metric: DriftMetric) -> Option<f64> {
        match metric {
            DriftMetric::FingerprintSimilarity => self.fingerprint_similarity.map(|t| t.min),
            DriftMetric::JudgeScoreSwing => self.judge_score_swing.map(|t| t.max_delta),
            DriftMetric::ResponseLevenshteinPct => self.response_levenshtein_pct.map(|t| t.max),
            DriftMetric::StepLatencyPctIncrease => self.step_latency_pct_increase.map(|t| t.max),
        }
    }
}

/// Top-level shape of an `APP.md` frontmatter block, read for its `version:`
/// gate and its `drift_defaults:` key. Every other key an APP.md carries —
/// `app`, `surface`, `archetype`, `url`, `locale` — belongs to other tools, which
/// is why [`ArtifactKind::AppMd`] shares its root.
#[derive(Debug, Clone, Copy, Deserialize)]
struct AppFrontmatter {
    #[serde(default)]
    drift_defaults: Option<DriftThresholds>,
}

/// The resolved three-layer threshold hierarchy for one scenario.
///
/// Precedence, most specific first:
///
/// 1. the scenario YAML's `drift:` block,
/// 2. the sample's `APP.md` `drift_defaults:` block,
/// 3. the `drift-defaults.yaml` found on the search path.
///
/// A step may additionally carry its own value — `judge.response_drift`, for
/// instance — which sits above all three; [`DriftPolicy::resolve`] takes it as
/// an argument rather than a layer, because it is per-step and not per-scenario.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct DriftPolicy {
    scenario: DriftThresholds,
    app: DriftThresholds,
    global: DriftThresholds,
}

impl DriftPolicy {
    /// Assemble the policy from its three layers.
    #[must_use]
    pub fn new(
        scenario: Option<DriftThresholds>,
        app: Option<DriftThresholds>,
        global: Option<DriftThresholds>,
    ) -> Self {
        Self {
            scenario: scenario.unwrap_or_default(),
            app: app.unwrap_or_default(),
            global: global.unwrap_or_default(),
        }
    }

    /// The metrics some layer declares — the ones a comparison can resolve.
    /// Anything absent from this list fails closed at [`Self::resolve`] the
    /// moment a comparison needs it.
    #[must_use]
    pub fn declared_metrics(&self) -> Vec<&'static str> {
        DriftMetric::all()
            .into_iter()
            .filter(|metric| self.resolve(*metric, None).is_ok())
            .map(DriftMetric::key)
            .collect()
    }

    /// Resolve `metric` through step → scenario → APP.md → global.
    ///
    /// # Errors
    ///
    /// [`OracleError::ThresholdUnspecified`] when no layer declares the metric.
    /// There is deliberately no built-in fallback value: a guessed ceiling
    /// silently decides whether a semantic change is reported as DRIFT or
    /// swallowed as a pass, which is the failure mode the hierarchy exists to
    /// prevent.
    pub fn resolve(&self, metric: DriftMetric, step: Option<f64>) -> Result<f64> {
        step.or_else(|| self.scenario.get(metric))
            .or_else(|| self.app.get(metric))
            .or_else(|| self.global.get(metric))
            .ok_or_else(|| OracleError::ThresholdUnspecified { metric }.into())
    }
}

/// Where the loader looks for the layers it does not receive inline.
#[derive(Debug, Clone, Copy, Default)]
pub struct ThresholdSearch<'a> {
    /// The sample directory, when the run has one. Supplies `APP.md` and the
    /// most specific `drift-defaults.yaml` candidate.
    pub sample_dir: Option<&'a Path>,
    /// The `mirroir-skills` checkout, from `--skills` / `MIRROIR_SKILLS`.
    pub skills_root: Option<&'a Path>,
    /// The directory the runner was invoked from.
    pub cwd: Option<&'a Path>,
    /// The user's home directory, from `$HOME`.
    pub home: Option<&'a Path>,
}

impl ThresholdSearch<'_> {
    /// Candidate `drift-defaults.yaml` paths, most specific first.
    fn global_candidates(&self) -> Vec<PathBuf> {
        let mut out = Vec::with_capacity(5);
        if let Some(dir) = self.sample_dir {
            out.push(dir.join(DRIFT_DEFAULTS_FILE));
        }
        if let Some(dir) = self.skills_root {
            out.push(dir.join(DRIFT_DEFAULTS_FILE));
        }
        if let Some(dir) = self.cwd {
            out.push(dir.join(DRIFT_DEFAULTS_FILE));
            out.push(dir.join(".mirroir").join(DRIFT_DEFAULTS_FILE));
        }
        if let Some(dir) = self.home {
            out.push(dir.join(".mirroir").join(DRIFT_DEFAULTS_FILE));
        }
        out
    }
}

/// Build the policy for one scenario: the scenario's own `drift:` block over
/// the sample's `APP.md` over the first `drift-defaults.yaml` on the search path.
///
/// The global layer is required to exist: a run with no `drift-defaults.yaml`
/// at any candidate is refused at load time rather than discovering a missing
/// threshold only once a comparison is due. An absent `APP.md` is not an
/// error — the scenario and global layers cover it.
///
/// # Errors
///
/// * [`OracleError::ThresholdsMissing`] when no `drift-defaults.yaml` candidate
///   exists; the error lists every path searched.
/// * [`OracleError::ThresholdsParse`] when a file that exists cannot be read or
///   deserialized.
///
/// A metric that no layer declares still fails closed at
/// [`DriftPolicy::resolve`].
pub fn load_policy(
    scenario: Option<DriftThresholds>,
    search: &ThresholdSearch<'_>,
) -> Result<DriftPolicy> {
    let mut sources = Vec::new();
    let app = match search.sample_dir {
        Some(dir) => {
            let path = dir.join("APP.md");
            let loaded = load_app_defaults(&path)?;
            if loaded.is_some() {
                sources.push(path);
            }
            loaded
        }
        None => None,
    };

    let candidates = search.global_candidates();
    let Some(found) = candidates.iter().find(|candidate| candidate.is_file()) else {
        return Err(OracleError::ThresholdsMissing {
            searched: candidates,
        }
        .into());
    };
    let global = load_drift_defaults(found)?;
    sources.push(found.clone());

    let policy = DriftPolicy::new(scenario, app, Some(global));
    info!(
        sources = ?sources,
        declared = ?policy.declared_metrics(),
        "resolved drift threshold layers"
    );
    Ok(policy)
}

/// Read one `drift-defaults.yaml`.
///
/// # Errors
///
/// [`OracleError::ThresholdsParse`] when the file can't be read or parsed.
pub fn load_drift_defaults(path: &Path) -> Result<DriftThresholds> {
    let raw = fs::read_to_string(path).map_err(|source| OracleError::ThresholdsParse {
        path: path.to_path_buf(),
        reason: source.to_string(),
    })?;
    parse_drift_defaults(path, &raw)
}

/// Parse a `drift-defaults.yaml` body.
///
/// # Errors
///
/// * [`OracleError::ThresholdsParse`] when the body isn't a threshold document.
/// * [`RunnerError::UnsupportedVersion`] when its `version:` major is unsupported.
/// * [`RunnerError::UnknownFields`] for keys the threshold schema does not define.
pub fn parse_drift_defaults(path: &Path, raw: &str) -> Result<DriftThresholds> {
    // The document root *is* the threshold layer; its `version:` is the
    // seam's, so the typed shape needs no wrapper to hold it.
    version::from_yaml_str(
        ArtifactKind::DriftDefaults,
        &path.display().to_string(),
        raw,
        |source| thresholds_parse(path, &source),
    )
}

fn thresholds_parse(path: &Path, source: &serde_norway::Error) -> RunnerError {
    OracleError::ThresholdsParse {
        path: path.to_path_buf(),
        reason: source.to_string(),
    }
    .into()
}

/// Read an `APP.md`'s `drift_defaults:` block, if the file has one.
///
/// Returns `None` when the file is absent or carries no `drift_defaults:` key.
///
/// # Errors
///
/// [`OracleError::ThresholdsParse`] when the file exists but can't be read or
/// its frontmatter can't be deserialized.
pub fn load_app_defaults(path: &Path) -> Result<Option<DriftThresholds>> {
    if !path.is_file() {
        return Ok(None);
    }
    let raw = fs::read_to_string(path).map_err(|source| OracleError::ThresholdsParse {
        path: path.to_path_buf(),
        reason: source.to_string(),
    })?;
    parse_app_defaults(path, &raw)
}

/// Parse an `APP.md` body for its `drift_defaults:` block.
///
/// # Errors
///
/// * [`OracleError::ThresholdsParse`] when the frontmatter can't be deserialized
///   or carries no `version:`.
/// * [`RunnerError::UnsupportedVersion`] when its `version:` major is unsupported.
/// * [`RunnerError::UnknownFields`] for unknown keys inside `drift_defaults:`.
pub fn parse_app_defaults(path: &Path, markdown: &str) -> Result<Option<DriftThresholds>> {
    let Some(body) = extract_yaml_block(markdown) else {
        return Ok(None);
    };
    let parsed: AppFrontmatter = version::from_yaml_str(
        ArtifactKind::AppMd,
        &path.display().to_string(),
        &body,
        |source| thresholds_parse(path, &source),
    )?;
    Ok(parsed.drift_defaults)
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use tempfile::tempdir;

    use super::*;

    type TestResult = StdResult<(), String>;

    const GLOBAL_LAYER: &str = "version: 1\nfingerprint_similarity: { min: 0.85 }\n";

    #[test]
    fn a_missing_global_layer_is_a_load_error_naming_every_searched_path() -> TestResult {
        let sample = tempdir().map_err(|e| e.to_string())?;
        let cwd = tempdir().map_err(|e| e.to_string())?;
        let home = tempdir().map_err(|e| e.to_string())?;
        let search = ThresholdSearch {
            sample_dir: Some(sample.path()),
            skills_root: None,
            cwd: Some(cwd.path()),
            home: Some(home.path()),
        };
        let err = match load_policy(None, &search) {
            Err(err) => err,
            Ok(policy) => return Err(format!("expected a load error, got {policy:?}")),
        };
        let message = err.to_string();
        if !message.contains("the global layer is required (fail-closed)") {
            return Err(format!("the error did not say fail-closed: {message}"));
        }
        for path in search.global_candidates() {
            let shown = path.display().to_string();
            if !message.contains(&shown) {
                return Err(format!("the error omitted {shown}: {message}"));
            }
        }
        if !matches!(
            err,
            RunnerError::Oracle(OracleError::ThresholdsMissing { ref searched })
                if searched.len() == 4
        ) {
            return Err(format!(
                "expected ThresholdsMissing over 4 paths, got {err:?}"
            ));
        }
        Ok(())
    }

    #[test]
    fn a_present_global_layer_loads_into_the_policy() -> TestResult {
        let cwd = tempdir().map_err(|e| e.to_string())?;
        let mirroir = cwd.path().join(".mirroir");
        fs::create_dir_all(&mirroir).map_err(|e| e.to_string())?;
        fs::write(mirroir.join(DRIFT_DEFAULTS_FILE), GLOBAL_LAYER).map_err(|e| e.to_string())?;
        let search = ThresholdSearch {
            cwd: Some(cwd.path()),
            ..ThresholdSearch::default()
        };
        let policy = load_policy(None, &search).map_err(|e| e.to_string())?;
        let similarity = policy
            .resolve(DriftMetric::FingerprintSimilarity, None)
            .map_err(|e| e.to_string())?;
        if (similarity - 0.85).abs() > f64::EPSILON {
            return Err(format!(
                "expected 0.85 from the global layer, got {similarity}"
            ));
        }
        if policy.resolve(DriftMetric::JudgeScoreSwing, None).is_ok() {
            return Err("a metric the layer omits must still fail closed".to_owned());
        }
        Ok(())
    }
}
