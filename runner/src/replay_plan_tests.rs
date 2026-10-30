// ABOUTME: Unit tests for the scenario execution plan — each shape, the plan it builds or the refusal it earns.
// ABOUTME: Included by replay_plan.rs as its `tests` module, so `super::` names the plan.

use std::fmt::Write as _;
use std::result::Result as StdResult;

use serde_norway::Deserializer;
use serde_norway::with::singleton_map_recursive;

use super::{ScenarioPlan, Segment};
use crate::error::RunnerError;
use crate::ios_error::IosError;
use crate::parser::scenario::Scenario;
use crate::parser::step::TargetKind;

type TestResult = StdResult<(), String>;

fn steps(yaml: &str) -> StdResult<Scenario, String> {
    singleton_map_recursive::deserialize(Deserializer::from_str(yaml))
        .map_err(|e| format!("parse: {e}"))
}

/// The plan as `hook 0, web 1..3, …` — one assertion per scenario shape.
fn render(yaml: &str) -> StdResult<String, String> {
    let scenario = steps(yaml)?;
    let plan = ScenarioPlan::build(&scenario.steps).map_err(|e| format!("build: {e}"))?;
    let mut out = String::new();
    for segment in plan.segments() {
        if !out.is_empty() {
            out.push_str(", ");
        }
        match segment {
            Segment::Hook(i) => write!(out, "hook {i}"),
            Segment::Block { kind, range } => {
                write!(out, "{kind} {}..{}", range.start, range.end)
            }
        }
        .map_err(|e| e.to_string())?;
    }
    Ok(out)
}

fn build_error(yaml: &str) -> StdResult<RunnerError, String> {
    let scenario = steps(yaml)?;
    match ScenarioPlan::build(&scenario.steps) {
        Err(error) => Ok(error),
        Ok(plan) => Err(format!("expected a refusal, got {:?}", plan.segments())),
    }
}

/// Each shape and the plan it builds: hooks around the web block, a
/// scenario of hooks only, and `remember:` riding inside a block or standing as a hook at either
/// end, never splitting the block.
#[test]
fn each_shape_builds_its_plan() -> TestResult {
    let web = "  - target: { kind: web, url: \"http://x/\" }\n";
    let cases = [
        (
            format!(
                "  - spawn: {{ id: s, command: \"echo hi\" }}\n{web}  - tap: \"Go\"\n  - http: {{ method: GET, url: \"http://x/\" }}\n  - kill: {{ id: s }}\n"
            ),
            "hook 0, web 1..3, hook 3, hook 4",
        ),
        (
            "  - http: { method: GET, url: \"http://x/\" }\n  - report: pass\n".to_owned(),
            "hook 0, hook 1",
        ),
        (
            format!(
                "{web}  - assert_visible: \"Dashboard\"\n  - http: {{ method: GET, url: \"http://x/\" }}\n  - remember: \"done\"\n"
            ),
            "web 0..2, hook 2, hook 3",
        ),
        (
            format!(
                "{web}  - remember: \"about to look\"\n  - assert_visible: \"Dashboard\"\n  - report: pass\n"
            ),
            "web 0..3, hook 3",
        ),
        (
            format!("  - remember: \"first\"\n{web}  - assert_visible: \"Sign in\"\n"),
            "hook 0, web 1..3",
        ),
    ];
    for (body, expected) in cases {
        let plan = render(&format!("version: 1\nname: shape\nsteps:\n{body}"))?;
        if plan != expected {
            return Err(format!("{body}\nplanned `{plan}`, expected `{expected}`"));
        }
    }
    Ok(())
}

/// The shape the plan exists for: a web block, an iOS block carrying the
/// device-level verbs only a phone has, and the parity gate reading both.
#[test]
fn a_web_block_then_an_ios_block_then_the_gate() -> TestResult {
    let plan = render(
        r#"
version: 1
name: two surfaces
steps:
  - target: { kind: web, url: "http://x/" }
  - assert_visible: "panel"
  - target: { kind: ios, app: "Safari" }
  - launch: "Safari"
  - open_url: "http://x/"
  - home:
  - remember: "a note after the block is a hook"
  - cross_surface:
      captures:
        - { surface: web, selector: "[data-test=panel]", to: "w.txt" }
        - { surface: ios, to: "i.txt" }
      response_files: ["w.txt", "i.txt"]
      min_similarity: 0.5
"#,
    );
    if cfg!(target_os = "macos") {
        assert_eq!(plan?, "web 0..2, ios 2..6, hook 6, hook 7");
    } else {
        // Off macOS the iOS block has no executor, and says so by name.
        let error = plan.err().unwrap_or_default();
        if !error.contains("macOS host") {
            return Err(format!("expected the macOS-host refusal, got {error}"));
        }
    }
    Ok(())
}

