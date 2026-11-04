// ABOUTME: Reads each `scene:` step's verdict back out of its ios block's report — pass, fail, or inconclusive.
// ABOUTME: A passing scene's tokens and frames feed drift against runs of the same model; a missing verdict is no pass.

use std::ops::Range;

use tracing::info;

use crate::compile::captures::{RunCaptures, SceneCapture, SceneVerdict};
use crate::compile::report::ReporterOutcome;
use crate::compile::report_error::ReportError;
use crate::error::{Result, RunnerError};
use crate::oracle::drift_session::DriftSession;
use crate::oracle::thresholds::DriftMetric;
use crate::parser::step::{SceneArgs, SkillStep};
use crate::scene_error::SceneError;

/// One `scene:` step of the block: its scenario index, its block-relative
/// index (the report's key), and its arguments.
struct SceneStep<'a> {
    index: usize,
    key: String,
    args: &'a SceneArgs,
}

/// Turn the result of running the `ios` block spanning `block` into the
/// scenario's verdict on its `scene:` steps.
///
/// On a passing report every scene must have a report entry. A pass feeds its
/// cost to `drift`, keyed `scene.<index>.<skill>@<model>.tokens` and
/// `….frames_to_predicate` with `index` as the scenario reads, so a scene is
/// compared only with green runs of the same step, skill and model — another
/// model records a fresh baseline instead of reporting drift.
///
/// On a failed report, a scene entry that failed or ran out of budget
/// replaces the report's failure, so its verdict decides the exit code; a
/// fail outranks an inconclusive. When no scene entry explains the failure —
/// a step before the scene failed and the scene never ran — the report's own
/// failure stands.
///
/// A block with no `scene:` step returns `ran` unchanged.
///
/// # Errors
///
/// * [`SceneError::Failed`] for a scene that failed — on either path.
/// * [`SceneError::Inconclusive`] for a scene whose budget ran out, when no
///   scene failed.
/// * [`SceneError::NotReported`] for a scene a passing report says nothing of.
/// * Whatever error `ran` carries when no scene entry explains it.
/// * [`crate::oracle::error::OracleError::ThresholdUnspecified`] when a scene
///   is compared and no layer declares its metric.
pub fn verify_scenes(
    steps: &[SkillStep],
    block: Range<usize>,
    ran: Result<ReporterOutcome>,
    drift: &mut DriftSession,
) -> Result<ReporterOutcome> {
    let scenes = scene_steps(steps, block);
    if scenes.is_empty() {
        return ran;
    }
    match ran {
        Ok(outcome) => {
            judge_passed_block(&scenes, &outcome.captures)?;
            for scene in &scenes {
                if let Some(capture) = outcome.captures.scenes.get(&scene.key) {
                    observe(scene.index, capture, drift)?;
                }
            }
            Ok(outcome)
        }
        Err(RunnerError::Report(ReportError::TestFailures {
            engine,
            failed,
            total,
            failures,
            captures,
        })) => Err(worst_reported(&scenes, &captures).map_or_else(
            || {
                ReportError::TestFailures {
                    engine,
                    failed,
                    total,
                    failures,
                    captures,
                }
                .into()
            },
            Into::into,
        )),
        Err(other) => Err(other),
    }
}

/// The block's `scene:` steps, in file order.
fn scene_steps(steps: &[SkillStep], block: Range<usize>) -> Vec<SceneStep<'_>> {
    let start = block.start;
    block
        .filter_map(|index| match steps.get(index) {
            Some(SkillStep::Scene(args)) => Some(SceneStep {
                index,
                key: (index - start).to_string(),
                args,
            }),
            _ => None,
        })
        .collect()
}

/// A passing block: a scene with no entry is refused, then the worst entry.
fn judge_passed_block(scenes: &[SceneStep<'_>], captures: &RunCaptures) -> Result<()> {
    if let Some(missing) = scenes
        .iter()
        .find(|scene| !captures.scenes.contains_key(&scene.key))
    {
        return Err(SceneError::NotReported {
            index: missing.index,
            skill: missing.args.skill.clone(),
        }
        .into());
    }
    worst_reported(scenes, captures).map_or(Ok(()), |error| Err(error.into()))
}

/// The first failed scene the report carries, else the first inconclusive one.
fn worst_reported(scenes: &[SceneStep<'_>], captures: &RunCaptures) -> Option<SceneError> {
    let reported = || {
        scenes.iter().filter_map(|scene| {
            captures
                .scenes
                .get(&scene.key)
                .map(|capture| (scene.index, capture))
        })
    };
    let first_failed = reported()
        .find(|(_, capture)| capture.verdict == SceneVerdict::Fail)
        .map(|(index, capture)| failed(index, capture));
    first_failed.or_else(|| {
        reported()
            .find(|(_, capture)| capture.verdict == SceneVerdict::Inconclusive)
            .map(|(index, capture)| inconclusive(index, capture))
    })
}

fn failed(index: usize, capture: &SceneCapture) -> SceneError {
    SceneError::Failed {
        index,
        skill: capture.skill.clone(),
        reason: capture.reason,
        frames: capture.frames,
        total_tokens: capture.total_tokens,
        seconds: capture.seconds,
        model: capture.model.clone(),
    }
}

fn inconclusive(index: usize, capture: &SceneCapture) -> SceneError {
    SceneError::Inconclusive {
        index,
        skill: capture.skill.clone(),
        reason: capture.reason,
        frames: capture.frames,
        total_tokens: capture.total_tokens,
        seconds: capture.seconds,
        model: capture.model.clone(),
    }
}

/// Feed one passing scene's cost to the drift session.
fn observe(index: usize, capture: &SceneCapture, drift: &mut DriftSession) -> Result<()> {
    let key = format!("scene.{index}.{}@{}", capture.skill, capture.model);
    info!(
        index,
        skill = %capture.skill,
        model = %capture.model,
        frames = capture.frames,
        total_tokens = capture.total_tokens,
        seconds = capture.seconds,
        waits = capture.waits,
        decider_calls = capture.decider_calls,
        evidence = %capture.evidence_dir.display(),
        "scene passed"
    );
    drift.observe_measure(
        DriftMetric::SceneTokensPctIncrease,
        &format!("{key}.tokens"),
        capture.total_tokens as f64,
    )?;
    if let Some(frames) = capture.frames_to_predicate {
        drift.observe_measure(
            DriftMetric::SceneFramesPctIncrease,
            &format!("{key}.frames_to_predicate"),
            f64::from(frames),
        )?;
    }
    Ok(())
}

#[cfg(test)]
#[path = "replay_scene_tests.rs"]
mod tests;
