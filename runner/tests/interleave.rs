// ABOUTME: Pins both web-block shapes — one contiguous run of web steps, and a run split by a runner step.
// ABOUTME: The contiguous shape compiles to one invocation; the split shape is rejected at validate time.

//! Web-block shape suite.
//!
//! A scenario compiles to exactly one `npx playwright test` invocation. These
//! tests pin what that model accepts — one adjacent run of web steps, with
//! runner-side steps before and after it — and what it refuses.

mod common;

use common::Sandbox;

/// Absolute path to a scenario shipped in this repository.
fn repo_scenario(relative: &str) -> String {
    format!("{}/{relative}", env!("CARGO_MANIFEST_DIR"))
}

/// A Playwright JSON report whose single test passed, attaching nothing.
/// Enough for the stub `npx` to stand in for a real invocation.
const PASSING_REPORT: &str = r#"{
  "suites": [
    {
      "title": "scenario.spec.ts",
      "specs": [
        {
          "title": "a note after the teardown",
          "tests": [
            { "projectName": "chromium", "results": [{ "status": "passed" }] }
          ]
        }
      ],
      "suites": []
    }
  ]
}"#;

/// The shape the design specifies: process lifecycle and HTTP probes on the
/// Rust side, every web step in one adjacent run between them. It validates,
/// and its web run compiles into a single Playwright spec that carries every
/// web assertion — the runner-side steps appear only as comments, because Rust
/// executes those around the invocation.
#[test]
fn contiguous_web_block_validates_and_compiles_to_one_spec() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = repo_scenario("samples/web-fixture/scenarios/login.yaml");

    let validated = sandbox.run(&["--validate", &scenario])?;
    if validated.is_failure() {
        return Err(format!(
            "the contiguous shape must validate, exited {:?}\n{}",
            validated.code,
            validated.output()
        ));
    }

    let compiled = sandbox.run(&["--emit", "playwright", &scenario])?;
    if compiled.is_failure() {
        return Err(format!(
            "the contiguous shape must compile, exited {:?}\n{}",
            compiled.code,
            compiled.output()
        ));
    }
    let spec = sandbox.emitted_spec("login")?;
    let blocks = spec.matches("\ntest(").count();
    if blocks != 1 {
        return Err(format!(
            "expected exactly one Playwright test block, got {blocks}\n{spec}"
        ));
    }
    for fragment in [
        "await page.goto(\"http://127.0.0.1:18902/login.html\")",
        "_by(page, \"sign-in\").click(",
        // `type:` clears and fills the field the preceding tap touched.
        "_by(page, \"email\").fill(\"ada@example.com\"",
        // The free browser-side invariants ride on every compiled scenario.
        "expect(_captures.page_errors, 'uncaught page errors').toEqual([]);",
        "_by(page, \"welcome\").waitFor(",
        "expect(_by(page, \"Welcome, ada@example.com\")).toBeVisible(",
        "// step (handled outside Playwright): spawn",
        "// step (handled outside Playwright): http",
        "// step (handled outside Playwright): assert_log_clean",
        "await test.info().attach('mirroir-captures'",
    ] {
        if !spec.contains(fragment) {
            return Err(format!("compiled spec is missing `{fragment}`\n{spec}"));
        }
    }
    Ok(())
}