#[test]
fn a_split_web_block_is_rejected_naming_the_offending_step() -> TestResult {
    let error = build_error(
        r#"
version: 1
name: split
steps:
  - target: { kind: web, url: "http://x/" }
  - assert_visible: "Dashboard"
  - http: { method: GET, url: "http://x/" }
  - tap: "Again"
"#,
    )?;
    match error {
        RunnerError::BlockNotContiguous {
            index: 3,
            kind: "tap",
            surface: TargetKind::Web,
            block_end: 1,
            separator_kind: "http",
        } => Ok(()),
        other => Err(format!("expected BlockNotContiguous, got {other:?}")),
    }
}

/// A note between a runner step and a later web step does not launder the
/// web step back into the block.
#[test]
fn a_remember_does_not_launder_a_trailing_screenshot() -> TestResult {
    let error = build_error(
        "version: 1\nname: launder\nsteps:\n  - target: { kind: web, url: \"http://x/\" }\n  - assert_visible: \"Dashboard\"\n  - report: pass\n  - remember: \"note\"\n  - screenshot: \"after\"\n",
    )?;
    match error {
        RunnerError::BlockNotContiguous {
            index: 4,
            kind: "screenshot",
            ..
        } => Ok(()),
        other => Err(format!("expected BlockNotContiguous, got {other:?}")),
    }
}

#[test]
fn a_target_kind_with_no_executor_is_rejected_naming_the_kind() -> TestResult {
    let error = build_error(
        "version: 1\nname: process\nsteps:\n  - target: { kind: process }\n  - report: pass\n",
    )?;
    match error {
        RunnerError::NoExecutorForTargetKind {
            index: 0,
            kind: TargetKind::Process,
        } => Ok(()),
        other => Err(format!("expected NoExecutorForTargetKind, got {other:?}")),
    }
}

#[test]
fn a_second_block_of_one_surface_is_rejected() -> TestResult {
    let error = build_error(
        "version: 1\nname: twice\nsteps:\n  - target: { kind: web, url: \"http://x/\" }\n  - tap: \"A\"\n  - report: pass\n  - target: { kind: web, url: \"http://y/\" }\n  - tap: \"B\"\n",
    )?;
    match error {
        RunnerError::SurfaceDeclaredTwice {
            surface: TargetKind::Web,
            first: 0,
            index: 3,
        } => Ok(()),
        other => Err(format!("expected SurfaceDeclaredTwice, got {other:?}")),
    }
}

#[test]
fn web_steps_with_no_target_are_rejected() -> TestResult {
    match build_error("version: 1\nname: no-target\nsteps:\n  - tap: \"Send\"\n")? {
        RunnerError::NoWebTarget {
            first_step: "tap",
            declared: "none",
        } => Ok(()),
        other => Err(format!("expected NoWebTarget, got {other:?}")),
    }
}

/// The `target:` opens the block: a device step before it would run before
/// the page is navigated.
#[test]
fn a_web_step_before_the_target_is_rejected() -> TestResult {
    let error = build_error(
        "version: 1\nname: late\nsteps:\n  - assert_visible: \"Dashboard\"\n  - target: { kind: web, url: \"http://x/\" }\n",
    )?;
    match error {
        RunnerError::NoWebTarget {
            first_step: "assert_visible",
            declared: "web",
        } => Ok(()),
        other => Err(format!("expected NoWebTarget, got {other:?}")),
    }
}

/// A capture from a surface the scenario never opens is refused at plan
/// time — `--validate` sees it, not only a run.
#[test]
fn a_capture_from_a_surface_with_no_block_is_a_plan_error() -> TestResult {
    let error = build_error(
        r#"
version: 1
name: no ios block
steps:
  - target: { kind: web, url: "http://x/" }
  - assert_visible: "panel"
  - cross_surface:
      captures:
        - { surface: ios, to: "i.txt" }
      response_files: ["w.txt", "i.txt"]
      min_similarity: 0.5
"#,
    )?;
    if !error
        .to_string()
        .contains("opens no `target: { kind: ios }` block")
    {
        return Err(format!("wrong refusal: {error}"));
    }
    Ok(())
}

