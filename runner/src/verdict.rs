// ABOUTME: The three verdicts — PASS, FAIL, DRIFT — as types, plus the process exit codes they map to.
// ABOUTME: DRIFT is "every assertion green and the semantics moved"; it has its own code so CI can decide.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::error::RunnerError;
use crate::mirroir::error::MirroirError;
use crate::scene_error::SceneError;

/// Exit code for a run in which every assertion held and nothing drifted.
pub const EXIT_PASS: u8 = 0;

/// Exit code for a run in which something failed: an assertion, a status code,
/// a judge score under its threshold, a dirty log, a runner error.
pub const EXIT_FAIL: u8 = 1;

/// Exit code for the DRIFT verdict: every structural assertion held, but at
/// least one drift metric moved past its resolved threshold. Distinct from
/// [`EXIT_FAIL`] on purpose — a CI lane decides for itself whether a drifted
/// run blocks the merge or only opens a review.
///
/// Chosen from the `sysexits.h` band this runner reserves (64-71);
/// `EX_DATAERR` is the closest classical meaning — the run's data moved.
pub const EXIT_DRIFT: u8 = 65;

/// Exit code for a run whose only failures are inconclusive `scene:` steps:
/// each ran out of budget before either predicate showed, so the run proved
/// neither a pass nor a regression. Distinct from [`EXIT_FAIL`] so a CI lane
/// can tell "the model ran out of budget" from "the app is broken".
///
/// From the same `sysexits.h` band as [`EXIT_DRIFT`]; `EX_NOINPUT`'s slot.
pub const EXIT_INCONCLUSIVE: u8 = 66;

impl RunnerError {
    /// Whether this failure is inconclusive and nothing else: one inconclusive
    /// scene, or an aggregate whose every failure was one.
    #[must_use]
    pub const fn is_inconclusive(&self) -> bool {
        match self {
            Self::Scene(SceneError::Inconclusive { .. }) => true,
            Self::SampleScenarioFailures {
                failed,
                inconclusive,
                ..
            }
            | Self::Mirroir(MirroirError::PlanFailures {
                failed,
                inconclusive,
                ..
            }) => *inconclusive > 0 && *failed == *inconclusive,
            _ => false,
        }
    }

    /// The process exit code for this failure: [`EXIT_INCONCLUSIVE`] when
    /// [`Self::is_inconclusive`], [`EXIT_FAIL`] for everything else.
    #[must_use]
    pub const fn exit_code(&self) -> u8 {
        if self.is_inconclusive() {
            EXIT_INCONCLUSIVE
        } else {
            EXIT_FAIL
        }
    }
}

/// What a scenario, sample, or plan concluded when it did not error out.
///
/// A failure is an `Err(RunnerError)`, never a variant here: this enum only
/// distinguishes the two outcomes a completed run can have.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunVerdict {
    /// Everything asserted held and nothing drifted.
    Pass,
    /// Everything asserted held, and at least one drift metric moved.
    Drift,
}

impl RunVerdict {
    /// The process exit code for this verdict.
    #[must_use]
    pub const fn exit_code(self) -> u8 {
        match self {
            Self::Pass => EXIT_PASS,
            Self::Drift => EXIT_DRIFT,
        }
    }

    /// Combine two verdicts: DRIFT is sticky across an aggregate run.
    #[must_use]
    pub const fn merge(self, other: Self) -> Self {
        match (self, other) {
            (Self::Pass, Self::Pass) => Self::Pass,
            _ => Self::Drift,
        }
    }
}

impl fmt::Display for RunVerdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Pass => "pass",
            Self::Drift => "drift",
        })
    }
}

/// The verdict recorded for one plan entry in the run summary JSON.
///
/// Serializes lowercase, so the strings a consumer's CI already greps for
/// (`"pass"`, `"fail"`, `"skipped"`, `"composed"`) are unchanged; `"drift"` is
/// the new one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SampleStatus {
    /// Every scenario in the sample passed.
    Pass,
    /// At least one scenario failed.
    Fail,
    /// No scenario failed and at least one drifted.
    Drift,
    /// The plan entry never ran: it declared `skip: true`, or the scenario
    /// set in effect did not select it.
    Skipped,
    /// `--compose-only`: the tree was built and nothing was replayed.
    Composed,
}

