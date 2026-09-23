// ABOUTME: Classifies every SkillStep as web-compiled or runner-dispatched, and names its kind.
// ABOUTME: One exhaustive match each — a new step kind is a compile error here before it is anywhere else.

use crate::parser::step::{SkillStep, TargetKind};

/// Which executor owns a step.
///
/// A scenario compiles to exactly one Playwright invocation: every
/// [`StepSurface::Web`] step becomes a statement in that spec, and every
/// [`StepSurface::Runner`] step executes in Rust as a pre-hook or a post-hook
/// around the invocation. [`StepSurface::Annotation`] is neither — it records
/// a note and drives nothing, so it is legal at any position.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepSurface {
    /// Compiled into the scenario's Playwright spec.
    Web,
    /// Dispatched in Rust around the Playwright invocation.
    Runner,
    /// Records a note for the run. It needs no browser, no page, and no
    /// runner-side state, so it neither joins the web block nor breaks it.
    Annotation,
}

/// Classify `step`. Exhaustive on purpose — a new step kind must be classified
/// here, and dispatched in `replay_step::dispatch_step`, before this compiles.
#[must_use]
pub const fn step_surface(step: &SkillStep) -> StepSurface {
    match step {
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
        | SkillStep::Measure(_) => StepSurface::Web,
        SkillStep::Remember(_) => StepSurface::Annotation,
        SkillStep::Launch(_)
        | SkillStep::Home(_)
        | SkillStep::Shake(_)
        | SkillStep::ResetApp(_)
        | SkillStep::SetNetwork(_)
        | SkillStep::Condition(_)
        | SkillStep::Spawn(_)
        | SkillStep::WaitPort(_)
        | SkillStep::Kill(_)
        | SkillStep::AssertLog(_)
        | SkillStep::AssertLogClean(_)
        | SkillStep::Judge(_)
        | SkillStep::Http(_)
        | SkillStep::Report(_)
        | SkillStep::CrossSurface(_) => StepSurface::Runner,
    }
}

/// True when `step` compiles into the scenario's Playwright spec.
#[must_use]
pub const fn is_web(step: &SkillStep) -> bool {
    matches!(step_surface(step), StepSurface::Web)
}

/// True when `step` drives the device of a `kind` block — the steps a block of
/// that surface carries, and whose first absence ends it.
///
/// A web block runs the steps Playwright compiles. An iOS block runs those
/// same interaction verbs plus the device-level ones only a phone has —
/// `launch:`, `home:`, `shake:`, `reset_app:`, `set_network:` — which outside
/// an iOS block are runner-side steps with nothing to drive.
#[must_use]
pub const fn is_device_step(step: &SkillStep, kind: TargetKind) -> bool {
    match kind {
        TargetKind::Web => is_web(step),
        TargetKind::Ios => {
            is_web(step)
                || matches!(
                    step,
                    SkillStep::Launch(_)
                        | SkillStep::Home(_)
                        | SkillStep::Shake(_)
                        | SkillStep::ResetApp(_)
                        | SkillStep::SetNetwork(_)
                )
        }
        TargetKind::Process | TargetKind::Http | TargetKind::Macos => false,
    }
}

/// True when `step` only records a note.
///
/// An annotation is transparent to the web block: it neither opens one nor
/// ends one, which is what lets `remember:` sit anywhere a scenario reads
/// naturally — including after the `kill:` that tears the server down.
#[must_use]
pub const fn is_annotation(step: &SkillStep) -> bool {
    matches!(step_surface(step), StepSurface::Annotation)
}

/// Short label for a [`SkillStep`] — used in `tracing` fields, error messages,
/// and the comments the compiler emits for runner-side steps.
#[must_use]
pub const fn step_kind(step: &SkillStep) -> &'static str {
    match step {
        SkillStep::Launch(_) => "launch",
        SkillStep::Tap(_) => "tap",
        SkillStep::Type(_) => "type",
        SkillStep::PressKey(_) => "press_key",
        SkillStep::Swipe(_) => "swipe",
        SkillStep::WaitFor(_) => "wait_for",
        SkillStep::AssertVisible(_) => "assert_visible",
        SkillStep::AssertNotVisible(_) => "assert_not_visible",
        SkillStep::Screenshot(_) => "screenshot",
        SkillStep::Home(_) => "home",
        SkillStep::OpenUrl(_) => "open_url",
        SkillStep::Shake(_) => "shake",
        SkillStep::ScrollTo(_) => "scroll_to",
        SkillStep::ResetApp(_) => "reset_app",
        SkillStep::SetNetwork(_) => "set_network",
        SkillStep::Measure(_) => "measure",
        SkillStep::LongPress(_) => "long_press",
        SkillStep::Drag(_) => "drag",
        SkillStep::Target(_) => "target",
        SkillStep::Remember(_) => "remember",
        SkillStep::Condition(_) => "condition",
        SkillStep::Spawn(_) => "spawn",
        SkillStep::WaitPort(_) => "wait_port",
        SkillStep::Kill(_) => "kill",
        SkillStep::AssertLog(_) => "assert_log",
        SkillStep::AssertLogClean(_) => "assert_log_clean",
        SkillStep::Judge(_) => "judge",
        SkillStep::Http(_) => "http",
        SkillStep::Report(_) => "report",
        SkillStep::CrossSurface(_) => "cross_surface",
    }
}

#[cfg(test)]
mod tests {
    use super::{StepSurface, is_annotation, is_web, step_kind, step_surface};
    use crate::parser::step::{AssertArgs, SkillStep, TapArgs, TargetArgs, TargetKind};

    fn target() -> SkillStep {
        SkillStep::Target(TargetArgs {
            kind: TargetKind::Web,
            browsers: Vec::new(),
            url: None,
            app: None,
        })
    }

    #[test]
    fn web_steps_classify_as_web() {
        assert_eq!(step_surface(&target()), StepSurface::Web);
        assert!(is_web(&SkillStep::Tap(TapArgs::new("Go".to_owned()))));
        assert!(is_web(&SkillStep::Screenshot("shot".to_owned())));
    }

    /// `remember:` records a note. It needs no browser and no runner-side
    /// state, so it is classified as neither surface — the classification that
    /// keeps it from splitting a scenario's single web block.
    #[test]
    fn remember_classifies_as_an_annotation() {
        let note = SkillStep::Remember("saw the streamed reply".to_owned());
        assert_eq!(step_surface(&note), StepSurface::Annotation);
        assert!(is_annotation(&note));
        assert!(!is_web(&note));
        assert!(!is_annotation(&SkillStep::Screenshot("shot".to_owned())));
    }

    #[test]
    fn runner_steps_classify_as_runner() {
        assert_eq!(
            step_surface(&SkillStep::Launch("App".to_owned())),
            StepSurface::Runner
        );
        assert!(!is_web(&SkillStep::Launch("App".to_owned())));
    }

    #[test]
    fn kind_labels_match_the_yaml_verb() {
        assert_eq!(step_kind(&target()), "target");
        assert_eq!(
            step_kind(&SkillStep::Tap(TapArgs::new("Go".to_owned()))),
            "tap"
        );
        assert_eq!(
            step_kind(&SkillStep::AssertNotVisible(AssertArgs::new(
                "x".to_owned()
            ))),
            "assert_not_visible"
        );
    }
}