/// A `judge:` in the contiguous shape gets its response from the page, and the
/// only channel out of the page is the `mirroir-captures` attachment: the
/// scrape happens at the judge step's own position in the flow and is filed
/// under that step's index. No file is written, and none is read —
/// `tests/captures.rs` drives the same shape end-to-end and asserts the oracle
/// received the scraped text.
#[test]
fn judge_response_compiles_into_the_captures_attachment_not_a_file() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario(
        "judged-contiguous.yaml",
        concat!(
            "version: 1\n",
            "name: contiguous web block with a judge post-hook\n",
            "steps:\n",
            "  - spawn: { id: server, command: \"echo booted\" }\n",
            "  - target:\n",
            "      kind: web\n",
            "      browsers: [chrome]\n",
            "      url: \"http://127.0.0.1:18902/login.html\"\n",
            "  - tap: \"sign-in\"\n",
            "  - wait_for: { label: \"welcome\", timeout_s: 10 }\n",
            "  - judge:\n",
            "      profile: fast-ci\n",
            "      user_prompt_template_hash: \"sha256:2fd94adeba57835b2267269c672245aeb82c450908f866bd4c887da010602834\"\n",
            "      response_selector: \"[data-test=welcome]\"\n",
            "      pass_threshold: 0.9\n",
            "  - kill: { id: server }\n",
        ),
    )?;

    let validated = sandbox.run(&["--validate", &scenario])?;
    if validated.is_failure() {
        return Err(format!(
            "the judged contiguous shape must validate, exited {:?}\n{}",
            validated.code,
            validated.output()
        ));
    }

    let compiled = sandbox.run(&["--emit", "playwright", &scenario])?;
    if compiled.is_failure() {
        return Err(format!(
            "the judged contiguous shape must compile, exited {:?}\n{}",
            compiled.code,
            compiled.output()
        ));
    }
    let spec = sandbox.emitted_spec("judged-contiguous")?;
    // The judge sits at step index 4; its scrape is filed under that key.
    for fragment in [
        "_captures.judge[\"4\"] = await _by(page, \"[data-test=welcome]\").innerText();",
        "await test.info().attach('mirroir-captures', { body: JSON.stringify(_captures), contentType: 'application/json' });",
    ] {
        if !spec.contains(fragment) {
            return Err(format!("compiled spec is missing `{fragment}`\n{spec}"));
        }
    }
    for banned in ["writeFileSync", "node:fs"] {
        if spec.contains(banned) {
            return Err(format!(
                "the judge response still round-trips through a file (`{banned}`)\n{spec}"
            ));
        }
    }
    Ok(())
}

/// A web run split by a runner-side step (`web → http → web`) is rejected at
/// validate time, naming the step index that resumes web work.
///
/// The shape cannot mean what it reads: a scenario compiles to one Playwright
/// invocation, so the trailing web steps would run in the same browser context
/// as the leading ones — before the `http:` probe the file puts between them,
/// not after. Re-declaring `target:` to force a second invocation is worse
/// still: a fresh context silently discards cookies, storage, auth and
/// in-memory state. So the runner refuses the shape instead of reordering it.
#[test]
fn non_contiguous_web_block_is_rejected_at_validate_time() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario(
        "split-web-block.yaml",
        concat!(
            "version: 1\n",
            "name: web run split by a runner-side step\n",
            "steps:\n",
            "  - target:\n",
            "      kind: web\n",
            "      browsers: [chrome]\n",
            "      url: \"http://127.0.0.1:9/\"\n",
            "  - assert_visible: \"Dashboard\"\n",
            "  - http:\n",
            "      method: GET\n",
            "      url: \"http://127.0.0.1:9/\"\n",
            "      expect_status: 200\n",
            "  - tap: \"Settings\"\n",
            "  - assert_visible: \"Preferences\"\n",
        ),
    )?;

    let validated = sandbox.run(&["--validate", &scenario])?;
    if !validated.is_failure() {
        return Err(format!(
            "validate accepted the split shape (exit {:?}); it cannot replay as written.\n{}",
            validated.code,
            validated.output()
        ));
    }
    let output = validated.output();
    for fragment in [
        "scenario splits its web steps",
        "step 3 (`tap`)",
        "step `http` ran on the runner side",
    ] {
        if !output.contains(fragment) {
            return Err(format!(
                "the validate failure did not name `{fragment}`\n{output}"
            ));
        }
    }

    // The same shape is refused by the run path too — there is no route that
    // accepts it.
    let run = sandbox.run(&["--run-scenario", &scenario])?;
    if !run.is_failure() {
        return Err(format!(
            "the split shape exited {:?} on --run-scenario.\n{}",
            run.code,
            run.output()
        ));
    }
    Ok(())
}

