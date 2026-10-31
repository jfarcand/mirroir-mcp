// ABOUTME: Appends drift candidates to `.harness/drift-log.md` — the row a human reviews.
// ABOUTME: One row per metric that moved past its resolved threshold while every assertion stayed green.

use std::fmt::Write as _;
use std::fs::{self, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};

use chrono::Utc;
use tracing::info;

use crate::error::{Result, RunnerError};
use crate::oracle::baseline::HARNESS_DIR;
use crate::oracle::thresholds::DriftMetric;

/// Filename of the drift log inside `.harness/`.
pub const DRIFT_LOG_FILE: &str = "drift-log.md";

/// Header written once, when the log is first created.
const DRIFT_LOG_HEADER: &str = "# Drift log

Candidates appended by `mirroir-run`. Each row is one metric that moved past its
resolved threshold while every structural assertion stayed green — the run is a
DRIFT verdict, not a FAIL. Review each row and either update the contract
(`SAMPLE.md` / `APP.md` / the scenario) when the change was intended, or open a
regression issue when it was not.

| Observed at | Scenario | Metric | Observed | Threshold | Detail |
|---|---|---|---|---|---|
";

/// Delete the drift log, if one exists.
///
/// The log is a review queue: one row per candidate a human still has to rule
/// on. `mirroir-run accept` is that ruling, so the queue it just answered is
/// removed rather than left to accumulate rows nobody will read again.
///
/// # Errors
///
/// [`RunnerError::Io`] when the file exists and cannot be removed.
pub fn clear_drift_log(root: &Path) -> Result<()> {
    let path = log_path(root);
    if !path.is_file() {
        return Ok(());
    }
    fs::remove_file(&path).map_err(|source| RunnerError::Io {
        context: format!("clear the drift log at {}", path.display()),
        source,
    })?;
    info!(path = %path.display(), "cleared the reviewed drift candidates");
    Ok(())
}

/// One reason a run earned the DRIFT verdict.
///
/// A measured metric carries the observation and the threshold it crossed. A
/// scenario's own `- report: drift` carries neither — there is no measurement
/// behind it — and the log renders those cells as `n/a` rather than printing a
/// zero that reads like a reading.
#[derive(Debug, Clone, PartialEq)]
pub enum DriftFinding {
    /// A metric moved past the threshold the hierarchy resolved for it.
    Metric {
        /// Which metric moved.
        metric: DriftMetric,
        /// The value this run observed.
        observed: f64,
        /// The threshold that was crossed.
        threshold: f64,
        /// Where in the scenario the drift was seen, in prose.
        detail: String,
    },
    /// The scenario declared the verdict itself via `- report: drift`.
    Declared {
        /// Why the scenario says it drifted.
        detail: String,
    },
    /// The compiled screen reference and this run cannot be paired: no
    /// similarity was measured, and the gap itself is the finding.
    Reference {
        /// Which pairing failed.
        gap: ReferenceGap,
        /// Which screen or file, in prose.
        detail: String,
    },
}

/// Why an `ios` block's screens could not be compared to its compiled reference.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReferenceGap {
    /// The reference recorded a screen this run did not observe.
    ScreenUnobserved,
    /// This run observed a screen the reference never recorded.
    ScreenUnreferenced,
    /// The scenario file changed since the reference was recorded.
    SourceChanged,
    /// The screens were read in a window of another size or orientation
    /// than the one the reference was recorded in.
    DeviceChanged,
}

impl ReferenceGap {
    /// The metric column's text.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::ScreenUnobserved => "screen_unobserved",
            Self::ScreenUnreferenced => "screen_unreferenced",
            Self::SourceChanged => "compiled_source_changed",
            Self::DeviceChanged => "compiled_device_changed",
        }
    }
}

impl DriftFinding {
    /// The metric column's text.
    #[must_use]
    pub fn metric_label(&self) -> &'static str {
        match self {
            Self::Metric { metric, .. } => metric.key(),
            Self::Declared { .. } => "declared",
            Self::Reference { gap, .. } => gap.label(),
        }
    }

    /// The observed / threshold columns' text.
    fn measurement_cells(&self) -> (String, String) {
        match self {
            Self::Metric {
                observed,
                threshold,
                ..
            } => (format!("{observed:.3}"), format!("{threshold:.3}")),
            Self::Declared { .. } | Self::Reference { .. } => ("n/a".to_owned(), "n/a".to_owned()),
        }
    }

    /// The prose column's text.
    #[must_use]
    pub fn detail(&self) -> &str {
        match self {
            Self::Metric { detail, .. }
            | Self::Declared { detail }
            | Self::Reference { detail, .. } => detail,
        }
    }

    /// One-line summary for logs and the run summary's `error` field.
    #[must_use]
    pub fn summary(&self) -> String {
        let (observed, threshold) = self.measurement_cells();
        format!(
            "{label} {observed} vs threshold {threshold} ({detail})",
            label = self.metric_label(),
            detail = self.detail()
        )
    }
}

