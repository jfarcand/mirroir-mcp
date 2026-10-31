// ABOUTME: `mirroir-run accept` end-to-end — a reviewed DRIFT becomes a diff and the next run is green.
// ABOUTME: Also pins the structural CI refusal: a job must never be able to bless its own drift.

//! Accept suite.
//!
//! Stage 3 gave the runner a DRIFT verdict that routes to human review. A
//! verdict that says "a human should look at this" is a trap without a command
//! for "yes, that is correct now": the suite's steady state goes amber and
//! someone deletes it. These tests pin that command.
//!
//! The subject is the same web fixture the DRIFT suite uses: `summary.html`
//! and its reworded twin render identical DOM and differ only in prose. A stub
//! `npx` supplies the Playwright report and a loopback stub answers the judge,
//! so the suite needs no Node, no browser, and no network.

mod common;

use std::fs;

use common::oracle_stub::stub_oracle;
use common::{Sandbox, fixture_summary_text, passing_report_with_judge, repo_path, skills_arg};

/// Exit code the runner reserves for the DRIFT verdict.
const EXIT_DRIFT: i32 = 65;

/// The judge step sits at index 5 of `order-summary.yaml`.
const JUDGE_STEP_INDEX: &str = "5";

fn report_with(summary: &str) -> String {
    passing_report_with_judge(
        "order-summary.spec.ts",
        "web-fixture — the order summary keeps its wording",
        JUDGE_STEP_INDEX,
        summary,
    )
}

/// Point the `byte-stable` profile at a fresh one-shot stub oracle and plant a
/// stub `npx` that hands back `report`.
fn prime(sandbox: &Sandbox, report: &str) -> Result<(), String> {
    let oracle = stub_oracle("0.95")?;
    sandbox.stub_npx(report)?;
    sandbox.write(
        ".mirroir/oracles/profiles.yaml",
        &format!(
            concat!(
                "version: 1\n",
                "profiles:\n",
                "  - name: byte-stable\n",
                "    base_url: \"http://127.0.0.1:{port}/v1/chat/completions\"\n",
                "    model: stub\n",
                "    timeout_s: 10\n"
            ),
            port = oracle.port
        ),
    )?;
    Ok(())
}

/// One ordinary `--run-scenario` invocation of the shipped drift scenario.
fn run(sandbox: &Sandbox, report: &str) -> Result<(Option<i32>, String), String> {
    prime(sandbox, report)?;
    let scenario = repo_path("samples/web-fixture/scenarios/order-summary.yaml");
    let skills = skills_arg()?;
    let home = sandbox.path().display().to_string();
    let outcome = sandbox.run_outside_ci(
        &["--run-scenario", scenario.as_str(), "--skills", &skills],
        &[("HOME", &home)],
    )?;
    Ok((outcome.code, outcome.output()))
}

/// The same scenario through `mirroir-run accept`.
fn accept(sandbox: &Sandbox, report: &str) -> Result<(Option<i32>, String), String> {
    prime(sandbox, report)?;
    let scenario = repo_path("samples/web-fixture/scenarios/order-summary.yaml");
    let skills = skills_arg()?;
    let home = sandbox.path().display().to_string();
    let outcome = sandbox.run_outside_ci(
        &[
            "accept",
            "--run-scenario",
            scenario.as_str(),
            "--skills",
            &skills,
        ],
        &[("HOME", &home)],
    )?;
    Ok((outcome.code, outcome.output()))
}

/// The loop this stage exists to close: green → reworded page DRIFTs → a human
/// runs `accept` → the same reworded page is green from then on.
#[test]
fn accept_turns_a_drift_into_a_clean_diff_and_the_next_run_is_green() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let store = sandbox.path().join(".harness").join("last-green.json");
    let log = sandbox.path().join(".harness").join("drift-log.md");

    let baseline = fixture_summary_text("summary.html")?;
    let reworded = fixture_summary_text("summary-reworded.html")?;
    if baseline == reworded {
        return Err("the fixture pair no longer differs in wording".to_owned());
    }

    let (code, output) = run(&sandbox, &report_with(&baseline))?;
    if code != Some(0) {
        return Err(format!(
            "the first run exited {code:?}, expected 0.\n{output}"
        ));
    }

    let (code, output) = run(&sandbox, &report_with(&reworded))?;
    if code != Some(EXIT_DRIFT) {
        return Err(format!(
            "the reworded run exited {code:?}, expected {EXIT_DRIFT} (DRIFT).\n{output}"
        ));
    }
    if !log.is_file() {
        return Err("the drifted run filed no candidate row".to_owned());
    }

    // The human reviews the row and signs it off.
    let (code, output) = accept(&sandbox, &report_with(&reworded))?;
    if code != Some(0) {
        return Err(format!("accept exited {code:?}, expected 0.\n{output}"));
    }
    if log.exists() {
        return Err("accept left the reviewed drift candidates in the queue".to_owned());
    }
    let store_json = fs::read_to_string(&store).map_err(|e| format!("read baseline: {e}"))?;
    let first_word = reworded.split(' ').next().unwrap_or(&reworded);
    if !store_json.contains(first_word) {
        return Err(format!(
            "accept did not re-record the reviewed wording:\n{store_json}"
        ));
    }
    if !output.contains("baselines re-recorded") {
        return Err(format!("accept printed no summary.\n{output}"));
    }

    // And the wording it accepted is now the thing every later run holds to.
    let (code, output) = run(&sandbox, &report_with(&reworded))?;
    if code != Some(0) {
        return Err(format!(
            "the run after accept exited {code:?}, expected 0.\n{output}"
        ));
    }
    if log.exists() {
        return Err("the run after accept filed a fresh drift candidate".to_owned());
    }
    Ok(())
}

