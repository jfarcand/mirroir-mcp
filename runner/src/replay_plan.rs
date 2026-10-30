// ABOUTME: Builds one scenario's execution plan — runner-side hooks and device blocks, in file order.
// ABOUTME: Each block runs as one invocation (Playwright for web, mirroir-mcp for ios), so its steps must be adjacent.

use std::ops::Range;

use crate::error::{Result, RunnerError};
use crate::parser::step::{SkillStep, TargetArgs, TargetKind};
use crate::parser::step_args::CaptureSurface;
use crate::parser::surface::{is_annotation, is_device_step, is_web};
use crate::replay_cross_surface::validate_cross_surface;
use crate::replay_target::{
    block_not_contiguous, check_hook, check_ios_block, check_target, no_web_target,
};

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
/// A step that only a device block can run, or that nothing here evaluates,
/// is never a hook: the plan refuses it instead of letting it pass unrun.
///
/// Annotation steps (`remember:`) are transparent: one between two web steps
/// rides along inside the web block, and one anywhere else is a hook. Inside
/// an `ios` block it is refused — `mirroir-mcp test` cannot evaluate it.
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
    /// * [`crate::ios_error::IosError::AiOnlyStepInBlock`] when an AI-only
    ///   step (`remember:`) sits between two steps of an `ios` block.
    /// * [`RunnerError::NoWebTarget`] when device steps appear before any
    ///   `target:` opens a block for them.
    /// * [`crate::ios_error::IosError::DeviceStepOutsideIosBlock`] when a
    ///   phone-only step (`launch:`, `home:`, `shake:`, `reset_app:`,
    ///   `set_network:`) appears before any `ios` block opens.
    /// * [`RunnerError::ConditionHasNoEvaluator`] for a `condition:`: nothing
    ///   here checks `if_visible`, so its branches would never run.
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
                if let Some(first) = opened_block(&segments, target.kind) {
                    return Err(RunnerError::SurfaceDeclaredTwice {
                        surface: target.kind,
                        first: first.start,
                        index,
                    });
                }
                let end = block_end(steps, index, target.kind);
                if target.kind == TargetKind::Ios {
                    check_ios_block(steps, index..end)?;
                }
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
            check_hook(steps, index, opened_block(&segments, TargetKind::Ios))?;
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

/// The range of the `kind` block already planned, if one opened.
fn opened_block(segments: &[Segment], kind: TargetKind) -> Option<Range<usize>> {
    segments.iter().find_map(|segment| match segment {
        Segment::Block { kind: k, range } if *k == kind => Some(range.clone()),
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
        Segment::Block { kind, range } => Some((*kind, range.clone())),
        Segment::Hook(_) => None,
    });
    match last_block {
        Some((surface, block)) => block_not_contiguous(steps, index, surface, &block),
        None => no_web_target(steps),
    }
}

#[cfg(test)]
#[path = "replay_plan_tests.rs"]
mod tests;