impl From<RunVerdict> for SampleStatus {
    fn from(verdict: RunVerdict) -> Self {
        match verdict {
            RunVerdict::Pass => Self::Pass,
            RunVerdict::Drift => Self::Drift,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compile::captures::SceneReason;

    #[test]
    fn drift_is_sticky_across_an_aggregate() {
        assert_eq!(RunVerdict::Pass.merge(RunVerdict::Pass), RunVerdict::Pass);
        assert_eq!(RunVerdict::Pass.merge(RunVerdict::Drift), RunVerdict::Drift);
        assert_eq!(RunVerdict::Drift.merge(RunVerdict::Pass), RunVerdict::Drift);
    }

    /// The four outcomes must be distinguishable by exit code alone — a CI
    /// lane that cannot tell DRIFT or INCONCLUSIVE from FAIL has no way to
    /// gate on either.
    #[test]
    fn the_four_outcomes_have_four_distinct_exit_codes() {
        assert_eq!(RunVerdict::Pass.exit_code(), EXIT_PASS);
        assert_eq!(RunVerdict::Drift.exit_code(), EXIT_DRIFT);
        let codes = [EXIT_PASS, EXIT_FAIL, EXIT_DRIFT, EXIT_INCONCLUSIVE];
        for (i, a) in codes.iter().enumerate() {
            for b in &codes[i + 1..] {
                assert_ne!(a, b);
            }
        }
    }

    fn inconclusive_scene() -> RunnerError {
        SceneError::Inconclusive {
            index: 2,
            skill: "s".to_owned(),
            reason: SceneReason::MaxFrames,
            frames: 3,
            total_tokens: 72_150,
            seconds: 12.5,
            model: "m".to_owned(),
        }
        .into()
    }

    #[test]
    fn an_inconclusive_scene_exits_66_and_any_other_failure_exits_1() {
        assert_eq!(inconclusive_scene().exit_code(), EXIT_INCONCLUSIVE);
        let failed = RunnerError::Scene(SceneError::NotReported {
            index: 2,
            skill: "s".to_owned(),
        });
        assert_eq!(failed.exit_code(), EXIT_FAIL);
    }

    /// A sample exits 66 only when every failed scenario was inconclusive;
    /// one other failure beside them makes it a plain failure.
    #[test]
    fn a_sample_is_inconclusive_only_when_every_failure_is() {
        let sample = |failed, inconclusive| RunnerError::SampleScenarioFailures {
            failed,
            inconclusive,
            total: 3,
            first_error: "x".to_owned(),
        };
        assert_eq!(sample(2, 2).exit_code(), EXIT_INCONCLUSIVE);
        assert_eq!(sample(2, 1).exit_code(), EXIT_FAIL);
        assert_eq!(sample(1, 0).exit_code(), EXIT_FAIL);
    }

    #[test]
    fn a_plan_is_inconclusive_only_when_every_failure_is() {
        let plan = |failed, inconclusive| {
            RunnerError::Mirroir(MirroirError::PlanFailures {
                failed,
                inconclusive,
                total: 4,
            })
        };
        assert_eq!(plan(1, 1).exit_code(), EXIT_INCONCLUSIVE);
        assert_eq!(plan(2, 1).exit_code(), EXIT_FAIL);
    }

    #[test]
    fn sample_status_serializes_lowercase() -> Result<(), serde_json::Error> {
        assert_eq!(serde_json::to_string(&SampleStatus::Pass)?, "\"pass\"");
        assert_eq!(serde_json::to_string(&SampleStatus::Fail)?, "\"fail\"");
        assert_eq!(serde_json::to_string(&SampleStatus::Drift)?, "\"drift\"");
        assert_eq!(
            serde_json::to_string(&SampleStatus::Skipped)?,
            "\"skipped\""
        );
        assert_eq!(
            serde_json::to_string(&SampleStatus::Composed)?,
            "\"composed\""
        );
        Ok(())
    }
}
