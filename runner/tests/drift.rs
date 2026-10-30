// ABOUTME: The third verdict end-to-end — a reworded page drifts, a broken page fails, a bare metric errors.
// ABOUTME: Drives the built binary against runner/samples/web-fixture with a stub npx and a stub oracle.

//! DRIFT verdict suite.
//!
//! Playwright has `passed`, `failed`, `timedOut`, `skipped` and `interrupted`.
//! None of them says "every assertion is green, the log is clean, and the
//! semantics moved". These tests pin the state that does.
//!
//! The subject is the web fixture's drift pair:
//! `samples/web-fixture/public/summary.html` and its reworded twin. Both
//! render the same DOM, respond to the same click, and set the same
//! `data-test` attribute; only the confirmation's prose differs. The scenario
//! driving them, `samples/web-fixture/scenarios/order-summary.yaml`, ships in
//! the repository and runs live against real Chromium; here a stub `npx`
//! supplies the Playwright report and a loopback stub answers the judge, so
//! the suite needs no Node, no browser, and no network.

mod common;

use std::fs;

use common::oracle_stub::stub_oracle;
use common::{Sandbox, fixture_summary_text, passing_report_with_judge, repo_path};

/// Exit code the runner reserves for the DRIFT verdict.
const EXIT_DRIFT: i32 = 65;

/// Exit code for a genuine failure.
const EXIT_FAIL: i32 = 1;

/// The judge step sits at index 5 of `order-summary.yaml`; the compiled spec
/// files its scrape under that key.
const JUDGE_STEP_INDEX: &str = "5";

/// Build a passing Playwright report whose `mirroir-captures` attachment
/// carries `summary` as the judged response.
fn report_with(summary: &str) -> String {
    passing_report_with_judge(
        "order-summary.spec.ts",
        "web-fixture — the order summary keeps its wording",
        JUDGE_STEP_INDEX,
        summary,
    )
}

/// A report in which the page's behavior actually broke: the order button
/// never produced its result, so the `assert_visible` timed out.
const BROKEN_BEHAVIOUR_REPORT: &str = r#"{
  "suites": [
    {
      "title": "order-summary.spec.ts",
      "specs": [
        {
          "title": "web-fixture — the order summary keeps its wording",
          "tests": [
            {
              "projectName": "chromium",
              "results": [
                {
                  "status": "failed",
                  "error": {
                    "message": "locator._waitForVisible: Timeout 10000ms exceeded.\nCall log:\n  - waiting for locator('[data-test=order-summary]') to be visible"
                  }
                }
              ]
            }
          ]
        }
      ],
      "suites": []
    }
  ]
}"#;

/// One `--run-scenario` invocation of the shipped drift scenario, with a
/// freshly primed stub oracle and a stub `npx` that hands back `summary`.
///
/// `skills` points the global drift-threshold layer at a directory; `None`
/// leaves the run with no `drift-defaults.yaml` anywhere, which is the
/// fail-closed case.
fn run_scenario(
    sandbox: &Sandbox,
    report: &str,
    skills: Option<&str>,
) -> Result<(Option<i32>, String), String> {
    let oracle = stub_oracle("0.95")?;
    sandbox.stub_npx(report)?;
    // Only the trusted home overlay may name an endpoint, so the redirect of
    // `byte-stable` onto the stub is declared where a user's machine config
    // lives.
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

    let scenario = repo_path("samples/web-fixture/scenarios/order-summary.yaml");
    let home = sandbox.path().display().to_string();
    let mut args = vec!["--run-scenario", scenario.as_str()];
    if let Some(dir) = skills {
        args.push("--skills");
        args.push(dir);
    }
    let run = sandbox.run_with_env(&args, &[("HOME", &home)])?;
    Ok((run.code, run.output()))
}

/// The repository's own `drift-defaults.yaml` — the shipped global layer.
fn shipped_thresholds() -> String {
    repo_path("")
        .trim_end_matches('/')
        .trim_end_matches('\\')
        .to_owned()
}