/// `remember:` is a note, not browser work: it needs no page, so it is legal
/// after the teardown. The design's canonical scenario ends exactly this way,
/// and both the validate path and the run path must accept it — while the note
/// still reaches the emitted spec as a comment at its own position.
#[test]
fn a_remember_after_the_teardown_validates_and_runs() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    sandbox.stub_npx(PASSING_REPORT)?;
    let scenario = sandbox.scenario(
        "remember-after-teardown.yaml",
        concat!(
            "version: 1\n",
            "name: a note after the teardown\n",
            "steps:\n",
            "  - spawn: { id: server, command: \"echo booted\" }\n",
            "  - target:\n",
            "      kind: web\n",
            "      browsers: [chrome]\n",
            "      url: \"http://127.0.0.1:9/\"\n",
            "  - assert_visible: \"Dashboard\"\n",
            "  - kill: { id: server }\n",
            "  - remember: \"Verified streaming reply over preferred transport\"\n",
        ),
    )?;

    // The scenario spawns a subprocess, so the child needs a shell on its
    // PATH — with the sandbox's own bin/ first, so `npx` still resolves to the
    // stub and no real browser is reached for.
    let path = format!("{}/bin:/bin:/usr/bin", sandbox.path().display());
    let env = [("PATH", path.as_str())];

    let validated = sandbox.run_with_env(&["--validate", &scenario], &env)?;
    if validated.is_failure() {
        return Err(format!(
            "a trailing note must validate, exited {:?}\n{}",
            validated.code,
            validated.output()
        ));
    }

    let run = sandbox.run_with_env(&["--run-scenario", &scenario], &env)?;
    if run.is_failure() {
        return Err(format!(
            "a trailing note must run, exited {:?}\n{}",
            run.code,
            run.output()
        ));
    }
    if !run
        .output()
        .contains("Verified streaming reply over preferred transport")
    {
        return Err(format!(
            "the note never reached the run log\n{}",
            run.output()
        ));
    }

    let compiled = sandbox.run_with_env(&["--emit", "playwright", &scenario], &env)?;
    if compiled.is_failure() {
        return Err(format!(
            "a trailing note must compile, exited {:?}\n{}",
            compiled.code,
            compiled.output()
        ));
    }
    let spec = sandbox.emitted_spec("remember-after-teardown")?;
    let note = "// remember: \"Verified streaming reply over preferred transport\"";
    if !spec.contains(note) {
        return Err(format!("compiled spec is missing `{note}`\n{spec}"));
    }
    Ok(())
}

/// A `screenshot:` needs the live page, so it stays a web step wherever it
/// sits. One after the teardown is still refused — a note next to it changes
/// nothing — and the refusal names the step, its index, and why the shape
/// cannot replay as written.
#[test]
fn a_screenshot_after_the_teardown_is_still_rejected() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario(
        "screenshot-after-teardown.yaml",
        concat!(
            "version: 1\n",
            "name: a screenshot after the teardown\n",
            "steps:\n",
            "  - spawn: { id: server, command: \"echo booted\" }\n",
            "  - target:\n",
            "      kind: web\n",
            "      browsers: [chrome]\n",
            "      url: \"http://127.0.0.1:9/\"\n",
            "  - assert_visible: \"Dashboard\"\n",
            "  - kill: { id: server }\n",
            "  - remember: \"the server is down\"\n",
            "  - screenshot: \"after\"\n",
        ),
    )?;

    let validated = sandbox.run(&["--validate", &scenario])?;
    if !validated.is_failure() {
        return Err(format!(
            "validate accepted a screenshot after the teardown (exit {:?}); it would shoot a page whose backend is gone.\n{}",
            validated.code,
            validated.output()
        ));
    }
    let output = validated.output();
    for fragment in [
        "scenario splits its web steps",
        "step 5 (`screenshot`)",
        "step `kill` ran on the runner side",
        "Each block runs as one invocation",
        "move every web step into a single adjacent run",
    ] {
        if !output.contains(fragment) {
            return Err(format!(
                "the validate failure did not name `{fragment}`\n{output}"
            ));
        }
    }
    Ok(())
}
