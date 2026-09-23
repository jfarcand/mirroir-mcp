// ABOUTME: Non-web step dispatch — one exhaustive match from SkillStep to its runner-side execution.
// ABOUTME: Returns a StepVerdict so the caller can refuse to pass a scenario that evaluated nothing.

use tracing::info;

use crate::compile::report::RunCaptures;
use crate::error::{Result, RunnerError};
use crate::oracle::baseline::BaselineMode;
use crate::oracle::drift_session::DriftSession;
use crate::parser::step::{ReportArgs, SkillStep};
use crate::parser::step_args::ReportVerdict;
use crate::parser::surface::step_kind;
use crate::replay::SampleContext;
use crate::replay_cross_surface::dispatch_cross_surface;
use crate::replay_dispatch::dispatch_judge;
use crate::replay_sample::resolve_spawn_args;
use crate::target::http::HttpClient;
use crate::target::process::ProcessRegistry;

/// What a dispatched step contributes to the scenario's verdict.
///
/// A scenario that never produces [`StepVerdict::Evaluated`] checked nothing
/// about the system under test, and the runner refuses to call it a pass.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepVerdict {
    /// The runner checked something the scenario asserts.
    Evaluated,
    /// The step ran but asserts nothing on its own — `kill:` teardown, or a
    /// `remember:` note.
    NoVerdict,
    /// The step's kind has no replay dispatch, so it was skipped.
    Skipped,
}

/// Scenario-wide facts a step dispatch needs beyond the step itself.
#[derive(Debug, Clone, Copy)]
pub struct StepDispatch<'a> {
    /// Scenario name — names the scenario in a `report:` failure.
    pub scenario_name: &'a str,
    /// Sample context, used to resolve `spawn: { from: SAMPLE.md }`.
    pub context: Option<SampleContext<'a>>,
    /// True when a session-scoped boot owns the subprocess lifecycle, which
    /// makes a scenario-level `kill:` of the shared id a no-op.
    pub session_shared: bool,
    /// Whether the run compares against its recorded baselines or re-records
    /// them. `judge:` and `cross_surface:` both write a baseline file in
    /// [`BaselineMode::Accept`] instead of reading one.
    pub baselines: BaselineMode,
}

