// ABOUTME: Accumulates one scenario's drift observations and compares them to the last-green baseline.
// ABOUTME: Produces the third verdict — every assertion green, but the semantics moved.

use tracing::info;

use crate::error::Result;
use crate::oracle::baseline::ScenarioBaseline;
use crate::oracle::drift::{Fingerprint, jaccard_similarity, levenshtein_pct};
use crate::oracle::drift_log::DriftFinding;
use crate::oracle::screen_drift::{ScreenCheck, compare_screens};
use crate::oracle::thresholds::{DriftMetric, DriftPolicy};
use crate::verdict::RunVerdict;

/// One scenario's drift accumulator.
///
/// The session is fed as the scenario executes — a judge score here, a measure
/// latency there — and each observation is compared against the same key in
/// the last-green baseline. Observations are always recorded; comparisons only
/// happen where a baseline exists, because a first run has nothing to drift
/// from. At the end the session reports [`RunVerdict::Drift`] when anything
/// moved, and hands back what this run saw so a green run can become the next
/// baseline.
#[derive(Debug)]
pub struct DriftSession {
    policy: DriftPolicy,
    baseline: Option<ScenarioBaseline>,
    observed: ScenarioBaseline,
    findings: Vec<DriftFinding>,
}

impl DriftSession {
    /// Start a session against `baseline` (`None` on a scenario's first run).
    #[must_use]
    pub fn new(policy: DriftPolicy, baseline: Option<ScenarioBaseline>) -> Self {
        Self {
            policy,
            baseline,
            observed: ScenarioBaseline::default(),
            findings: Vec::new(),
        }
    }

    /// Record what a `judge:` step saw and compare it to the baseline.
    ///
    /// `step_levenshtein` is the step's own `response_drift.max_levenshtein_pct`
    /// when it declared one — the innermost layer of the threshold hierarchy.
    /// `explicit_baseline` is the text of `judge.drift_baseline_file` when the
    /// step names one, which takes the place of the store's recorded response.
    ///
    /// # Errors
    ///
    /// [`crate::oracle::error::OracleError::ThresholdUnspecified`] when a
    /// comparison is due and no layer declares that metric's threshold.
    pub fn observe_judge(
        &mut self,
        index: usize,
        score: f64,
        response: &str,
        step_levenshtein: Option<f64>,
        explicit_baseline: Option<&str>,
    ) -> Result<()> {
        let key = index.to_string();
        self.observed.judge_scores.insert(key.clone(), score);
        self.observed
            .responses
            .insert(key.clone(), response.to_owned());

        let recorded = self
            .baseline
            .as_ref()
            .and_then(|b| b.responses.get(&key))
            .cloned();
        if let Some(previous) = explicit_baseline.or(recorded.as_deref()) {
            self.compare_response(index, previous, response, step_levenshtein)?;
        }
        let recorded_score = self
            .baseline
            .as_ref()
            .and_then(|b| b.judge_scores.get(&key))
            .copied();
        if let Some(previous) = recorded_score {
            let swing = (score - previous).abs();
            let threshold = self.policy.resolve(DriftMetric::JudgeScoreSwing, None)?;
            info!(index, swing, threshold, "drift check: judge_score_swing");
            if swing > threshold {
                self.findings.push(DriftFinding::Metric {
                    metric: DriftMetric::JudgeScoreSwing,
                    observed: swing,
                    threshold,
                    detail: format!("judge step {index}: score moved {previous:.3} → {score:.3}"),
                });
            }
        }
        Ok(())
    }

    /// Record what a `measure:` step timed and compare it to the baseline.
    ///
    /// A baseline latency of zero has no percentage increase to compute, so the
    /// observation is recorded and left uncompared.
    ///
    /// # Errors
    ///
    /// [`crate::oracle::error::OracleError::ThresholdUnspecified`] when a
    /// comparison is due and no layer declares `step_latency_pct_increase`.
    pub fn observe_measure(&mut self, name: &str, elapsed_ms: f64) -> Result<()> {
        self.observed.metrics.insert(name.to_owned(), elapsed_ms);
        let Some(&previous) = self.baseline.as_ref().and_then(|b| b.metrics.get(name)) else {
            return Ok(());
        };
        if previous <= 0.0 {
            return Ok(());
        }
        let increase = (elapsed_ms - previous) / previous;
        let threshold = self
            .policy
            .resolve(DriftMetric::StepLatencyPctIncrease, None)?;
        info!(
            measure = name,
            increase, threshold, "drift check: step_latency_pct_increase"
        );
        if increase > threshold {
            self.findings.push(DriftFinding::Metric {
                metric: DriftMetric::StepLatencyPctIncrease,
                observed: increase,
                threshold,
                detail: format!("measure `{name}`: {previous:.0}ms → {elapsed_ms:.0}ms"),
            });
        }
        Ok(())
    }