#[test]
fn the_plan_hands_the_compiler_the_target_that_opens_the_block() -> TestResult {
    let scenario = steps(
        "version: 1\nname: resolved\nsteps:\n  - spawn: { id: s, command: \"echo hi\" }\n  - target: { kind: web, url: \"http://x/\" }\n  - assert_visible: \"Dashboard\"\n",
    )?;
    let plan = ScenarioPlan::build(&scenario.steps).map_err(|e| format!("build: {e}"))?;
    let target = plan
        .web_target(&scenario.steps)
        .map_err(|e| format!("web_target: {e}"))?;
    assert_eq!(target.kind, TargetKind::Web);
    assert_eq!(target.url.as_deref(), Some("http://x/"));
    Ok(())
}

#[test]
fn a_scenario_with_no_web_block_has_no_target_to_compile() -> TestResult {
    let scenario =
        steps("version: 1\nname: no-web\nsteps:\n  - http: { method: GET, url: \"http://x/\" }\n")?;
    let plan = ScenarioPlan::build(&scenario.steps).map_err(|e| format!("build: {e}"))?;
    match plan.web_target(&scenario.steps) {
        Err(RunnerError::NoWebTarget {
            first_step: "http", ..
        }) => Ok(()),
        other => Err(format!("expected NoWebTarget, got {:?}", other.map(|_| ()))),
    }
}

/// A phone-only step with no `ios` block to carry it would run nothing as a
/// hook, so each one is refused by name — before any block, and after a web
/// block alike.
#[test]
fn a_phone_only_step_outside_an_ios_block_is_refused() -> TestResult {
    let web = "  - target: { kind: web, url: \"http://x/\" }\n  - tap: \"Go\"\n";
    let cases = [
        ("  - launch: \"Acme\"\n", "launch"),
        ("  - home:\n", "home"),
        ("  - shake:\n", "shake"),
        ("  - reset_app: \"Acme\"\n", "reset_app"),
        ("  - set_network: \"airplane_on\"\n", "set_network"),
    ];
    for (step, expected) in cases {
        for (body, index) in [(format!("{step}{web}"), 0), (format!("{web}{step}"), 2)] {
            match build_error(&format!("version: 1\nname: phone\nsteps:\n{body}"))? {
                RunnerError::Ios(IosError::DeviceStepOutsideIosBlock { index: i, kind })
                    if i == index && kind == expected => {}
                other => {
                    return Err(format!(
                        "{body}\nexpected DeviceStepOutsideIosBlock, got {other:?}"
                    ));
                }
            }
        }
    }
    Ok(())
}

/// A phone-only step after a runner-side step ended the `ios` block would
/// need a second block, a fresh session: the split is refused like a web one.
#[cfg(target_os = "macos")]
#[test]
fn a_phone_only_step_after_the_ios_block_ended_is_a_split_block() -> TestResult {
    let error = build_error(
        r#"
version: 1
name: split ios
steps:
  - target: { kind: ios, app: "Safari" }
  - open_url: "http://x/"
  - cross_surface:
      captures:
        - { surface: ios, to: "i.txt" }
      response_files: ["i.txt"]
      min_similarity: 0.5
  - home:
"#,
    )?;
    match error {
        RunnerError::BlockNotContiguous {
            index: 3,
            kind: "home",
            surface: TargetKind::Ios,
            block_end: 1,
            separator_kind: "cross_surface",
        } => Ok(()),
        other => Err(format!("expected BlockNotContiguous, got {other:?}")),
    }
}

/// Nothing here evaluates `if_visible`, so a `condition:` is refused at plan
/// time rather than run as a hook that checks nothing.
#[test]
fn a_condition_has_no_evaluator() -> TestResult {
    let error = build_error(
        r#"
version: 1
name: branch
steps:
  - http: { method: GET, url: "http://x/" }
  - condition:
      if_visible: "Cookie banner"
      then:
        - tap: "Accept all"
"#,
    )?;
    match error {
        RunnerError::ConditionHasNoEvaluator {
            index: 1,
            if_visible,
        } if if_visible == "Cookie banner" => Ok(()),
        other => Err(format!("expected ConditionHasNoEvaluator, got {other:?}")),
    }
}