/// Execute one runner-side step and report what it contributed to the verdict.
///
/// The match is exhaustive over [`SkillStep`] on purpose: a new step kind is a
/// compile error here rather than a step the runner quietly walks past.
///
/// `index` is the step's position in the scenario — the key the scenario's
/// Playwright invocation filed `judge:` and `cross_surface:` captures under.
/// `captures` carries those values; it is empty for a pre-hook, since the
/// invocation has not run yet.
///
/// `drift` is the scenario's drift accumulator: `judge:` feeds it every score
/// and response it sees, and `- report: drift` declares a finding on it. Drift
/// is a verdict, not an error, so a drifted step still returns `Ok` and the
/// remaining post-hooks run.
///
/// # Errors
///
/// Any error returned by the dispatched step variants propagates verbatim,
/// plus [`RunnerError::ScenarioReportedFailure`] for `- report: fail` and
/// [`RunnerError::WebStepOutsideBlock`] for a web step, which belongs to the
/// scenario's single Playwright invocation and is never dispatched here.
pub async fn dispatch_step(
    index: usize,
    step: &SkillStep,
    dispatch: &StepDispatch<'_>,
    processes: &mut ProcessRegistry,
    http: &HttpClient,
    captures: &RunCaptures,
    drift: &mut DriftSession,
) -> Result<StepVerdict> {
    match step {
        SkillStep::Spawn(args) => {
            let resolved = resolve_spawn_args(args, dispatch.context.as_ref())?;
            if dispatch.session_shared {
                processes.ensure_spawned(&resolved)?;
            } else {
                processes.spawn(&resolved)?;
            }
            Ok(StepVerdict::Evaluated)
        }
        SkillStep::Kill(args) => {
            if dispatch.session_shared {
                // In session-scoped mode the shared boot stays alive across
                // scenarios; a scenario-level kill: of the boot id is a no-op
                // so individual scenarios stay portable.
                info!(id = %args.id, "kill: skipped (session-shared subprocess)");
            } else {
                processes.kill_process(args).await?;
            }
            Ok(StepVerdict::NoVerdict)
        }
        SkillStep::WaitPort(args) => {
            processes.wait_port(args).await?;
            Ok(StepVerdict::Evaluated)
        }
        SkillStep::AssertLog(args) => {
            processes.assert_log(args).await?;
            Ok(StepVerdict::Evaluated)
        }
        SkillStep::AssertLogClean(args) => {
            processes.assert_log_clean(args).await?;
            Ok(StepVerdict::Evaluated)
        }
        SkillStep::Http(args) => {
            http.dispatch(args).await?;
            Ok(StepVerdict::Evaluated)
        }
        SkillStep::Judge(args) => {
            dispatch_judge(index, args, captures, drift, dispatch.baselines).await?;
            Ok(StepVerdict::Evaluated)
        }
        SkillStep::CrossSurface(args) => {
            dispatch_cross_surface(index, args, captures, dispatch.baselines)?;
            Ok(StepVerdict::Evaluated)
        }
        SkillStep::Report(args) => dispatch_report(dispatch.scenario_name, args, drift),
        // `remember:` is an annotation: it records the author's observation on
        // the run and touches nothing else, so it asserts nothing and is legal
        // at any position — including after the `kill:` that ends the session.
        SkillStep::Remember(note) => {
            info!(index, note = %note, "remember");
            Ok(StepVerdict::NoVerdict)
        }
        // LIMITATION(registre#1): the device-only step kinds (launch, home, shake, reset_app,
        // set_network, condition) have no replay dispatch and are skipped. A scenario
        // that leans on one of them for its only assertion evaluates nothing, and the caller
        // fails it on that ground rather than reporting a pass.
        SkillStep::Launch(_)
        | SkillStep::Home(_)
        | SkillStep::Shake(_)
        | SkillStep::ResetApp(_)
        | SkillStep::SetNetwork(_)
        | SkillStep::Condition(_) => Ok(StepVerdict::Skipped),
        // Web steps belong to the scenario's single Playwright invocation;
        // `ScenarioPlan` routes them there and never here. Listing the kinds
        // explicitly is what makes the match exhaustive — adding a step kind
        // breaks the build here — and reaching this arm means the plan and the
        // dispatcher disagree, which is a failure, not something to walk past.
        SkillStep::Target(_)
        | SkillStep::Tap(_)
        | SkillStep::Type(_)
        | SkillStep::PressKey(_)
        | SkillStep::Swipe(_)
        | SkillStep::WaitFor(_)
        | SkillStep::AssertVisible(_)
        | SkillStep::AssertNotVisible(_)
        | SkillStep::Screenshot(_)
        | SkillStep::OpenUrl(_)
        | SkillStep::ScrollTo(_)
        | SkillStep::LongPress(_)
        | SkillStep::Drag(_)
        | SkillStep::Measure(_) => Err(RunnerError::WebStepOutsideBlock {
            index,
            kind: step_kind(step),
        }),
    }
}

/// Apply a `- report:` step's declared verdict to the scenario.
///
/// `drift` carries the third verdict: `- report: drift` is the author saying
/// the run held structurally and moved semantically, so it lands as a finding
/// on the session rather than as an error that would abort the post-hooks.
fn dispatch_report(
    scenario_name: &str,
    args: &ReportArgs,
    drift: &mut DriftSession,
) -> Result<StepVerdict> {
    match args.verdict {
        ReportVerdict::Pass | ReportVerdict::CrossSurfacePass => {
            info!(
                scenario = scenario_name,
                verdict = ?args.verdict,
                "scenario reported a pass verdict"
            );
            Ok(StepVerdict::Evaluated)
        }
        ReportVerdict::Fail => Err(RunnerError::ScenarioReportedFailure {
            scenario: scenario_name.to_owned(),
        }),
        ReportVerdict::Drift => {
            drift.declare(scenario_name);
            info!(
                scenario = scenario_name,
                "scenario reported the drift verdict"
            );
            Ok(StepVerdict::Evaluated)
        }
    }
}

#[cfg(test)]
mod tests {
    use std::result::Result as StdResult;

    use super::{
        BaselineMode, DriftSession, StepDispatch, StepVerdict, dispatch_report, dispatch_step,
    };
    use crate::compile::report::RunCaptures;
    use crate::error::RunnerError;
    use crate::oracle::thresholds::DriftPolicy;
    use crate::parser::step::{ReportArgs, SkillStep, TapArgs};
    use crate::parser::step_args::ReportVerdict;
    use crate::target::http::HttpClient;
    use crate::target::process::ProcessRegistry;
    use crate::verdict::RunVerdict;

