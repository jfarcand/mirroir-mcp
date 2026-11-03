// ABOUTME: Tests for reading `scene:` verdicts out of an ios block's report, on the pass and the failure path.
// ABOUTME: Included by replay_scene.rs as its `tests` module; covers outranking, missing entries, and same-model drift.

use std::ops::Range;
use std::path::PathBuf;
use std::result::Result as StdResult;

use serde_norway::Deserializer;
use serde_norway::with::singleton_map_recursive;

use super::verify_scenes;
use crate::compile::captures::{RunCaptures, SceneCapture, SceneReason, SceneVerdict};
use crate::compile::report::{ReporterOutcome, ReporterVerdict, TestFailure};
use crate::compile::report_error::{ReportEngine, ReportError};
use crate::error::{Result, RunnerError};
use crate::oracle::baseline::ScenarioBaseline;
use crate::oracle::drift_log::DriftFinding;
use crate::oracle::drift_session::DriftSession;
use crate::oracle::thresholds::{DriftPolicy, DriftThresholds, MaxThreshold};
use crate::parser::scenario::Scenario;
use crate::parser::step::SkillStep;
use crate::scene_error::SceneError;
use crate::verdict::RunVerdict;

type TestResult = StdResult<(), String>;

/// `target`, `launch`, then two scenes at block indices 2 and 3, behind one
/// leading hook so the block starts at scenario index 1.
fn steps() -> StdResult<Vec<SkillStep>, String> {
    let yaml = concat!(
        "version: 1\nname: scene\nsteps:\n",
        "  - http: { method: GET, url: \"http://x/\" }\n",
        "  - target: { kind: ios, app: \"Scene Frames\" }\n",
        "  - launch: \"Scene Frames\"\n",
        "  - scene: { skill: reach, budget: { max_frames: 6, max_tokens: 200000, max_seconds: 60 } }\n",
        "  - scene: { skill: other, budget: { max_frames: 6, max_tokens: 200000, max_seconds: 60 } }\n",
    );
    let scenario: Scenario = singleton_map_recursive::deserialize(Deserializer::from_str(yaml))
        .map_err(|e| e.to_string())?;
    Ok(scenario.steps)
}

const BLOCK: Range<usize> = 1..5;

fn capture(skill: &str, verdict: SceneVerdict, reason: SceneReason, tokens: u64) -> SceneCapture {
    SceneCapture {
        skill: skill.to_owned(),
        verdict,
        reason,
        frames: 3,
        frames_to_predicate: (verdict == SceneVerdict::Pass).then_some(3),
        prompt_tokens: tokens - 150,
        completion_tokens: 150,
        total_tokens: tokens,
        seconds: 12.5,
        model: "model-a".to_owned(),
        response_model: Some("model-a-2026".to_owned()),
        rejected_replies: 0,
        evidence_dir: PathBuf::from("/w/scene"),
    }
}

fn pass(skill: &str) -> SceneCapture {
    capture(skill, SceneVerdict::Pass, SceneReason::Success, 72_150)
}

fn captures(entries: Vec<(&str, SceneCapture)>) -> RunCaptures {
    RunCaptures {
        scenes: entries
            .into_iter()
            .map(|(key, capture)| (key.to_owned(), capture))
            .collect(),
        ..RunCaptures::default()
    }
}

fn passed(entries: Vec<(&str, SceneCapture)>) -> ReporterOutcome {
    ReporterOutcome {
        verdict: ReporterVerdict {
            passed: 1,
            ..ReporterVerdict::default()
        },
        captures: captures(entries),
    }
}

fn failed(entries: Vec<(&str, SceneCapture)>) -> Result<ReporterOutcome> {
    Err(ReportError::TestFailures {
        engine: ReportEngine::MirroirMcp,
        failed: 1,
        total: 1,
        failures: vec![TestFailure {
            title: "scene".to_owned(),
            message: "step 1 (launch: \"Scene Frames\"): not found".to_owned(),
        }],
        captures: Box::new(captures(entries)),
    }
    .into())
}

fn policy() -> DriftPolicy {
    DriftPolicy::new(
        None,
        None,
        Some(DriftThresholds {
            scene_tokens_pct_increase: Some(MaxThreshold { max: 0.50 }),
            scene_frames_pct_increase: Some(MaxThreshold { max: 0.50 }),
            ..DriftThresholds::default()
        }),
    )
}

fn verify(ran: Result<ReporterOutcome>) -> StdResult<Result<ReporterOutcome>, String> {
    let mut drift = DriftSession::new(policy(), None);
    Ok(verify_scenes(&steps()?, BLOCK, ran, &mut drift))
}

