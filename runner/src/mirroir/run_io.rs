// ABOUTME: I/O helpers for run_mirroir — config + local-override loading and run-summary JSON emission.
// ABOUTME: Keeps the orchestrator file lean; these helpers touch the filesystem and the summary schema.

use std::env as std_env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{Result, RunnerError};
use crate::mirroir::discover::{LOCAL_OVERRIDES_FILE, MIRROIR_DIR};
use crate::mirroir::error::MirroirError;
use crate::parser::local_overrides::{apply_overrides, parse_local_overrides};
use crate::parser::mirroir::{MirroirConfig, parse_mirroir_config};
pub use crate::verdict::SampleStatus;

/// Schema version of the run summary JSON.
///
/// Bumped to 2 when the verdict gained its third state: `samples[].verdict`
/// can now read `"drift"`, and `totals` carries a `drifted` count.
pub const SUMMARY_SCHEMA_VERSION: u32 = 2;

/// Per-sample outcome line in the summary JSON.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SampleVerdict {
    /// Plan entry name.
    pub name: String,
    /// `pass` / `fail` / `drift` / `skipped` / `composed`.
    pub verdict: SampleStatus,
    /// Optional message explaining the verdict: failure detail, drift note, or
    /// why an entry the plan declares never ran.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Top-level summary written to `--report` (`mirroir-run-report.json` by default).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunSummary {
    /// Schema version of this summary JSON.
    pub version: u32,
    /// Absolute path to the `.mirroir/mirroir.yaml` that was loaded.
    pub config_path: PathBuf,
    /// Generation timestamp.
    pub generated_at: DateTime<Utc>,
    /// Per-sample outcomes in plan order.
    pub samples: Vec<SampleVerdict>,
    /// Aggregate counts.
    pub totals: RunTotals,
}

/// Aggregate counts for [`RunSummary`].
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct RunTotals {
    /// Samples discovered in the plan.
    pub samples: usize,
    /// Samples whose every scenario passed with nothing drifting.
    pub passed: usize,
    /// Samples whose `run_sample` returned `Err`.
    pub failed: usize,
    /// Samples that held structurally but whose semantics moved.
    pub drifted: usize,
    /// Samples that never ran: the plan entry declared `skip: true`, or the
    /// scenario set in effect did not select it.
    pub skipped: usize,
}

/// Read + parse the `mirroir.yaml` at `config_path`.
///
/// # Errors
///
/// * [`RunnerError::Io`] when the file can't be read.
/// * Anything [`parse_mirroir_config`] returns.
pub fn load_config(config_path: &Path) -> Result<MirroirConfig> {
    let raw = fs::read_to_string(config_path).map_err(|source| RunnerError::Io {
        context: format!("read mirroir.yaml at {}", config_path.display()),
        source,
    })?;
    parse_mirroir_config(&config_path.display().to_string(), &raw)
}

/// Derive the project root from the config path.
///
/// `config_path` is `<root>/.mirroir/mirroir.yaml`; the project root is the
/// parent's parent.
///
/// # Errors
///
/// [`MirroirError::ConfigNotFound`] when the path has too few components.
pub fn project_root_for_config(config_path: &Path) -> Result<PathBuf> {
    // config_path is `<root>/.mirroir/mirroir.yaml`; project root is the parent's parent.
    config_path
        .parent() // .mirroir/
        .and_then(Path::parent) // <root>
        .map(Path::to_path_buf)
        .ok_or_else(|| {
            RunnerError::Mirroir(MirroirError::ConfigNotFound {
                searched_from: config_path.to_path_buf(),
            })
        })
}

/// Load `mirroir.local.yaml` (if present) and apply its overrides to `config`.
///
/// # Errors
///
/// * [`RunnerError::Io`] when the overrides file can't be read.
/// * Anything [`parse_local_overrides`] / [`apply_overrides`] returns.
pub fn load_and_apply_local_overrides(
    project_root: &Path,
    config: &mut MirroirConfig,
) -> Result<()> {
    let path = project_root.join(MIRROIR_DIR).join(LOCAL_OVERRIDES_FILE);
    if !path.is_file() {
        return Ok(());
    }
    let raw = fs::read_to_string(&path).map_err(|source| RunnerError::Io {
        context: format!("read local overrides at {}", path.display()),
        source,
    })?;
    let overrides = parse_local_overrides(&path.display().to_string(), &raw)?;
    apply_overrides(config, overrides)
}