    /// Compare the screens an `ios` block left against its compiled reference.
    ///
    /// The reference is a file next to the scenario, not a key in the
    /// last-green store, so nothing is added to the observed baseline.
    ///
    /// # Errors
    ///
    /// [`crate::oracle::error::OracleError::ThresholdUnspecified`] when a pair
    /// of screens is compared and no layer declares `fingerprint_similarity`.
    pub fn observe_screens(&mut self, check: ScreenCheck<'_>) -> Result<()> {
        let findings = compare_screens(&self.policy, check)?;
        self.findings.extend(findings);
        Ok(())
    }

    /// Record a `- report: drift` step: the scenario author's own verdict.
    pub fn declare(&mut self, scenario: &str) {
        self.findings.push(DriftFinding::Declared {
            detail: format!("scenario `{scenario}` reported the drift verdict"),
        });
    }

    /// Everything that drifted, in observation order.
    #[must_use]
    pub fn findings(&self) -> &[DriftFinding] {
        &self.findings
    }

    /// The verdict the accumulated findings imply.
    #[must_use]
    pub fn verdict(&self) -> RunVerdict {
        if self.findings.is_empty() {
            RunVerdict::Pass
        } else {
            RunVerdict::Drift
        }
    }

    /// What this run observed, for recording as the next baseline.
    #[must_use]
    pub fn into_observed(self) -> ScenarioBaseline {
        self.observed
    }

