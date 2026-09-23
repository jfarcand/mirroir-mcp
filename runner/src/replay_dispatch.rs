// ABOUTME: `judge:` and `measure:` post-hook dispatch — resolve the response, score it, feed the drift session.
// ABOUTME: Enforces absolute measure budgets as FAIL and relative growth as DRIFT; they are separate questions.

use std::fs;
use std::path::Path;

use tracing::info;

use crate::compile::report::RunCaptures;
use crate::error::{Result, RunnerError};
use crate::oracle::baseline::BaselineMode;
use crate::oracle::drift_session::DriftSession;
use crate::oracle::error::OracleError;
use crate::oracle::judge::{JudgeRegistry, enforce_threshold, run_judge};
use crate::parser::step::{JudgeArgs, SkillStep};

/// Dispatch a `judge:` step: resolve the response, run the judge registry,
/// enforce the pass threshold, then hand the score and the response to the
/// scenario's drift session for comparison against the last green run.
///
/// The response comes from `response_text`, then `response_file`, then the
/// `mirroir-captures` attachment the scenario's Playwright invocation filed
/// under this step's `index` — the channel that carries `response_selector`
/// text out of the live page.
///
/// A judge score under its threshold is a FAIL and returns here. A score that
/// held while the wording moved is DRIFT: the session records the finding and
/// the step still reports [`crate::replay_step::StepVerdict::Evaluated`], so
/// the scenario's remaining post-hooks — `kill:`, `assert_log_clean:` — still
/// run.
///
/// # Errors
///
/// * [`OracleError::Decode`] when no response source resolved.
/// * [`RunnerError::Io`] when a response or baseline file can't be read.
/// * Any error from judge registry loading, judging, threshold enforcement.
/// * [`OracleError::ThresholdUnspecified`] when a drift comparison is due and
///   no layer of the hierarchy declares that metric's threshold.
pub async fn dispatch_judge(
    index: usize,
    args: &JudgeArgs,
    captures: &RunCaptures,
    drift: &mut DriftSession,
    baselines: BaselineMode,
) -> Result<()> {
    let response = load_response_text(index, args, captures)?;
    let registry = JudgeRegistry::load_from_cwd()?;
    let outcome = run_judge(&registry, args, &response).await?;
    enforce_threshold(&args.profile, args, &outcome)?;
    info!(
        profile = %args.profile,
        score = outcome.score,
        pass_threshold = args.pass_threshold,
        "judge passed"
    );

    // A `drift_baseline_file:` names the text this step drifts from; without
    // one the session compares against `.harness/last-green.json`. Accept turns
    // the read into a write: the file becomes what this run judged, and the
    // diff is the human's to review.
    let explicit_baseline = match (baselines, args.drift_baseline_file.as_deref()) {
        (BaselineMode::Compare, Some(path)) => {
            Some(fs::read_to_string(path).map_err(|source| RunnerError::Io {
                context: format!("read drift baseline {path}"),
                source,
            })?)
        }
        (BaselineMode::Accept, Some(path)) => {
            write_judge_baseline(path, &response)?;
            info!(index, file = %path, bytes = response.len(), "re-recorded the judge drift baseline");
            None
        }
        (_, None) => None,
    };
    drift.observe_judge(
        index,
        outcome.score,
        &response,
        args.response_drift.as_ref().map(|c| c.max_levenshtein_pct),
        explicit_baseline.as_deref(),
    )
}

/// Write `response` to the step's `drift_baseline_file`, creating the parent
/// directory when the scenario names one that does not exist yet.
fn write_judge_baseline(path: &str, response: &str) -> Result<()> {
    let target = Path::new(path);
    if let Some(parent) = target.parent()
        && !parent.as_os_str().is_empty()
    {
        fs::create_dir_all(parent).map_err(|source| RunnerError::Io {
            context: format!("create the drift baseline directory {}", parent.display()),
            source,
        })?;
    }
    fs::write(target, response).map_err(|source| RunnerError::Io {
        context: format!("re-record the drift baseline {path}"),
        source,
    })
}

fn load_response_text(index: usize, args: &JudgeArgs, captures: &RunCaptures) -> Result<String> {
    if let Some(text) = &args.response_text {
        return Ok(text.clone());
    }
    if let Some(path) = &args.response_file {
        return fs::read_to_string(path).map_err(|source| RunnerError::Io {
            context: format!("read judge.response_file {path}"),
            source,
        });
    }
    if let Some(text) = captures.judge.get(&index.to_string()) {
        return Ok(text.clone());
    }
    Err(OracleError::Decode {
        reason: format!(
            "no response source for judge step {index}: set response_text or response_file, or place the step after a web block so `{}` is captured",
            args.response_selector
        ),
    }
    .into())
}