/// Accepting a baseline is a person saying the new output is correct. A CI job
/// that could say it would report green forever, so the refusal is structural.
#[test]
fn accept_refuses_to_run_in_ci() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = repo_path("samples/web-fixture/scenarios/order-summary.yaml");
    let home = sandbox.path().display().to_string();

    for marker in ["CI", "GITHUB_ACTIONS", "BUILDKITE"] {
        let outcome = sandbox.run_outside_ci(
            &["accept", "--run-scenario", scenario.as_str()],
            &[("HOME", &home), (marker, "1")],
        )?;
        if outcome.code == Some(0) {
            return Err(format!(
                "accept ran with {marker} set:\n{}",
                outcome.output()
            ));
        }
        let text = outcome.output();
        if !text.contains("refuses to run in CI") || !text.contains(marker) {
            return Err(format!(
                "the refusal does not name {marker} or the reason:\n{text}"
            ));
        }
    }
    Ok(())
}

/// A `judge:` step that names its own `drift_baseline_file` compares against
/// that file. Accept rewrites it, so the reviewed wording becomes the anchor —
/// and the file's contents are load-bearing, which the drift on the third run
/// proves.
#[test]
fn accept_rewrites_an_explicit_judge_drift_baseline_file() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let baseline_file = sandbox.path().join("baselines").join("reply.txt");
    let home = sandbox.path().display().to_string();

    let scenario_for = |reply: &str| {
        format!(
            concat!(
                "version: 1\n",
                "name: accept — the explicit judge baseline\n",
                "drift:\n",
                "  fingerprint_similarity: {{ min: 0.85 }}\n",
                "  judge_score_swing: {{ max_delta: 0.10 }}\n",
                "  response_levenshtein_pct: {{ max: 0.20 }}\n",
                "  step_latency_pct_increase: {{ max: 0.30 }}\n",
                "steps:\n",
                "  - judge:\n",
                "      profile: byte-stable\n",
                "      user_prompt_template_hash: \"{hash}\"\n",
                "      response_selector: \"[data-test=reply]\"\n",
                "      response_text: \"{reply}\"\n",
                "      pass_threshold: 0.5\n",
                "      expected_signal: \"confirms the order\"\n",
                "      drift_baseline_file: \"baselines/reply.txt\"\n",
            ),
            hash = TEMPLATE_HASH,
            reply = reply,
        )
    };

    // Accept first: nothing exists yet, so the file is created from what the
    // run judged rather than read.
    let path = sandbox.scenario("accept-baseline.yaml", &scenario_for(FIRST_REPLY))?;
    prime(&sandbox, "{}")?;
    let outcome =
        sandbox.run_outside_ci(&["accept", "--run-scenario", &path], &[("HOME", &home)])?;
    if outcome.code != Some(0) {
        return Err(format!(
            "accept exited {:?}\n{}",
            outcome.code,
            outcome.output()
        ));
    }
    let written = fs::read_to_string(&baseline_file)
        .map_err(|e| format!("accept wrote no drift baseline file: {e}"))?;
    if written != FIRST_REPLY {
        return Err(format!("the baseline file holds `{written}`"));
    }

    // An ordinary run of the same wording holds against it.
    prime(&sandbox, "{}")?;
    let outcome = sandbox.run_outside_ci(&["--run-scenario", &path], &[("HOME", &home)])?;
    if outcome.code != Some(0) {
        return Err(format!(
            "the run after accept exited {:?}\n{}",
            outcome.code,
            outcome.output()
        ));
    }

    // Reword it and the same file is what the run drifts from.
    let reworded =
        sandbox.scenario("accept-baseline-reworded.yaml", &scenario_for(SECOND_REPLY))?;
    prime(&sandbox, "{}")?;
    let outcome = sandbox.run_outside_ci(&["--run-scenario", &reworded], &[("HOME", &home)])?;
    if outcome.code != Some(EXIT_DRIFT) {
        return Err(format!(
            "a reworded reply exited {:?}, expected {EXIT_DRIFT}\n{}",
            outcome.code,
            outcome.output()
        ));
    }
    Ok(())
}

/// The judge's canonical user-prompt template hash — the runner refuses any
/// other value, so the fixture scenarios pin the same one the shipped
/// `order-summary.yaml` does.
const TEMPLATE_HASH: &str =
    "sha256:2fd94adeba57835b2267269c672245aeb82c450908f866bd4c887da010602834";

/// The wording the first accept records.
const FIRST_REPLY: &str = "Order placed. Your total is 42 dollars.";

/// A rewrite of it, far enough to cross the 0.20 Levenshtein ceiling.
const SECOND_REPLY: &str = "We have received your purchase request, chief, and it comes to 42.";
