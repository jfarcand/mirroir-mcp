// ABOUTME: Per-step Playwright emission — maps each web SkillStep to its `.spec.ts` line(s).
// ABOUTME: Owns locator selection, per-step timeouts, and the JS string-literal encoder.

use std::fmt::Write as _;
use std::ops::Range;

use crate::compile::error::PlaywrightError;
use crate::compile::playwright_keys::{playwright_key_combo, swipe_delta};
use crate::compile::playwright_measure::emit_measure;
use crate::error::Result;
use crate::parser::scenario::Scenario;
use crate::parser::step::{AssertArgs, SkillStep, TapArgs, TargetKind, TypeArgs, WaitForArgs};
use crate::parser::step_args::CaptureSurface;
use crate::parser::surface::{is_web, step_kind};
use crate::replay_plan::{ScenarioPlan, Segment};

/// Ceiling, in milliseconds, for a locator action or assertion whose step
/// declares no `timeout_s` of its own.
const DEFAULT_STEP_TIMEOUT_MS: u64 = 30_000;

/// The element a bare `type:` writes into when no `tap:` preceded it: whatever
/// the page has focused. Naming a target with `into:` is always preferable —
/// this keeps a scenario recorded against a page that autofocuses its input
/// working without one.
const FOCUSED_ELEMENT_LOCATOR: &str = "page.locator(\":focus\")";

/// What the emitter carries from one step to the next.
///
/// A `type:` step with no `into:` writes into the element the closest
/// preceding `tap:` / `long_press:` targeted — the shape every recorded
/// scenario has, and the one the design's worked example compiles to.
#[derive(Debug, Default, Clone)]
pub struct EmitContext {
    last_target: Option<String>,
}

impl EmitContext {
    /// Remember `label` as the element a following bare `type:` writes into.
    fn touched(&mut self, label: &str) {
        self.last_target = Some(label.to_owned());
    }
}

/// Emit the Playwright statement(s) for a single web `step` into `out`.
///
/// Web-handled variants (`tap`/`type`/`wait_for`/…) emit `page`/`_by` calls;
/// every other variant is emitted as a comment so the generated spec mirrors
/// the scenario shape while the Rust dispatcher handles it around Playwright.
///
/// # Errors
///
/// * [`PlaywrightError::Encode`] when a label / text / path can't be encoded
///   as a JS string literal.
/// * [`PlaywrightError::Unsupported`] when a `measure:` step's `action` has no
///   web equivalent.
/// * [`crate::error::RunnerError::Format`] for `std::fmt::Write` failure
///   (unreachable for `String` but typed for `?` propagation).
pub fn emit_step(step: &SkillStep, ctx: &mut EmitContext, out: &mut String) -> Result<()> {
    match step {
        SkillStep::Target(_) => {
            // Target step is consumed by compile_scenario; nothing to emit per step.
        }
        SkillStep::Tap(args) => emit_tap(args, ctx, out)?,
        SkillStep::Type(args) => emit_type(args, ctx, out)?,
        SkillStep::PressKey(args) => {
            let combo = playwright_key_combo(&args.key, &args.modifiers);
            let s = js_string_literal(&combo, "press_key combo")?;
            writeln!(out, "  await page.keyboard.press({s});")?;
        }
        SkillStep::Swipe(direction) => {
            let (dx, dy) = swipe_delta(direction);
            // A wheel event is delivered at the pointer's position, which
            // starts at (0, 0) — outside most scrollable regions. Park the
            // pointer over the page first so the scroll lands on the content.
            writeln!(out, "  await _center(page);")?;
            writeln!(out, "  await page.mouse.wheel({dx}, {dy});")?;
        }
        SkillStep::WaitFor(args) => emit_wait_for(args, out)?,
        SkillStep::AssertVisible(args) => emit_assert(args, Polarity::Positive, out)?,
        SkillStep::AssertNotVisible(args) => emit_assert(args, Polarity::Negative, out)?,
        SkillStep::Screenshot(name) => {
            let path = format!("screenshots/{name}.png");
            let s = js_string_literal(&path, "screenshot path")?;
            writeln!(
                out,
                "  await page.screenshot({{ path: {s}, fullPage: true }});"
            )?;
        }
        SkillStep::OpenUrl(url) => {
            let s = js_string_literal(url, "open_url")?;
            writeln!(out, "  await page.goto({s});")?;
        }
        SkillStep::ScrollTo(args) => {
            let s = js_string_literal(&args.label, "scroll_to label")?;
            writeln!(out, "  await _by(page, {s}).scrollIntoViewIfNeeded();")?;
        }
        SkillStep::LongPress(args) => {
            let s = js_string_literal(&args.label, "long_press label")?;
            let delay = args.duration_ms.unwrap_or(1000);
            writeln!(
                out,
                "  await _by(page, {s}).click({{ delay: {delay}, timeout: {DEFAULT_STEP_TIMEOUT_MS} }});"
            )?;
            ctx.touched(&args.label);
        }
        SkillStep::Drag(args) => {
            let from = js_string_literal(&args.from, "drag.from")?;
            let to = js_string_literal(&args.to, "drag.to")?;
            writeln!(out, "  await _by(page, {from}).dragTo(_by(page, {to}));")?;
        }
        SkillStep::Remember(note) => {
            // Preserve as a comment so reviewers can see the AI observation
            // intent in the generated spec.
            let s = js_string_literal(note, "remember note")?;
            writeln!(out, "  // remember: {s}")?;
        }
        SkillStep::Measure(args) => emit_measure(args, ctx, out)?,
        // iOS-only / native-only / non-web steps: kept as a comment so the
        // generated spec mirrors the scenario shape; the Rust dispatcher
        // handles them around the Playwright invocation.
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
        | SkillStep::CrossSurface(_) => {
            writeln!(
                out,
                "  // step (handled outside Playwright): {}",
                step_kind(step)
            )?;
        }
    }
    Ok(())
}