    type TestResult = StdResult<(), String>;

    fn session() -> DriftSession {
        DriftSession::new(DriftPolicy::default(), None)
    }

    /// A web step reaching the runner-side dispatcher means the execution plan
    /// and the dispatcher disagree about who owns it. That is a hard failure,
    /// not a step to walk past.
    #[tokio::test]
    async fn a_web_step_cannot_be_dispatched_outside_the_web_block() -> TestResult {
        let mut processes = ProcessRegistry::default();
        let http = HttpClient::new().map_err(|e| e.to_string())?;
        let dispatch = StepDispatch {
            scenario_name: "s",
            context: None,
            session_shared: false,
            baselines: BaselineMode::Compare,
        };
        let step = SkillStep::Tap(TapArgs::new("Go".to_owned()));
        let res = dispatch_step(
            3,
            &step,
            &dispatch,
            &mut processes,
            &http,
            &RunCaptures::default(),
            &mut session(),
        )
        .await;
        match res {
            Err(RunnerError::WebStepOutsideBlock { index, kind })
                if index == 3 && kind == "tap" =>
            {
                Ok(())
            }
            other => Err(format!("expected WebStepOutsideBlock, got {other:?}")),
        }
    }

    /// A `remember:` after the block reaches this dispatcher, and it must be
    /// recorded rather than refused: it is a note, not browser work. It
    /// asserts nothing, so it carries no verdict of its own — a scenario whose
    /// only step is a note still evaluates nothing.
    #[tokio::test]
    async fn a_remember_dispatches_as_a_note_with_no_verdict() -> TestResult {
        let mut processes = ProcessRegistry::default();
        let http = HttpClient::new().map_err(|e| e.to_string())?;
        let dispatch = StepDispatch {
            scenario_name: "s",
            context: None,
            session_shared: false,
            baselines: BaselineMode::Compare,
        };
        let step = SkillStep::Remember("Verified streaming reply".to_owned());
        let res = dispatch_step(
            5,
            &step,
            &dispatch,
            &mut processes,
            &http,
            &RunCaptures::default(),
            &mut session(),
        )
        .await;
        match res {
            Ok(StepVerdict::NoVerdict) => Ok(()),
            other => Err(format!("expected NoVerdict, got {other:?}")),
        }
    }

    #[test]
    fn report_pass_is_an_evaluated_verdict() -> TestResult {
        for verdict in [ReportVerdict::Pass, ReportVerdict::CrossSurfacePass] {
            match dispatch_report("s", &ReportArgs { verdict }, &mut session()) {
                Ok(StepVerdict::Evaluated) => {}
                other => return Err(format!("{verdict:?} should pass, got {other:?}")),
            }
        }
        Ok(())
    }

    #[test]
    fn report_fail_is_a_scenario_failure() -> TestResult {
        match dispatch_report(
            "declared failure",
            &ReportArgs {
                verdict: ReportVerdict::Fail,
            },
            &mut session(),
        ) {
            Err(RunnerError::ScenarioReportedFailure { scenario })
                if scenario == "declared failure" =>
            {
                Ok(())
            }
            other => Err(format!("expected ScenarioReportedFailure, got {other:?}")),
        }
    }

    /// `- report: drift` is the third verdict, not a failure: the step still
    /// evaluates, so the scenario's teardown runs, and the session carries the
    /// verdict out.
    #[test]
    fn report_drift_is_a_drift_verdict_not_a_failure() -> TestResult {
        let mut drift = session();
        match dispatch_report(
            "drifted",
            &ReportArgs {
                verdict: ReportVerdict::Drift,
            },
            &mut drift,
        ) {
            Ok(StepVerdict::Evaluated) => {}
            other => return Err(format!("expected an evaluated step, got {other:?}")),
        }
        if drift.verdict() != RunVerdict::Drift {
            return Err("the declaration never reached the session".to_owned());
        }
        let Some(finding) = drift.findings().first() else {
            return Err("no finding recorded".to_owned());
        };
        if !finding.detail().contains("drifted") {
            return Err(format!(
                "the finding does not name the scenario: {finding:?}"
            ));
        }
        Ok(())
    }
}
