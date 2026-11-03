// ABOUTME: Pins how mirroir-run reads mirroir-mcp reports: an AI-only step, and a scene that passed or ran out of budget.
// ABOUTME: The fixtures are byte-exact Swift writer output, pinned on the Swift side by its contract tests.

use std::result::Result as StdResult;

use serde_norway::Deserializer;
use serde_norway::with::singleton_map_recursive;

use crate::compile::captures::{SceneReason, SceneVerdict};
use crate::compile::report::parse_report_body;
use crate::compile::report_error::{ReportEngine, ReportError};
use crate::error::RunnerError;
use crate::oracle::drift_session::DriftSession;
use crate::oracle::thresholds::DriftPolicy;
use crate::parser::scenario::Scenario;
use crate::parser::step::SkillStep;
use crate::replay_scene::verify_scenes;
use crate::scene_error::SceneError;
use crate::verdict::EXIT_INCONCLUSIVE;

/// The report `mirroir-mcp test --report-json` writes for a skill whose
/// device steps passed around a `verify:` it could not evaluate.
const NOT_EVALUATED_REPORT: &str = include_str!("fixtures/mirroir-mcp-report-not-evaluated.json");

/// The report for a block (`target`, `launch`, `scene`) whose scene saw its
/// success predicate on frame 3.
const SCENE_PASS_REPORT: &str = include_str!("fixtures/mirroir-mcp-report-scene-pass.json");

/// The report for the same block shape whose scene used its three frames
/// without seeing either predicate.
const SCENE_INCONCLUSIVE_REPORT: &str =
    include_str!("fixtures/mirroir-mcp-report-scene-inconclusive.json");

/// The block both scene reports were written for: the scene is block step 2.
fn scene_block(skill: &str) -> Result<Vec<SkillStep>, String> {
    let yaml = format!(
        "version: 1\nname: scene\nsteps:\n  - target: {{ kind: ios, app: \"Scene Frames\" }}\n  - launch: \"Scene Frames\"\n  - scene: {{ skill: {skill}, budget: {{ max_frames: 3, max_tokens: 200000, max_seconds: 60 }} }}\n"
    );
    let scenario: Scenario = singleton_map_recursive::deserialize(Deserializer::from_str(&yaml))
        .map_err(|e| e.to_string())?;
    Ok(scenario.steps)
}

/// A passing scene is a passing block, and its cost reaches the drift session
/// under its step, skill and route model.
#[test]
fn a_passing_scene_passes_and_feeds_drift() -> Result<(), String> {
    let ran = parse_report_body(ReportEngine::MirroirMcp, "report.json", SCENE_PASS_REPORT);
    let mut drift = DriftSession::new(DriftPolicy::default(), None);
    let outcome = verify_scenes(&scene_block("scene-frames-reach")?, 0..3, ran, &mut drift)
        .map_err(|e| e.to_string())?;
    let Some(scene) = outcome.captures.scenes.get("2") else {
        return Err("no scene entry under block step 2".to_owned());
    };
    assert_eq!(scene.verdict, SceneVerdict::Pass);
    assert_eq!(scene.frames_to_predicate, Some(3));
    assert_eq!(scene.total_tokens, 72_150);
    let observed = drift.into_observed().metrics;
    assert_eq!(
        observed.get("scene.2.scene-frames-reach@scene-stub.tokens"),
        Some(&72_150.0)
    );
    assert_eq!(
        observed.get("scene.2.scene-frames-reach@scene-stub.frames_to_predicate"),
        Some(&3.0)
    );
    Ok(())
}

/// The block failed, and the scene's own report says why: its budget ran out.
/// The verdict is inconclusive, and the run exits 66 instead of 1.
#[test]
fn an_inconclusive_scene_is_its_own_verdict_and_exits_66() -> Result<(), String> {
    let ran = parse_report_body(
        ReportEngine::MirroirMcp,
        "report.json",
        SCENE_INCONCLUSIVE_REPORT,
    );
    let mut drift = DriftSession::new(DriftPolicy::default(), None);
    match verify_scenes(
        &scene_block("scene-frames-impossible")?,
        0..3,
        ran,
        &mut drift,
    ) {
        Err(
            error @ RunnerError::Scene(SceneError::Inconclusive {
                index: 2,
                reason: SceneReason::MaxFrames,
                frames: 3,
                total_tokens: 72_150,
                ..
            }),
        ) => {
            assert_eq!(error.exit_code(), EXIT_INCONCLUSIVE);
            Ok(())
        }
        other => Err(format!("expected an inconclusive scene, got {other:?}")),
    }
}

/// A skill that holds a not-evaluated AI-only step is a failure of the block,
/// carrying mirroir-mcp's reason, never a pass on its other steps.
#[test]
fn a_not_evaluated_step_fails_the_block_with_its_reason() -> StdResult<(), String> {
    let res = parse_report_body(
        ReportEngine::MirroirMcp,
        "report.json",
        NOT_EVALUATED_REPORT,
    );
    let Err(RunnerError::Report(ReportError::TestFailures {
        failed,
        total,
        failures,
        ..
    })) = res
    else {
        return Err(format!("expected TestFailures, got {res:?}"));
    };
    if failed != 1 || total != 1 {
        return Err(format!("wrong counts: failed={failed} total={total}"));
    }
    let Some(first) = failures.first() else {
        return Err("no failure detail captured".to_owned());
    };
    if first.title != "check-alarms"
        || !first
            .message
            .contains("not evaluated: verify needs an AI client")
    {
        return Err(format!("wrong failure: {first:?}"));
    }
    Ok(())
}

/// A failed report keeps the captures the run wrote, so the scene's report
/// survives the failure it explains.
#[test]
fn a_failed_report_still_carries_its_scene_captures() -> Result<(), String> {
    let res = parse_report_body(
        ReportEngine::MirroirMcp,
        "report.json",
        SCENE_INCONCLUSIVE_REPORT,
    );
    let Err(RunnerError::Report(ReportError::TestFailures {
        failures, captures, ..
    })) = res
    else {
        return Err(format!("expected TestFailures, got {res:?}"));
    };
    if !failures.iter().any(|f| {
        f.message
            .contains("INCONCLUSIVE: scene-frames-impossible: max_frames")
    }) {
        return Err(format!("wrong failure: {failures:?}"));
    }
    match captures.scenes.get("2") {
        Some(scene) if scene.verdict == SceneVerdict::Inconclusive => Ok(()),
        other => Err(format!("scene capture lost on the failure path: {other:?}")),
    }
}