    fn compare_response(
        &mut self,
        index: usize,
        previous: &str,
        current: &str,
        step_levenshtein: Option<f64>,
    ) -> Result<()> {
        let similarity = jaccard_similarity(&Fingerprint::of(previous), &Fingerprint::of(current));
        let floor = self
            .policy
            .resolve(DriftMetric::FingerprintSimilarity, None)?;
        info!(
            index,
            similarity, floor, "drift check: fingerprint_similarity"
        );
        if similarity < floor {
            self.findings.push(DriftFinding::Metric {
                metric: DriftMetric::FingerprintSimilarity,
                observed: similarity,
                threshold: floor,
                detail: format!("judge step {index}: the response's token set moved"),
            });
        }

        let distance = levenshtein_pct(previous, current);
        let ceiling = self
            .policy
            .resolve(DriftMetric::ResponseLevenshteinPct, step_levenshtein)?;
        info!(
            index,
            distance, ceiling, "drift check: response_levenshtein_pct"
        );
        if distance > ceiling {
            self.findings.push(DriftFinding::Metric {
                metric: DriftMetric::ResponseLevenshteinPct,
                observed: distance,
                threshold: ceiling,
                detail: format!("judge step {index}: the response text was reworded"),
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use super::*;
    use crate::error::RunnerError;
    use crate::oracle::error::OracleError;
    use crate::oracle::thresholds::{
        DriftThresholds, MaxDeltaThreshold, MaxThreshold, MinThreshold,
    };

    type TestResult = StdResult<(), String>;

    fn full_policy() -> DriftPolicy {
        DriftPolicy::new(
            None,
            None,
            Some(DriftThresholds {
                fingerprint_similarity: Some(MinThreshold { min: 0.85 }),
                judge_score_swing: Some(MaxDeltaThreshold { max_delta: 0.10 }),
                response_levenshtein_pct: Some(MaxThreshold { max: 0.25 }),
                step_latency_pct_increase: Some(MaxThreshold { max: 0.30 }),
            }),
        )
    }

    fn baseline(response: &str, score: f64) -> ScenarioBaseline {
        let mut b = ScenarioBaseline::default();
        b.responses.insert("3".to_owned(), response.to_owned());
        b.judge_scores.insert("3".to_owned(), score);
        b
    }

    /// The wedge: the assertion is green, the judge still scores it a pass, and
    /// the wording moved. That is DRIFT, not PASS and not FAIL.
    #[test]
    fn reworded_response_at_the_same_score_is_drift() -> TestResult {
        let mut session = DriftSession::new(
            full_policy(),
            Some(baseline("Your order has been placed.", 0.95)),
        );
        session
            .observe_judge(
                3,
                0.95,
                "We have received your purchase request, chief.",
                None,
                None,
            )
            .map_err(|e| format!("observe: {e}"))?;
        if session.verdict() != RunVerdict::Drift {
            return Err(format!("expected Drift, got {:?}", session.verdict()));
        }
        let metrics: Vec<&'static str> = session
            .findings()
            .iter()
            .map(DriftFinding::metric_label)
            .collect();
        if !metrics.contains(&"response_levenshtein_pct") {
            return Err(format!("levenshtein did not trip: {metrics:?}"));
        }
        Ok(())
    }

    /// Byte-identical output at the same score is not drift, and the run is
    /// recorded as the next baseline.
    #[test]
    fn an_identical_response_is_a_pass() -> TestResult {
        let mut session = DriftSession::new(
            full_policy(),
            Some(baseline("Your order has been placed.", 0.95)),
        );
        session
            .observe_judge(3, 0.95, "Your order has been placed.", None, None)
            .map_err(|e| format!("observe: {e}"))?;
        if session.verdict() != RunVerdict::Pass {
            return Err(format!("expected Pass, got {:?}", session.findings()));
        }
        let observed = session.into_observed();
        if observed.responses.get("3").map(String::as_str) != Some("Your order has been placed.") {
            return Err("the run was not recorded for the next baseline".to_owned());
        }
        Ok(())
    }

    /// A first run has nothing to compare against, so no threshold is needed
    /// and no drift can be reported — even with an empty policy.
    #[test]
    fn a_first_run_needs_no_thresholds() -> TestResult {
        let mut session = DriftSession::new(DriftPolicy::default(), None);
        session
            .observe_judge(3, 0.95, "anything at all", None, None)
            .map_err(|e| format!("a first run must not need a threshold: {e}"))?;
        session
            .observe_measure("first_token", 900.0)
            .map_err(|e| format!("a first measure must not need a threshold: {e}"))?;
        if session.verdict() != RunVerdict::Pass {
            return Err("a first run cannot drift".to_owned());
        }
        Ok(())
    }

    /// Fail-closed: with a baseline in hand and no layer declaring the metric,
    /// the runner refuses by name rather than guessing a ceiling.
    #[test]
    fn a_comparison_with_no_threshold_anywhere_errors_by_metric_name() -> TestResult {
        let mut session =
            DriftSession::new(DriftPolicy::default(), Some(baseline("the reply", 0.9)));
        match session.observe_judge(3, 0.9, "a different reply", None, None) {
            Err(RunnerError::Oracle(OracleError::ThresholdUnspecified { metric })) => {
                if metric.key() != "fingerprint_similarity" {
                    return Err(format!("wrong metric named: {metric}"));
                }
                Ok(())
            }
            other => Err(format!("expected ThresholdUnspecified, got {other:?}")),
        }
    }

    /// The step's own `response_drift.max_levenshtein_pct` outranks every
    /// scenario / APP.md / global layer.
    #[test]
    fn a_step_threshold_outranks_the_layers() -> TestResult {
        let mut session = DriftSession::new(
            full_policy(),
            Some(baseline("Your order has been placed.", 0.95)),
        );
        session
            .observe_judge(
                3,
                0.95,
                "We have received your purchase request, chief.",
                Some(1.0),
                None,
            )
            .map_err(|e| format!("observe: {e}"))?;
        if session
            .findings()
            .iter()
            .any(|f| f.metric_label() == "response_levenshtein_pct")
        {
            return Err("the step's own ceiling of 1.0 was ignored".to_owned());
        }
        Ok(())
    }

    /// A latency that grows past the resolved ceiling drifts; the same latency
    /// twice does not.
    #[test]
    fn latency_growth_past_the_ceiling_is_drift() -> TestResult {
        let mut previous = ScenarioBaseline::default();
        previous.metrics.insert("first_token".to_owned(), 1000.0);
        let mut session = DriftSession::new(full_policy(), Some(previous.clone()));
        session
            .observe_measure("first_token", 1200.0)
            .map_err(|e| e.to_string())?;
        if session.verdict() != RunVerdict::Pass {
            return Err("a 20% increase is inside the 30% ceiling".to_owned());
        }

        let mut session = DriftSession::new(full_policy(), Some(previous));
        session
            .observe_measure("first_token", 1800.0)
            .map_err(|e| e.to_string())?;
        if session.verdict() != RunVerdict::Drift {
            return Err("an 80% increase must drift".to_owned());
        }
        Ok(())
    }

    /// A judge whose score swings past `max_delta` drifts even when the words
    /// barely moved.
    #[test]
    fn a_score_swing_past_max_delta_is_drift() -> TestResult {
        let mut session = DriftSession::new(
            full_policy(),
            Some(baseline("Your order has been placed.", 0.95)),
        );
        session
            .observe_judge(3, 0.60, "Your order has been placed.", None, None)
            .map_err(|e| e.to_string())?;
        let metrics: Vec<&'static str> = session
            .findings()
            .iter()
            .map(DriftFinding::metric_label)
            .collect();
        if metrics != vec!["judge_score_swing"] {
            return Err(format!("expected only a score swing, got {metrics:?}"));
        }
        Ok(())
    }
}
