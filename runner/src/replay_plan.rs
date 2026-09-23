// ABOUTME: Builds one scenario's execution plan — runner-side hooks and device blocks, in file order.
// ABOUTME: Each block runs as one invocation (Playwright for web, mirroir-mcp for ios), so its steps must be adjacent.

use std::ops::Range;

use crate::error::{Result, RunnerError};
use crate::parser::step::{SkillStep, TargetArgs, TargetKind};
use crate::parser::step_args::CaptureSurface;
use crate::parser::surface::{is_annotation, is_device_step, is_web, step_kind};
use crate::replay_cross_surface::validate_cross_surface;
use crate::replay_target::{check_target, no_web_target};

/// One unit of a scenario's execution, in the order the file reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Segment {
    /// A runner-side step, dispatched in Rust — `spawn:`, `http:`, `judge:`,
    /// `cross_surface:`, …
    Hook(usize),
    /// A device block: the `target:` that opens it and the steps it carries,
    /// run as one invocation of the surface's engine.
    Block {
        /// The surface the block drives.
        kind: TargetKind,
        /// Step indices, opening `target:` included.
        range: Range<usize>,
    },
}

/// How one scenario executes.
///
/// A `target:` opens a device block, and the block runs as exactly one
/// invocation: a `web` block compiles to one `npx playwright test`, an `ios`
/// block is handed to one `mirroir-mcp test`. The block carries the device
/// steps of its surface that follow the `target:` and ends at the first
/// runner-side step; everything outside a block is a hook, dispatched in Rust
/// in file order. A hook after a block reads the values the block attached.
///
/// Annotation steps (`remember:`) are transparent: one between two device
/// steps rides along inside the block, and one anywhere else is a hook.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScenarioPlan {
    segments: Vec<Segment>,
}

impl ScenarioPlan {
    /// Partition `steps` into hooks and device blocks.
    ///
    /// # Errors
    ///
    /// * [`RunnerError::NoExecutorForTargetKind`] /
    ///   [`RunnerError::IosNeedsMacosHost`] when a `target:` declares a
    ///   surface nothing here can run.
    /// * [`RunnerError::SurfaceDeclaredTwice`] when a surface opens two blocks.
    /// * [`RunnerError::NoWebTarget`] when device steps appear before any
    ///   `target:` opens a block for them.
    /// * [`RunnerError::BlockNotContiguous`] when a device step follows a
    ///   runner-side step that already ended its block — re-entering the
    ///   surface would mean a second invocation with a fresh session, its
    ///   state silently discarded, so the shape is rejected instead of
    ///   quietly reordered.
    /// * any [`crate::cross_surface_error::CrossSurfaceError`] a
    ///   `cross_surface:` step's shape raises against the blocks this plan
    ///   opens.
    ///
    /// A plan nothing can execute is not a valid plan, so all of these are
    /// refused here rather than deep inside a compiler, where only a run would
    /// have reached them.
    pub fn build(steps: &[SkillStep]) -> Result<Self> {
        let mut segments = Vec::new();
        let mut index = 0;
        while index < steps.len() {
            let step = &steps[index];
            if let SkillStep::Target(target) = step {
                check_target(index, target)?;
                if let Some(first) = opening_index(&segments, target.kind) {
                    return Err(RunnerError::SurfaceDeclaredTwice {
                        surface: target.kind,
                        first,
                        index,
                    });
                }
                let end = block_end(steps, index, target.kind);
                segments.push(Segment::Block {
                    kind: target.kind,
                    range: index..end,
                });
                index = end;
                continue;
            }
            if is_web(step) {
                return Err(device_step_outside_a_block(steps, &segments, index));
            }
            segments.push(Segment::Hook(index));
            index += 1;
        }
        let plan = Self { segments };
        for (at, step) in steps.iter().enumerate() {
            if let SkillStep::CrossSurface(args) = step {
                validate_cross_surface(at, args, |surface| plan.opens(surface))?;
            }
        }
        Ok(plan)
    }

    /// The scenario's hooks and blocks, in execution order.
    #[must_use]
    pub fn segments(&self) -> &[Segment] {
        &self.segments
    }

    /// The step range of the block `kind` opens, if the scenario has one.
    #[must_use]
    pub fn block(&self, kind: TargetKind) -> Option<Range<usize>> {
        self.segments.iter().find_map(|segment| match segment {
            Segment::Block { kind: k, range } if *k == kind => Some(range.clone()),
            _ => None,
        })
    }