/// Which way an assertion reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Polarity {
    /// `assert_visible` — the element is there / carries the text.
    Positive,
    /// `assert_not_visible` — the element is gone / lacks the text.
    Negative,
}

fn emit_tap(args: &TapArgs, ctx: &mut EmitContext, out: &mut String) -> Result<()> {
    let target = locator(&args.label, args.last, "tap label")?;
    let ms = timeout_ms(args.timeout_s);
    writeln!(out, "  await {target}.click({{ timeout: {ms} }});")?;
    ctx.touched(&args.label);
    Ok(())
}

/// `type:` clears the field and writes the text, rather than pushing keystrokes
/// at whatever holds focus: a scenario that re-runs against a pre-filled form
/// must produce the same value it did on an empty one.
fn emit_type(args: &TypeArgs, ctx: &EmitContext, out: &mut String) -> Result<()> {
    let text = js_string_literal(&args.text, "type text")?;
    let ms = timeout_ms(args.timeout_s);
    let named = args.into.as_deref().or(ctx.last_target.as_deref());
    let target = match named {
        Some(label) => locator(label, args.last, "type target")?,
        None => FOCUSED_ELEMENT_LOCATOR.to_owned(),
    };
    writeln!(out, "  await {target}.fill({text}, {{ timeout: {ms} }});")?;
    Ok(())
}

fn emit_wait_for(args: &WaitForArgs, out: &mut String) -> Result<()> {
    let target = locator(&args.label, args.last, "wait_for label")?;
    let ms = timeout_ms(args.timeout_s);
    writeln!(
        out,
        "  await {target}.waitFor({{ state: 'visible', timeout: {ms} }});"
    )?;
    Ok(())
}

fn emit_assert(args: &AssertArgs, polarity: Polarity, out: &mut String) -> Result<()> {
    let target = locator(&args.label, args.last, "assert label")?;
    let ms = timeout_ms(args.timeout_s);
    let negation = match polarity {
        Polarity::Positive => "",
        Polarity::Negative => ".not",
    };
    if let Some(text) = args.contains.as_deref() {
        let expected = js_string_literal(text, "assert contains")?;
        writeln!(
            out,
            "  await expect({target}){negation}.toContainText({expected}, {{ timeout: {ms} }});"
        )?;
    } else {
        let matcher = match polarity {
            Polarity::Positive => "toBeVisible",
            Polarity::Negative => "toBeHidden",
        };
        writeln!(
            out,
            "  await expect({target}).{matcher}({{ timeout: {ms} }});"
        )?;
    }
    Ok(())
}

