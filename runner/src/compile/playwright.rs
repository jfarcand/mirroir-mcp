// ABOUTME: Compile a scenario into ONE Playwright `.spec.ts` + emit playwright.config.ts.
// ABOUTME: Runner-side steps are emitted as comments; their captures ride out on the mirroir-captures attachment.

use std::fmt::Write as _;

use crate::compile::playwright_emit::{emit_steps, js_string_literal};
use crate::compile::playwright_prelude::{ScenarioSource, emit_prelude};
use crate::compile::report::CAPTURES_ATTACHMENT;
use crate::error::Result;
use crate::parser::scenario::Scenario;
use crate::parser::step::Browser;
use crate::replay_plan::ScenarioPlan;

/// Output of [`compile_scenario`].
///
/// `spec_ts` is the full TypeScript source of a Playwright spec file (one
/// `test()` per compiled scenario). `browsers` is the list of browsers the
/// emitted spec expects to be parametrized over — used by the
/// [`emit_playwright_config`] caller to drive `projects:`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaywrightSpec {
    /// Full TypeScript source body for the `.spec.ts` file.
    pub spec_ts: String,
    /// Browsers declared by the scenario's `target:` step (defaults to chrome).
    pub browsers: Vec<Browser>,
}

/// Compile one scenario into a Playwright spec body.
///
/// Every web step of the scenario lands in a single `test()` — the runner
/// invokes Playwright once per scenario. Runner-side step variants (`spawn:`,
/// `http:`, `judge:`, …) are kept in the emitted spec as comments so a human
/// reader sees the full intent; at run time the Rust dispatcher executes them
/// as pre-hooks and post-hooks around the invocation.
///
/// Two of those runner-side steps need a value only the live page has:
/// `judge.response_selector` and `cross_surface.capture.selector`. Their text
/// is scraped at the step's own position in the flow and written into a
/// `captures` object, which the test attaches as
/// [`CAPTURES_ATTACHMENT`] — the channel the Rust post-hooks read it back from.
///
/// `plan` is the scenario's [`ScenarioPlan`] — the layer that decides whether
/// anything can execute the plan at all. The spec compiles its web block,
/// opened by the `target: { kind: web }` step the plan resolved; another
/// surface's block is named in a comment and never compiled. `source` names the
/// YAML the scenario was loaded from; it becomes the emitted file's provenance
/// header.
///
/// # Errors
///
/// * [`crate::compile::error::PlaywrightError::Unsupported`] when the scenario
///   carries a `measure:` whose `action` has no web equivalent.
/// * [`crate::compile::error::PlaywrightError::Encode`] if a label, URL, or
///   name can't be encoded as a JS string literal.
/// * [`crate::error::RunnerError::Format`] for `std::fmt::Write` failure
///   (unreachable for `String` but typed for `?` propagation).
pub fn compile_scenario(
    scenario: &Scenario,
    plan: &ScenarioPlan,
    source: &ScenarioSource,
) -> Result<PlaywrightSpec> {
    let target = plan.web_target(&scenario.steps)?;
    let browsers = if target.browsers.is_empty() {
        vec![Browser::Chrome]
    } else {
        target.browsers.clone()
    };

    let mut body = String::new();
    emit_prelude(source, &mut body)?;

    let title = js_string_literal(&scenario.name, "scenario name")?;
    writeln!(body, "test({title}, async ({{ page }}) => {{")?;
    writeln!(
        body,
        "  const _captures = {{ metrics: {{}}, judge: {{}}, cross_surface: {{}}, page_errors: [], failed_requests: [] }};"
    )?;
    writeln!(body, "  _watch(page, _captures);")?;

    if let Some(url) = target.url.as_deref() {
        let lit = js_string_literal(url, "target.url")?;
        writeln!(body, "  await page.goto({lit});")?;
    }

    emit_steps(scenario, plan, &mut body)?;

    // Attached before the invariants are asserted, so a run that trips one
    // still carries every capture the post-hooks read.
    writeln!(
        body,
        "  await test.info().attach('{CAPTURES_ATTACHMENT}', {{ body: JSON.stringify(_captures), contentType: 'application/json' }});"
    )?;
    writeln!(
        body,
        "  expect(_captures.page_errors, 'uncaught page errors').toEqual([]);"
    )?;
    writeln!(
        body,
        "  expect(_captures.failed_requests, 'failed requests').toEqual([]);"
    )?;
    writeln!(body, "}});")?;

    Ok(PlaywrightSpec {
        spec_ts: body,
        browsers,
    })
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;
    use crate::replay_plan::ScenarioPlan;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn compile(yaml: &str) -> StdResult<PlaywrightSpec, Box<dyn StdError>> {
        use serde_yaml::Deserializer;
        use serde_yaml::with::singleton_map_recursive;
        let de = Deserializer::from_str(yaml);
        let scenario: Scenario = singleton_map_recursive::deserialize(de)?;
        let source = ScenarioSource {
            path: "scenarios/unit.yaml".to_owned(),
            digest: "sha256:0".to_owned(),
        };
        // The plan resolves the target, exactly as a run and an `--emit` do:
        // a scenario the plan refuses never reaches the compiler.
        let plan = ScenarioPlan::build(&scenario.steps)?;
        Ok(compile_scenario(&scenario, &plan, &source)?)
    }

    fn assert_contains(haystack: &str, needle: &str) -> TestResult {
        if haystack.contains(needle) {
            Ok(())
        } else {
            Err(format!("expected `{needle}` in output, got:\n{haystack}").into())
        }
    }

    fn assert_missing(haystack: &str, needle: &str) -> TestResult {
        if haystack.contains(needle) {
            Err(format!("did not expect `{needle}` in output, got:\n{haystack}").into())
        } else {
            Ok(())
        }
    }

    #[test]
    fn compiles_simple_web_scenario_with_tap_type_assert() -> TestResult {
        let yaml = r#"
version: 1
name: connect-and-broadcast
steps:
  - target: { kind: web, browsers: [chrome, firefox], url: "http://localhost:8081/" }
  - wait_for: "Connected"
  - tap: "prompt-input"
  - type: "hello"
  - tap: "send"
  - assert_visible: "delivered"
"#;
        let spec = compile(yaml)?;
        assert_eq!(spec.browsers, vec![Browser::Chrome, Browser::Firefox]);
        let s = &spec.spec_ts;
        assert_contains(s, "// AUTO-GENERATED by mirroir-run — DO NOT EDIT.")?;
        assert_contains(s, "// Source: scenarios/unit.yaml")?;
        assert_contains(s, "// Source hash: sha256:0")?;
        assert_contains(s, "import { test, expect } from '@playwright/test';")?;
        assert_contains(s, "test(\"connect-and-broadcast\"")?;
        assert_contains(s, "await page.goto(\"http://localhost:8081/\")")?;
        assert_contains(s, "await _by(page, \"Connected\").waitFor")?;
        assert_contains(
            s,
            "await _by(page, \"prompt-input\").click({ timeout: 30000 });",
        )?;
        // `type:` clears and fills the element the preceding tap touched — no
        // keystrokes at whatever happens to hold focus.
        assert_contains(
            s,
            "await _by(page, \"prompt-input\").fill(\"hello\", { timeout: 30000 });",
        )?;
        assert_missing(s, "page.keyboard.type")?;
        assert_contains(s, "await _by(page, \"send\").click({ timeout: 30000 });")?;
        assert_contains(
            s,
            "await expect(_by(page, \"delivered\")).toBeVisible({ timeout: 30000 });",
        )?;
        // The browser-side invariants every scenario gets for free.
        assert_contains(s, "page.on('pageerror'")?;
        assert_contains(s, "page.on('response'")?;
        assert_contains(
            s,
            "expect(_captures.page_errors, 'uncaught page errors').toEqual([]);",
        )?;
        assert_contains(
            s,
            "expect(_captures.failed_requests, 'failed requests').toEqual([]);",
        )?;
        // Every compiled scenario closes on the captures attachment.
        assert_contains(
            s,
            "await test.info().attach('mirroir-captures', { body: JSON.stringify(_captures), contentType: 'application/json' });",
        )?;
        Ok(())
    }

    #[test]
    fn by_helper_passes_through_locator_engine_prefixes() -> TestResult {
        let yaml = r#"
version: 1
name: role-targeting
steps:
  - target: { kind: web, browsers: [chrome], url: "http://localhost/" }
  - tap: "role=button[name=\"Submit\"]"
  - assert_visible: "role=heading[name=\"Settings\"]"
"#;
        let spec = compile(yaml)?;
        let s = &spec.spec_ts;
        // The helper recognizes Playwright locator-engine prefixes and passes them
        // straight to page.locator (role=/text=/xpath=/css=/id=/data-testid=).
        assert_contains(
            s,
            "if (/^(role|text|xpath|css|id|data-testid)=/.test(label)) return page.locator(label);",
        )?;
        // Bare labels resolve in Playwright's own priority: role first, the
        // test attribute after the user-facing locators, visible text last.
        let role_at = s
            .find("page.getByRole('button', { name: label, exact: true })")
            .ok_or("default chain lost its getByRole branch")?;
        let test_attr_at = s
            .find("page.locator(`[data-test=")
            .ok_or("default chain lost its data-test branch")?;
        let text_at = s
            .find("page.getByText(label, { exact: true })")
            .ok_or("default chain lost its getByText branch")?;
        if !(role_at < test_attr_at && test_attr_at < text_at) {
            return Err(format!("default chain is out of priority order:\n{s}").into());
        }
        assert_contains(
            s,
            "await _by(page, \"role=button[name=\\\"Submit\\\"]\").click({ timeout: 30000 });",
        )?;
        Ok(())
    }

    #[test]
    fn compiles_press_key_with_modifiers() -> TestResult {
        let yaml = r#"
version: 1
name: press-key
steps:
  - target: { kind: web, browsers: [chrome], url: "http://localhost/" }
  - press_key: { key: "return", modifiers: ["command", "shift"] }
"#;
        let spec = compile(yaml)?;
        assert_contains(
            &spec.spec_ts,
            "await page.keyboard.press(\"Meta+Shift+Enter\");",
        )?;
        Ok(())
    }

    #[test]
    fn compiles_non_web_steps_as_comments() -> TestResult {
        let yaml = r#"
version: 1
name: mixed
steps:
  - target: { kind: web, browsers: [chrome], url: "http://localhost/" }
  - tap: "Send"
  - spawn: { id: server, command: "echo hi" }
  - http: { method: GET, url: "http://x/" }
"#;
        let spec = compile(yaml)?;
        let s = &spec.spec_ts;
        assert_contains(s, "// step (handled outside Playwright): spawn")?;
        assert_contains(s, "// step (handled outside Playwright): http")?;
        assert_contains(s, "await _by(page, \"Send\").click({ timeout: 30000 });")?;
        Ok(())
    }

    #[test]
    fn judge_response_selector_is_captured_into_the_attachment_not_a_file() -> TestResult {
        let yaml = r#"
version: 1
name: judged
steps:
  - target: { kind: web, browsers: [chrome], url: "http://x/" }
  - tap: "Send"
  - judge: { profile: fast-ci, user_prompt_template_hash: "sha256:abc", response_selector: "[data-test=reply]", pass_threshold: 0.9 }
"#;
        let spec = compile(yaml)?;
        let s = &spec.spec_ts;
        assert_contains(
            s,
            "_captures.judge[\"2\"] = await _by(page, \"[data-test=reply]\").innerText();",
        )?;
        // The file round-trip this replaces is gone for good.
        assert_missing(s, "writeFileSync")?;
        assert_missing(s, "node:fs")?;
        Ok(())
    }

    #[test]
    fn judge_with_an_inline_response_needs_no_capture() -> TestResult {
        let yaml = r#"
version: 1
name: inline-judged
steps:
  - target: { kind: web, browsers: [chrome], url: "http://x/" }
  - tap: "Send"
  - judge:
      profile: fast-ci
      user_prompt_template_hash: "sha256:abc"
      response_selector: "[data-test=reply]"
      pass_threshold: 0.9
      response_text: "already captured"
"#;
        let spec = compile(yaml)?;
        assert_missing(&spec.spec_ts, "_captures.judge")?;
        Ok(())
    }

    #[test]
    fn cross_surface_capture_is_emitted_at_its_step_position() -> TestResult {
        let yaml = r#"
version: 1
name: cross
steps:
  - target: { kind: web, browsers: [chrome], url: "http://x/" }
  - tap: "Send"
  - cross_surface:
      response_files: ["/tmp/a.txt", "/tmp/b.txt"]
      min_similarity: 0.5
      captures:
        - { surface: web, selector: "main", to: "/tmp/b.txt" }
"#;
        let spec = compile(yaml)?;
        assert_contains(
            &spec.spec_ts,
            "_captures.cross_surface[\"2\"] = await _by(page, \"main\").innerText();",
        )?;
        Ok(())
    }

    /// An iOS block's steps run in mirroir-mcp: the browser spec names them in
    /// a comment and never compiles them, so the phone's `tap:` cannot land on
    /// the page.
    #[cfg(target_os = "macos")]
    #[test]
    fn an_ios_block_is_never_compiled_into_the_browser_spec() -> TestResult {
        let yaml = r#"
version: 1
name: two surfaces
steps:
  - target: { kind: web, url: "http://x/" }
  - tap: "Web Only"
  - target: { kind: ios, app: "Safari" }
  - tap: "Phone Only"
"#;
        let spec = compile(yaml)?;
        assert_contains(&spec.spec_ts, "\"Web Only\"")?;
        assert_missing(&spec.spec_ts, "Phone Only")?;
        assert_contains(
            &spec.spec_ts,
            "// ios block step (runs outside Playwright): tap",
        )?;
        Ok(())
    }

    #[test]
    fn measure_times_its_action_into_the_metrics_capture() -> TestResult {
        let yaml = r#"
version: 1
name: measured
steps:
  - target: { kind: web, browsers: [chrome], url: "http://x/" }
  - measure: { name: "first_token_latency", action: "tap:send", until: "streaming-caret", max_seconds: 5 }
"#;
        let spec = compile(yaml)?;
        let s = &spec.spec_ts;
        assert_contains(s, "const _t0 = Date.now();")?;
        assert_contains(s, "await _by(page, \"send\").click({ timeout: 30000 });")?;
        assert_contains(
            s,
            "await _by(page, \"streaming-caret\").waitFor({ state: 'visible', timeout: 5000 });",
        )?;
        assert_contains(
            s,
            "_captures.metrics[\"first_token_latency\"] = Date.now() - _t0;",
        )?;
        Ok(())
    }

    #[test]
    fn defaults_browsers_to_chrome_when_unspecified() -> TestResult {
        let yaml = r#"
version: 1
name: defaults
steps:
  - target: { kind: web, url: "http://x/" }
"#;
        let spec = compile(yaml)?;
        assert_eq!(spec.browsers, vec![Browser::Chrome]);
        Ok(())
    }

    #[test]
    fn swipe_emits_mouse_wheel_in_each_direction() -> TestResult {
        for (dir, expected) in [
            ("up", "wheel(0, -300)"),
            ("down", "wheel(0, 300)"),
            ("left", "wheel(-300, 0)"),
            ("right", "wheel(300, 0)"),
        ] {
            let yaml = format!(
                "version: 1\nname: swipe\nsteps:\n  - target: {{ kind: web, browsers: [chrome], url: \"http://x/\" }}\n  - swipe: \"{dir}\"\n"
            );
            let spec = compile(&yaml)?;
            assert_contains(&spec.spec_ts, expected).map_err(|e| format!("dir={dir}: {e}"))?;
        }
        Ok(())
    }
}