    /// The scenario's web block, if it has one.
    #[must_use]
    pub fn web(&self) -> Option<Range<usize>> {
        self.block(TargetKind::Web)
    }

    /// Whether a block runs the surface a `cross_surface` capture reads.
    #[must_use]
    pub fn opens(&self, surface: CaptureSurface) -> bool {
        let kind = match surface {
            CaptureSurface::Web => TargetKind::Web,
            CaptureSurface::Ios => TargetKind::Ios,
        };
        self.block(kind).is_some()
    }

    /// The `target: { kind: web }` step the web block opens with.
    ///
    /// [`Self::build`] proves the block starts there, so the compiler receives
    /// the target the plan resolved instead of scanning the scenario for one
    /// of its own — and validate and run cannot disagree about which target a
    /// file declares.
    ///
    /// # Errors
    ///
    /// [`RunnerError::NoWebTarget`] when the scenario plans no web block:
    /// there is no browser work to compile.
    pub fn web_target<'a>(&self, steps: &'a [SkillStep]) -> Result<&'a TargetArgs> {
        match self.web().and_then(|block| steps.get(block.start)) {
            Some(SkillStep::Target(target)) => Ok(target),
            _ => Err(no_web_target(steps)),
        }
    }
}

/// Index of the `target:` that already opened a `kind` block, if one did.
fn opening_index(segments: &[Segment], kind: TargetKind) -> Option<usize> {
    segments.iter().find_map(|segment| match segment {
        Segment::Block { kind: k, range } if *k == kind => Some(range.start),
        _ => None,
    })
}

/// One past the last device step of the `kind` block opened at `start`.
///
/// The run ends at the first step that executes on the runner side; an
/// annotation executes nowhere, so it does not end it. Trailing annotations
/// are not part of the invocation: the block stops at its last device step.
fn block_end(steps: &[SkillStep], start: usize, kind: TargetKind) -> usize {
    let mut end = start + 1;
    for (offset, step) in steps[start + 1..].iter().enumerate() {
        if matches!(step, SkillStep::Target(_)) {
            break;
        }
        if is_device_step(step, kind) {
            end = start + 1 + offset + 1;
        } else if !is_annotation(step) {
            break;
        }
    }
    end
}

/// The error for a device step no open block carries: a split block when one
/// already ended, a missing `target:` when none ever opened.
fn device_step_outside_a_block(
    steps: &[SkillStep],
    segments: &[Segment],
    index: usize,
) -> RunnerError {
    let last_block = segments.iter().rev().find_map(|segment| match segment {
        Segment::Block { kind, range } => Some((*kind, range.end)),
        Segment::Hook(_) => None,
    });
    match last_block {
        Some((surface, end)) => RunnerError::BlockNotContiguous {
            index,
            kind: step_kind(&steps[index]),
            surface,
            block_end: end - 1,
            separator_kind: steps.get(end).map_or("<end>", step_kind),
        },
        None => no_web_target(steps),
    }
}

#[cfg(test)]
mod tests {
    use std::fmt::Write as _;
    use std::result::Result as StdResult;

    use serde_yaml::Deserializer;
    use serde_yaml::with::singleton_map_recursive;

    use super::{ScenarioPlan, Segment};
    use crate::error::RunnerError;
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
    /// scenario of hooks only, `launch:` outside an iOS block staying a hook,
    /// and `remember:` riding inside a block or standing as a hook at either
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
                format!("  - launch: \"Acme\"\n{web}  - tap: \"Go\"\n"),
                "hook 0, web 1..3",
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
  - remember: "rides along inside the block"
  - home:
  - cross_surface:
      captures:
        - { surface: web, selector: "[data-test=panel]", to: "w.txt" }
        - { surface: ios, to: "i.txt" }
      response_files: ["w.txt", "i.txt"]
      min_similarity: 0.5
"#,
        );
        if cfg!(target_os = "macos") {
            assert_eq!(plan?, "web 0..2, ios 2..7, hook 7");
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
        let scenario = steps(
            "version: 1\nname: no-web\nsteps:\n  - http: { method: GET, url: \"http://x/\" }\n",
        )?;
        let plan = ScenarioPlan::build(&scenario.steps).map_err(|e| format!("build: {e}"))?;
        match plan.web_target(&scenario.steps) {
            Err(RunnerError::NoWebTarget {
                first_step: "http", ..
            }) => Ok(()),
            other => Err(format!("expected NoWebTarget, got {:?}", other.map(|_| ()))),
        }
    }
}