/// Every scene passed: the outcome stands, and each scene's tokens and frames
/// are recorded under its scenario index, skill and route model.
#[test]
fn passing_scenes_record_their_cost_by_step_skill_and_model() -> TestResult {
    let mut drift = DriftSession::new(policy(), None);
    verify_scenes(
        &steps()?,
        BLOCK,
        Ok(passed(vec![("2", pass("reach")), ("3", pass("other"))])),
        &mut drift,
    )
    .map_err(|e| e.to_string())?;
    let keys: Vec<String> = drift.into_observed().metrics.into_keys().collect();
    assert_eq!(
        keys,
        [
            "scene.3.reach@model-a.frames_to_predicate",
            "scene.3.reach@model-a.tokens",
            "scene.4.other@model-a.frames_to_predicate",
            "scene.4.other@model-a.tokens",
        ]
    );
    Ok(())
}

#[test]
fn a_passing_block_with_an_unreported_scene_is_not_a_pass() -> TestResult {
    match verify(Ok(passed(vec![("2", pass("reach"))])))? {
        Err(RunnerError::Scene(SceneError::NotReported { index: 4, skill }))
            if skill == "other" =>
        {
            Ok(())
        }
        other => Err(format!("expected NotReported, got {other:?}")),
    }
}

#[test]
fn an_inconclusive_scene_fails_the_block_as_inconclusive() -> TestResult {
    let out_of_frames = capture(
        "other",
        SceneVerdict::Inconclusive,
        SceneReason::MaxFrames,
        72_150,
    );
    for ran in [
        failed(vec![("2", pass("reach")), ("3", out_of_frames.clone())]),
        Ok(passed(vec![("2", pass("reach")), ("3", out_of_frames)])),
    ] {
        match verify(ran)? {
            Err(error @ RunnerError::Scene(SceneError::Inconclusive { index: 4, .. })) => {
                assert!(error.is_inconclusive());
                assert_eq!(error.exit_code(), 66);
            }
            other => return Err(format!("expected Inconclusive, got {other:?}")),
        }
    }
    Ok(())
}

/// A failed scene outranks an inconclusive one, whatever order they ran in.
#[test]
fn a_failed_scene_outranks_an_inconclusive_one() -> TestResult {
    let ran = failed(vec![
        (
            "2",
            capture(
                "reach",
                SceneVerdict::Inconclusive,
                SceneReason::MaxTokens,
                1_000,
            ),
        ),
        (
            "3",
            capture("other", SceneVerdict::Fail, SceneReason::InputFailed, 500),
        ),
    ]);
    match verify(ran)? {
        Err(error @ RunnerError::Scene(SceneError::Failed { index: 4, .. })) => {
            assert_eq!(error.exit_code(), 1);
            Ok(())
        }
        other => Err(format!("expected Failed, got {other:?}")),
    }
}

/// A step before the scene failed, so no scene ran: the report's own failure
/// is the verdict, not a missing scene.
#[test]
fn a_failure_no_scene_explains_keeps_its_own_error() -> TestResult {
    match verify(failed(Vec::new()))? {
        Err(RunnerError::Report(ReportError::TestFailures { failures, .. }))
            if failures.iter().any(|f| f.message.contains("launch")) =>
        {
            Ok(())
        }
        other => Err(format!("expected the report's TestFailures, got {other:?}")),
    }
}

/// A block with no scene is none of this module's business.
#[test]
fn a_block_without_a_scene_passes_through() -> TestResult {
    let mut drift = DriftSession::new(DriftPolicy::default(), None);
    let all = steps()?;
    match verify_scenes(&all, 1..3, failed(Vec::new()), &mut drift) {
        Err(RunnerError::Report(ReportError::TestFailures { .. })) => Ok(()),
        other => Err(format!("expected the report unchanged, got {other:?}")),
    }
}

/// Against a baseline from the same model a scene that doubled its tokens
/// drifts; the same scene on another model records a fresh baseline instead.
#[test]
fn scene_cost_drifts_only_against_the_same_model() -> TestResult {
    let mut previous = ScenarioBaseline::default();
    previous
        .metrics
        .insert("scene.3.reach@model-a.tokens".to_owned(), 30_000.0);
    previous
        .metrics
        .insert("scene.3.reach@model-a.frames_to_predicate".to_owned(), 3.0);
    let scenes = |model: &str| {
        let mut reach = pass("reach");
        reach.model = model.to_owned();
        let mut other = pass("other");
        other.model = model.to_owned();
        Ok(passed(vec![("2", reach), ("3", other)]))
    };

    let mut drift = DriftSession::new(policy(), Some(previous.clone()));
    verify_scenes(&steps()?, BLOCK, scenes("model-a"), &mut drift).map_err(|e| e.to_string())?;
    if drift.verdict() != RunVerdict::Drift {
        return Err("72150 tokens against 30000 on the same model must drift".to_owned());
    }
    if drift.findings().len() != 1 {
        return Err(format!(
            "only the tokens moved: {:?}",
            drift
                .findings()
                .iter()
                .map(DriftFinding::summary)
                .collect::<Vec<_>>()
        ));
    }

    let mut drift = DriftSession::new(policy(), Some(previous));
    verify_scenes(&steps()?, BLOCK, scenes("model-b"), &mut drift).map_err(|e| e.to_string())?;
    if drift.verdict() != RunVerdict::Pass {
        return Err("another model has no baseline to drift from".to_owned());
    }
    Ok(())
}