/// Enforce every `measure:` budget in the scenario's web block against the
/// latencies the invocation attached, and feed each timing to the drift
/// session so a latency that crept up against the last green run is reported.
///
/// The absolute budget is a FAIL; the relative increase over the baseline is a
/// DRIFT. They are separate questions and the runner asks both.
///
/// # Errors
///
/// * [`RunnerError::MeasureNotCaptured`] when a `measure:` step recorded no
///   timing — the invocation ran but its metric never reached the attachment.
/// * [`RunnerError::MeasureBudgetExceeded`] when an observed latency is over
///   the step's declared `max_seconds`.
/// * [`OracleError::ThresholdUnspecified`] when a baseline latency exists and
///   no layer declares `step_latency_pct_increase`.
pub fn verify_measures(
    steps: &[SkillStep],
    captures: &RunCaptures,
    drift: &mut DriftSession,
) -> Result<()> {
    for step in steps {
        let SkillStep::Measure(args) = step else {
            continue;
        };
        let Some(&elapsed_ms) = captures.metrics.get(&args.name) else {
            return Err(RunnerError::MeasureNotCaptured {
                name: args.name.clone(),
            });
        };
        let observed_s = elapsed_ms / 1000.0;
        info!(measure = %args.name, observed_s, "measure recorded");
        if let Some(max_seconds) = args.max_seconds
            && observed_s > max_seconds
        {
            return Err(RunnerError::MeasureBudgetExceeded {
                name: args.name.clone(),
                observed_s,
                max_seconds,
            });
        }
        drift.observe_measure(&args.name, elapsed_ms)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use serde_yaml::from_str;

    use super::*;
    use crate::oracle::thresholds::DriftPolicy;
    use crate::parser::step::MeasureArgs;

    type TestResult = StdResult<(), String>;

    /// A session with no baseline: measure budgets are checked, and no drift
    /// comparison is due.
    fn first_run() -> DriftSession {
        DriftSession::new(DriftPolicy::default(), None)
    }

    fn measure(name: &str, max_seconds: Option<f64>) -> SkillStep {
        SkillStep::Measure(MeasureArgs {
            name: name.to_owned(),
            action: "tap:send".to_owned(),
            until: Some("caret".to_owned()),
            max_seconds,
        })
    }

    #[test]
    fn measure_within_budget_passes() -> TestResult {
        let mut captures = RunCaptures::default();
        captures.metrics.insert("first_token".to_owned(), 900.0);
        verify_measures(
            &[measure("first_token", Some(5.0))],
            &captures,
            &mut first_run(),
        )
        .map_err(|e| format!("in-budget measure rejected: {e}"))
    }

    #[test]
    fn measure_over_budget_fails_with_both_numbers() -> TestResult {
        let mut captures = RunCaptures::default();
        captures.metrics.insert("first_token".to_owned(), 7500.0);
        match verify_measures(
            &[measure("first_token", Some(5.0))],
            &captures,
            &mut first_run(),
        ) {
            Err(RunnerError::MeasureBudgetExceeded {
                name,
                observed_s,
                max_seconds,
            }) => {
                if name != "first_token"
                    || (observed_s - 7.5).abs() > f64::EPSILON
                    || (max_seconds - 5.0).abs() > f64::EPSILON
                {
                    return Err(format!("wrong payload: {name} {observed_s} {max_seconds}"));
                }
                Ok(())
            }
            other => Err(format!("expected MeasureBudgetExceeded, got {other:?}")),
        }
    }

    #[test]
    fn measure_with_no_recorded_timing_fails() -> TestResult {
        match verify_measures(
            &[measure("first_token", None)],
            &RunCaptures::default(),
            &mut first_run(),
        ) {
            Err(RunnerError::MeasureNotCaptured { name }) if name == "first_token" => Ok(()),
            other => Err(format!("expected MeasureNotCaptured, got {other:?}")),
        }
    }

    #[test]
    fn judge_response_comes_from_the_attachment_when_no_file_is_set() -> TestResult {
        let args: JudgeArgs = from_str(
            "profile: fast-ci\nuser_prompt_template_hash: \"sha256:abc\"\nresponse_selector: \"[data-test=reply]\"\npass_threshold: 0.9\n",
        )
        .map_err(|e| e.to_string())?;
        let mut captures = RunCaptures::default();
        captures
            .judge
            .insert("6".to_owned(), "the attached reply".to_owned());
        let text = load_response_text(6, &args, &captures).map_err(|e| e.to_string())?;
        if text != "the attached reply" {
            return Err(format!("wrong response text: {text}"));
        }
        // A judge step with no capture and no file names the selector it wanted.
        match load_response_text(6, &args, &RunCaptures::default()) {
            Err(RunnerError::Oracle(OracleError::Decode { reason }))
                if reason.contains("[data-test=reply]") =>
            {
                Ok(())
            }
            other => Err(format!(
                "expected a decode error naming the selector, got {other:?}"
            )),
        }
    }
}