/// Resolve the user's home root from `$HOME`.
///
/// # Errors
///
/// [`MirroirError::HomeDirUnavailable`] when `$HOME` is unset.
pub fn resolve_home_root() -> Result<PathBuf> {
    std_env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or(RunnerError::Mirroir(MirroirError::HomeDirUnavailable))
}

/// Write the full run-summary JSON with explicit pass/fail/drift/skip counts.
///
/// # Errors
///
/// [`RunnerError::Io`] when serialization or the write fails.
pub fn write_summary_full(
    path: &Path,
    config_path: &Path,
    verdicts: Vec<SampleVerdict>,
    totals: RunTotals,
) -> Result<()> {
    let total = verdicts.len();
    let summary = RunSummary {
        version: SUMMARY_SCHEMA_VERSION,
        config_path: config_path.to_path_buf(),
        generated_at: Utc::now(),
        samples: verdicts,
        totals: RunTotals {
            samples: total,
            ..totals
        },
    };
    let json = serde_json::to_string_pretty(&summary).map_err(|source| RunnerError::Io {
        context: "serialize mirroir summary".to_owned(),
        source: io::Error::other(source.to_string()),
    })?;
    fs::write(path, json).map_err(|source| RunnerError::Io {
        context: format!("write summary at {}", path.display()),
        source,
    })
}

#[cfg(test)]
mod tests {
    use std::fs as std_fs;
    use std::result::Result as StdResult;

    use tempfile::tempdir;

    use super::{RunSummary, RunTotals, SampleStatus, SampleVerdict, write_summary_full};
    use crate::compile::report::parse_report_body;
    use crate::compile::report_error::ReportEngine;
    use crate::error::RunnerError;

    type TestResult = StdResult<(), String>;

    /// The Playwright JSON reporter a failing strict-mode locator produces.
    const STRICT_MODE_REPORT: &str =
        include_str!("../compile/fixtures/playwright-strict-mode.json");

    /// The locator text Playwright produced must survive every hop to the run
    /// summary a CI lane reads: reporter JSON → `ReportError::TestFailures`
    /// → the sample's first scenario failure → `samples[].error`. A bare count
    /// at any hop makes the artifact useless for diagnosis.
    #[test]
    fn a_strict_mode_violation_reaches_samples_error_in_the_summary() -> TestResult {
        let Err(playwright) = parse_report_body(
            ReportEngine::Playwright,
            "playwright-report.json",
            STRICT_MODE_REPORT,
        ) else {
            return Err("the canned report should have parsed as a failure".to_owned());
        };
        // `run_sample` records the first failing scenario's message verbatim.
        let sample_failure = RunnerError::SampleScenarioFailures {
            failed: 1,
            total: 1,
            first_error: format!("scenarios/checkout.yaml: {playwright}"),
        };
        // `run_mirroir` writes that message into the plan entry's verdict.
        let verdict = SampleVerdict {
            name: "checkout".to_owned(),
            verdict: SampleStatus::Fail,
            error: Some(sample_failure.to_string()),
        };

        let dir = tempdir().map_err(|e| format!("tempdir: {e}"))?;
        let summary_path = dir.path().join("mirroir-run-report.json");
        write_summary_full(
            &summary_path,
            &dir.path().join(".mirroir").join("mirroir.yaml"),
            vec![verdict],
            RunTotals {
                failed: 1,
                ..RunTotals::default()
            },
        )
        .map_err(|e| format!("write summary: {e}"))?;

        let raw = std_fs::read_to_string(&summary_path).map_err(|e| format!("read: {e}"))?;
        let summary: RunSummary =
            serde_json::from_str(&raw).map_err(|e| format!("parse summary: {e}"))?;
        if summary.version != super::SUMMARY_SCHEMA_VERSION {
            return Err(format!(
                "summary schema version drifted: {}",
                summary.version
            ));
        }
        let Some(sample) = summary.samples.first() else {
            return Err("summary carried no samples".to_owned());
        };
        let Some(error) = sample.error.as_deref() else {
            return Err("samples[0].error is null".to_owned());
        };
        if !error.contains("strict mode violation: resolved to 3 elements") {
            return Err(format!(
                "locator text lost on the way to the summary: {error}"
            ));
        }
        if !error.contains("web-fixture — order button resolves uniquely") {
            return Err(format!("failing test title lost: {error}"));
        }
        Ok(())
    }
}