/// The `_by(...)` expression for `label`, with `.last()` appended when the step
/// asked for the final match of an ambiguous label.
fn locator(label: &str, last: bool, context: &str) -> Result<String> {
    let s = js_string_literal(label, context)?;
    Ok(if last {
        format!("_by(page, {s}).last()")
    } else {
        format!("_by(page, {s})")
    })
}

/// Resolve a step's declared `timeout_s` into milliseconds.
const fn timeout_ms(timeout_s: Option<u32>) -> u64 {
    match timeout_s {
        Some(secs) => secs as u64 * 1000,
        None => DEFAULT_STEP_TIMEOUT_MS,
    }
}

/// Walk the scenario's steps in order, emitting each one and — for the two
/// runner-side steps that need a live-page value — the capture that feeds
/// their post-hook.
///
/// Steps inside another surface's block (`ios`) run in that surface's own
/// invocation: they are named in a comment and never compiled, so a phone's
/// `tap:` cannot land in the browser's spec.
///
/// # Errors
///
/// Anything [`emit_step`] returns, plus [`PlaywrightError::Encode`] when a
/// capture selector can't be encoded as a JS string literal.
pub fn emit_steps(scenario: &Scenario, plan: &ScenarioPlan, body: &mut String) -> Result<()> {
    let foreign: Vec<(TargetKind, Range<usize>)> = plan
        .segments()
        .iter()
        .filter_map(|segment| match segment {
            Segment::Block { kind, range } if *kind != TargetKind::Web => {
                Some((*kind, range.clone()))
            }
            _ => None,
        })
        .collect();
    let mut ctx = EmitContext::default();
    let mut web_started = false;
    for (index, step) in scenario.steps.iter().enumerate() {
        if let Some((kind, _)) = foreign.iter().find(|(_, range)| range.contains(&index)) {
            writeln!(
                body,
                "  // {kind} block step (runs outside Playwright): {}",
                step_kind(step)
            )?;
            continue;
        }
        emit_step(step, &mut ctx, body)?;
        if is_web(step) {
            web_started = true;
            continue;
        }
        // A capture before the first web step would scrape a page that has not
        // been driven yet, so it is emitted only once the flow is under way.
        if web_started {
            emit_capture(index, step, body)?;
        }
    }
    Ok(())
}

/// Emit the DOM scrape a runner-side step needs, keyed by its step index.
fn emit_capture(index: usize, step: &SkillStep, body: &mut String) -> Result<()> {
    match step {
        SkillStep::Judge(args) => {
            // An inline response or a file the scenario supplies wins over the
            // page: the author already said where the text comes from.
            if args.response_text.is_some()
                || args.response_file.is_some()
                || args.response_selector.trim().is_empty()
            {
                return Ok(());
            }
            let selector = js_string_literal(&args.response_selector, "judge.response_selector")?;
            writeln!(
                body,
                "  _captures.judge[\"{index}\"] = await _by(page, {selector}).innerText();"
            )?;
        }
        SkillStep::CrossSurface(args) => {
            // The plan validated every capture's shape: a web capture carries
            // its selector. An iOS capture is the iOS block's to record.
            for capture in &args.captures {
                let (CaptureSurface::Web, Some(selector)) = (capture.surface, &capture.selector)
                else {
                    continue;
                };
                let selector = js_string_literal(selector, "cross_surface.captures.selector")?;
                writeln!(
                    body,
                    "  _captures.cross_surface[\"{index}\"] = await _by(page, {selector}).innerText();"
                )?;
            }
        }
        _ => {}
    }
    Ok(())
}