/// Absolute path of the drift log under `root`.
#[must_use]
pub fn log_path(root: &Path) -> PathBuf {
    root.join(HARNESS_DIR).join(DRIFT_LOG_FILE)
}

/// Append one markdown row per finding to `<root>/.harness/drift-log.md`,
/// creating the file with its header when it does not exist yet.
///
/// # Errors
///
/// [`RunnerError::Io`] when the directory can't be created or the log can't be
/// opened or written.
pub fn append_findings(root: &Path, scenario: &str, findings: &[DriftFinding]) -> Result<()> {
    if findings.is_empty() {
        return Ok(());
    }
    let path = log_path(root);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| RunnerError::Io {
            context: format!("create {}", parent.display()),
            source,
        })?;
    }
    let fresh = !path.is_file();
    let mut rows = String::new();
    if fresh {
        rows.push_str(DRIFT_LOG_HEADER);
    }
    let observed_at = Utc::now().to_rfc3339();
    for finding in findings {
        let (observed, threshold) = finding.measurement_cells();
        writeln!(
            rows,
            "| {observed_at} | {scenario} | {metric} | {observed} | {threshold} | {detail} |",
            scenario = escape_cell(scenario),
            metric = finding.metric_label(),
            detail = escape_cell(finding.detail())
        )?;
    }

    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|source| RunnerError::Io {
            context: format!("open the drift log at {}", path.display()),
            source,
        })?;
    file.write_all(rows.as_bytes())
        .map_err(|source| RunnerError::Io {
            context: format!("append to the drift log at {}", path.display()),
            source,
        })?;
    info!(
        path = %path.display(),
        scenario,
        rows = findings.len(),
        "appended drift candidates"
    );
    Ok(())
}

/// Keep a value that may contain `|` or a newline from breaking the table.
fn escape_cell(value: &str) -> String {
    value.replace('|', "\\|").replace(['\n', '\r'], " ")
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use tempfile::tempdir;

    use super::*;

    type TestResult = StdResult<(), String>;

    fn finding() -> DriftFinding {
        DriftFinding::Metric {
            metric: DriftMetric::ResponseLevenshteinPct,
            observed: 0.412,
            threshold: 0.25,
            detail: "judge step 4 | the reply was reworded".to_owned(),
        }
    }

    #[test]
    fn the_first_append_writes_the_header_and_later_ones_do_not() -> TestResult {
        let dir = tempdir().map_err(|e| e.to_string())?;
        append_findings(dir.path(), "alpha", &[finding()]).map_err(|e| e.to_string())?;
        append_findings(dir.path(), "beta", &[finding()]).map_err(|e| e.to_string())?;
        let body = fs::read_to_string(log_path(dir.path())).map_err(|e| e.to_string())?;
        if body.matches("# Drift log").count() != 1 {
            return Err(format!("header written more than once:\n{body}"));
        }
        if body.matches("| response_levenshtein_pct |").count() != 2 {
            return Err(format!("expected two candidate rows:\n{body}"));
        }
        if !body.contains("judge step 4 \\| the reply was reworded") {
            return Err(format!("a pipe in the detail broke the table:\n{body}"));
        }
        Ok(())
    }

    /// A `- report: drift` has no measurement behind it; the log must not
    /// invent one.
    #[test]
    fn a_declared_drift_renders_no_numbers() -> TestResult {
        let dir = tempdir().map_err(|e| e.to_string())?;
        append_findings(
            dir.path(),
            "declared",
            &[DriftFinding::Declared {
                detail: "the scenario reported the drift verdict".to_owned(),
            }],
        )
        .map_err(|e| e.to_string())?;
        let body = fs::read_to_string(log_path(dir.path())).map_err(|e| e.to_string())?;
        if !body.contains("| declared | n/a | n/a |") {
            return Err(format!("declared row rendered numbers:\n{body}"));
        }
        Ok(())
    }

    #[test]
    fn no_findings_writes_no_file() -> TestResult {
        let dir = tempdir().map_err(|e| e.to_string())?;
        append_findings(dir.path(), "alpha", &[]).map_err(|e| e.to_string())?;
        if log_path(dir.path()).exists() {
            return Err("an empty finding list should not create the log".to_owned());
        }
        Ok(())
    }
}