/// The wedge. Run the scenario against the baseline wording, then against the
/// reworded twin. Every assertion passes both times and the judge scores both
/// above threshold — so Playwright reports the same green either way. The
/// runner does not: the second run is DRIFT, with its own exit code and a
/// candidate row a human reviews.
#[test]
fn a_reworded_page_drifts_instead_of_failing() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let skills = shipped_thresholds();

    let baseline = fixture_summary_text("summary.html")?;
    let (code, output) = run_scenario(&sandbox, &report_with(&baseline), Some(&skills))?;
    if code != Some(0) {
        return Err(format!(
            "the first run exited {code:?}; a scenario with no baseline yet cannot drift.\n{output}"
        ));
    }
    let store = sandbox.path().join(".harness").join("last-green.json");
    if !store.is_file() {
        return Err("a green run recorded no last-green baseline".to_owned());
    }

    let reworded = fixture_summary_text("summary-reworded.html")?;
    if reworded == baseline {
        return Err("the fixture pair no longer differs in wording".to_owned());
    }
    let (code, output) = run_scenario(&sandbox, &report_with(&reworded), Some(&skills))?;
    if code != Some(EXIT_DRIFT) {
        return Err(format!(
            "the reworded run exited {code:?}, expected {EXIT_DRIFT} (DRIFT).\n{output}"
        ));
    }

    let log = sandbox.path().join(".harness").join("drift-log.md");
    let rows = fs::read_to_string(&log).map_err(|e| format!("no drift-log candidate: {e}"))?;
    for fragment in [
        "| Observed at | Scenario | Metric |",
        "web-fixture — the order summary keeps its wording",
        "response_levenshtein_pct",
    ] {
        if !rows.contains(fragment) {
            return Err(format!("the drift log is missing `{fragment}`:\n{rows}"));
        }
    }

    // The baseline is a human's to move: a drifted run must not quietly adopt
    // the new wording as the thing every later run is compared against.
    let still_green = fs::read_to_string(&store).map_err(|e| format!("read baseline: {e}"))?;
    if still_green.contains("purchase request") {
        return Err(format!(
            "the drifted run overwrote the last-green baseline:\n{still_green}"
        ));
    }
    Ok(())
}

/// The same page, twice. Nothing moved, so nothing drifts and the run stays
/// green — the drift machinery must not turn every second run amber.
#[test]
fn an_unchanged_page_stays_green_on_the_second_run() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let skills = shipped_thresholds();
    let baseline = fixture_summary_text("summary.html")?;

    for attempt in 1..=2 {
        let (code, output) = run_scenario(&sandbox, &report_with(&baseline), Some(&skills))?;
        if code != Some(0) {
            return Err(format!(
                "run {attempt} exited {code:?}, expected 0.\n{output}"
            ));
        }
    }
    if sandbox
        .path()
        .join(".harness")
        .join("drift-log.md")
        .exists()
    {
        return Err("an unchanged page produced a drift candidate".to_owned());
    }
    Ok(())
}

/// A genuine behavior break is still a FAIL, and its exit code stays distinct
/// from DRIFT — otherwise a CI lane that tolerates drift would tolerate a
/// broken page too.
#[test]
fn a_behaviour_break_is_a_failure_not_a_drift() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let skills = shipped_thresholds();

    let (code, output) = run_scenario(&sandbox, BROKEN_BEHAVIOUR_REPORT, Some(&skills))?;
    if code != Some(EXIT_FAIL) {
        return Err(format!(
            "a broken page exited {code:?}, expected {EXIT_FAIL} (FAIL).\n{output}"
        ));
    }
    if !output.contains("waiting for locator('[data-test=order-summary]')") {
        return Err(format!(
            "the failure lost Playwright's own message.\n{output}"
        ));
    }
    if sandbox
        .path()
        .join(".harness")
        .join("drift-log.md")
        .exists()
    {
        return Err("a failing run filed a drift candidate".to_owned());
    }
    Ok(())
}

/// Fail-closed. With a baseline to compare against and no `drift-defaults.yaml`
/// on any layer, the runner refuses by metric name instead of inventing a
/// threshold — a guessed ceiling would silently decide whether the change was
/// reported at all.
#[test]
fn a_metric_no_layer_declares_errors_by_name() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let baseline = fixture_summary_text("summary.html")?;

    // First run: nothing to compare against, so no threshold is needed yet.
    let (code, output) = run_scenario(&sandbox, &report_with(&baseline), None)?;
    if code != Some(0) {
        return Err(format!(
            "the first run exited {code:?}; with no baseline, no threshold is due.\n{output}"
        ));
    }

    // Second run: a comparison is due and no layer covers the metric.
    let reworded = fixture_summary_text("summary-reworded.html")?;
    let (code, output) = run_scenario(&sandbox, &report_with(&reworded), None)?;
    if code != Some(EXIT_FAIL) {
        return Err(format!(
            "an unresolvable threshold exited {code:?}, expected {EXIT_FAIL}.\n{output}"
        ));
    }
    if !output.contains("unspecified drift threshold for fingerprint_similarity") {
        return Err(format!("the refusal did not name the metric.\n{output}"));
    }
    Ok(())
}