/// Encode `s` as a JSON/JS string literal (double-quoted, escapes applied).
///
/// # Errors
///
/// [`PlaywrightError::Encode`] when `serde_json` fails to encode `s`.
pub fn js_string_literal(s: &str, context: &str) -> Result<String> {
    serde_json::to_string(s).map_err(|source| {
        PlaywrightError::Encode {
            context: context.to_owned(),
            source,
        }
        .into()
    })
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn emit(step: &SkillStep, ctx: &mut EmitContext) -> StdResult<String, Box<dyn StdError>> {
        let mut out = String::new();
        emit_step(step, ctx, &mut out)?;
        Ok(out)
    }

    #[test]
    fn js_string_literal_escapes_special_chars() -> TestResult {
        assert_eq!(js_string_literal("hello", "ctx")?, "\"hello\"");
        assert_eq!(js_string_literal("a\"b", "ctx")?, "\"a\\\"b\"");
        assert_eq!(js_string_literal("line\nfeed", "ctx")?, "\"line\\nfeed\"");
        Ok(())
    }

    #[test]
    fn bare_type_fills_the_element_the_preceding_tap_touched() -> TestResult {
        let mut ctx = EmitContext::default();
        let tapped = emit(&SkillStep::Tap(TapArgs::new("email".to_owned())), &mut ctx)?;
        assert_eq!(
            tapped,
            "  await _by(page, \"email\").click({ timeout: 30000 });\n"
        );
        let typed = emit(
            &SkillStep::Type(TypeArgs::new("ada@example.com".to_owned())),
            &mut ctx,
        )?;
        assert_eq!(
            typed,
            "  await _by(page, \"email\").fill(\"ada@example.com\", { timeout: 30000 });\n"
        );
        Ok(())
    }

    #[test]
    fn type_with_no_preceding_touch_falls_back_to_the_focused_element() -> TestResult {
        let mut ctx = EmitContext::default();
        let typed = emit(&SkillStep::Type(TypeArgs::new("hi".to_owned())), &mut ctx)?;
        assert_eq!(
            typed,
            "  await page.locator(\":focus\").fill(\"hi\", { timeout: 30000 });\n"
        );
        Ok(())
    }

    #[test]
    fn type_into_overrides_the_preceding_touch() -> TestResult {
        let mut ctx = EmitContext::default();
        let _ = emit(&SkillStep::Tap(TapArgs::new("send".to_owned())), &mut ctx)?;
        let typed = emit(
            &SkillStep::Type(TypeArgs {
                text: "hello".to_owned(),
                into: Some("prompt-input".to_owned()),
                last: false,
                timeout_s: Some(5),
            }),
            &mut ctx,
        )?;
        assert_eq!(
            typed,
            "  await _by(page, \"prompt-input\").fill(\"hello\", { timeout: 5000 });\n"
        );
        Ok(())
    }

    #[test]
    fn assert_visible_gains_contains_and_last() -> TestResult {
        let mut ctx = EmitContext::default();
        let plain = emit(
            &SkillStep::AssertVisible(AssertArgs::new("welcome".to_owned())),
            &mut ctx,
        )?;
        assert_eq!(
            plain,
            "  await expect(_by(page, \"welcome\")).toBeVisible({ timeout: 30000 });\n"
        );
        let contains = emit(
            &SkillStep::AssertVisible(AssertArgs {
                label: "message-agent".to_owned(),
                contains: Some("4".to_owned()),
                last: true,
                timeout_s: None,
            }),
            &mut ctx,
        )?;
        assert_eq!(
            contains,
            "  await expect(_by(page, \"message-agent\").last()).toContainText(\"4\", { timeout: 30000 });\n"
        );
        Ok(())
    }

    #[test]
    fn assert_not_visible_inverts_whichever_matcher_the_arguments_select() -> TestResult {
        let mut ctx = EmitContext::default();
        let hidden = emit(
            &SkillStep::AssertNotVisible(AssertArgs::new("error-toast".to_owned())),
            &mut ctx,
        )?;
        assert_eq!(
            hidden,
            "  await expect(_by(page, \"error-toast\")).toBeHidden({ timeout: 30000 });\n"
        );
        let lacks = emit(
            &SkillStep::AssertNotVisible(AssertArgs {
                label: "status".to_owned(),
                contains: Some("Error".to_owned()),
                last: false,
                timeout_s: None,
            }),
            &mut ctx,
        )?;
        assert_eq!(
            lacks,
            "  await expect(_by(page, \"status\")).not.toContainText(\"Error\", { timeout: 30000 });\n"
        );
        Ok(())
    }

    #[test]
    fn swipe_parks_the_pointer_before_it_scrolls() -> TestResult {
        let mut ctx = EmitContext::default();
        let swiped = emit(&SkillStep::Swipe("down".to_owned()), &mut ctx)?;
        assert_eq!(
            swiped,
            "  await _center(page);\n  await page.mouse.wheel(0, 300);\n"
        );
        Ok(())
    }
}
