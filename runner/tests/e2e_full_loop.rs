/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: The acceptance test for the whole runner loop — boot, browser, capture, oracle, verdict, rerun, drift, accept, break, artifacts, lockfile.
// ABOUTME: Drives a real chromium against a served copy of the web fixture from an adopter-shaped `.mirroir/` plan; no stub npx anywhere.

//! Full-loop end-to-end suite.
//!
//! Every other integration suite in this directory stubs `npx` and asserts one
//! feature. This one runs the loop an adopter runs, in order, against a real
//! browser: a `.mirroir/` plan, a project-local archetype, one scenario whose
//! web steps form a single contiguous block, and the process / HTTP / oracle
//! hooks that sit around it.
//!
//! Thirteen phases, each observed rather than assumed:
//!
//! | # | Phase | What it proves |
//! |---|---|---|
//! | 1 | BOOT | the scenario spawns the static server and waits for its port |
//! | 2 | WEB | one contiguous web block compiles to exactly ONE `npx` invocation |
//! | 3 | CAPTURE | the confirmation leaves the browser on the captures attachment |
//! | 4 | ORACLE | the judge post-hook consumes that captured value |
//! | 5 | NON-WEB | the HTTP probe, the kill and the log scan run around the browser |
//! | 6 | VERDICT | PASS, exit 0 |
//! | 7 | RERUN | an identical second run is PASS and the compose cache hits |
//! | 8 | DRIFT | reworded prose, unchanged behavior → exit 65 and a drift-log row |
//! | 9 | ACCEPT | `mirroir-run accept` regenerates the baselines |
//! | 10 | GREEN | the next run is PASS again |
//! | 11 | BREAK | broken behavior → exit 1, carrying Playwright's own message |
//! | 12 | ARTIFACT | the persisted workspace still holds spec, reports and trace |
//! | 13 | SUPPLY | one tampered byte inside a locked archetype fails `--frozen` |
//!
//! The browser leg is gated on `MIRROIR_PLAYWRIGHT_HOME`, the signal the
//! repository's CI lanes already use for "Playwright is provisioned here". A
//! host without it reports that it did not run the loop, loudly, on the real
//! stderr; a host that claims a browser and cannot produce one fails.

mod common;

use std::env;
use std::fs;
use std::net::TcpStream;
use std::path::{Path, PathBuf};

use common::full_loop::{BrowserGate, LoopFixture, LoopOutcome, announce, browser_gate};
use common::loop_tree::{
    FLOW, SAMPLE_NAME, SCENARIO_NAME, break_summary, plant_archetype_tamper, restore_summary,
    reword_summary,
};
use common::{Sandbox, fixture_summary_text};

/// Exit code the runner reserves for the DRIFT verdict.
const EXIT_DRIFT: i32 = 65;

/// Exit code for a genuine failure.
const EXIT_FAIL: i32 = 1;

/// Number of web steps in the scenario's single block: `target`,
/// `assert_visible`, `tap`, `wait_for`, `assert_not_visible`.
const WEB_STEPS: usize = 5;

/// Ordered record of what each phase actually observed, printed at the end so
/// a green run is readable evidence rather than a bare `ok`.
struct PhaseLog(Vec<String>);

impl PhaseLog {
    const fn new() -> Self {
        Self(Vec::new())
    }

    fn record(&mut self, number: usize, phase: &str, evidence: &str) {
        self.0
            .push(format!("  [{number:>2}/13] {phase:<9} {evidence}"));
    }

    fn publish(&self) {
        announce("\nFULL LOOP — phases observed:");
        for line in &self.0 {
            announce(line);
        }
        announce(&format!("FULL LOOP: {}/13 phases observed\n", self.0.len()));
    }
}

/// Assert `needle` appears in `haystack`, naming the phase that wanted it.
fn expect(haystack: &str, needle: &str, phase: &str) -> Result<(), String> {
    if haystack.contains(needle) {
        Ok(())
    } else {
        Err(format!("{phase}: `{needle}` is missing from:\n{haystack}"))
    }
}

/// Assert the run exited with `code`, printing everything it said when not.
fn expect_exit(outcome: &LoopOutcome, code: i32, phase: &str) -> Result<(), String> {
    if outcome.code == Some(code) {
        Ok(())
    } else {
        Err(format!(
            "{phase}: exited {:?}, expected {code}.\n{}",
            outcome.code, outcome.output
        ))
    }
}

/// The whole loop, in the order an adopter meets it.
#[test]
fn the_whole_loop_runs_end_to_end() -> Result<(), String> {
    let toolchain = match browser_gate()? {
        BrowserGate::Ready(toolchain) => toolchain,
        BrowserGate::NotProvisioned(reason) => {
            let guidance = "The thirteen-phase loop needs a browser. Provision one the way the\n\
                 runner-full-loop CI lane does:\n\
                 \x20 export MIRROIR_PLAYWRIGHT_HOME=$HOME/.cache/mirroir-playwright\n\
                 \x20 mkdir -p \"$MIRROIR_PLAYWRIGHT_HOME\" && cd \"$MIRROIR_PLAYWRIGHT_HOME\"\n\
                 \x20 npm init -y && npm install @playwright/test && npx playwright install chromium";
            // Anywhere the loop is optional an unprovisioned browser is a skipped
            // leg, announced loudly. The one lane that owes the loop sets
            // MIRROIR_E2E_REQUIRED, and there a missing browser is a false green —
            // the acceptance test for a branch built to delete silent passes must
            // not become one — so that lane goes red instead of quietly green.
            // The signal is this variable and not `CI`, because every other lane
            // also runs `cargo test --all-targets` without provisioning a browser.
            if env::var_os("MIRROIR_E2E_REQUIRED").is_some() {
                return Err(format!(
                    "FULL LOOP: {reason}, but MIRROIR_E2E_REQUIRED is set. This lane must \
                     exercise the loop, not skip it.\n{guidance}"
                ));
            }
            announce(&format!(
                "\nFULL LOOP: NOT RUN — {reason}.\n{guidance}\n\
                 Nothing below this line was exercised.\n"
            ));
            return Ok(());
        }
    };
    let sandbox = Sandbox::new()?;
    let fixture = LoopFixture::plant(&sandbox, toolchain)?;
    let mut log = PhaseLog::new();
    announce(&format!(
        "\nFULL LOOP: driving {} against 127.0.0.1:{}",
        fixture.chromium().display(),
        fixture.port
    ));

    let baseline = fixture_summary_text("summary.html")?;
    first_run(&fixture, &baseline, &mut log)?;
    rerun(&fixture, &mut log)?;
    let reworded = drift(&fixture, &baseline, &mut log)?;
    accept(&fixture, &baseline, &reworded, &mut log)?;
    green_again(&fixture, &mut log)?;
    break_and_artifacts(&fixture, &mut log)?;
    supply_chain(&fixture, &mut log)?;

    log.publish();
    Ok(())
}

/// Phases 1-6 — one invocation carries boot, browser, capture, oracle, the
/// non-web hooks, and the verdict.
fn first_run(fixture: &LoopFixture<'_>, baseline: &str, log: &mut PhaseLog) -> Result<(), String> {
    let run = fixture.run(&[])?;
    expect_exit(&run, 0, "1-6 first run")?;
    let out = &run.output;

    expect(out, "spawned subprocess", "1 BOOT")?;
    expect(out, "id=fixture", "1 BOOT")?;
    expect(out, r#"kind="wait_port""#, "1 BOOT")?;
    log.record(
        1,
        "BOOT",
        "spawned `python3 -m http.server`, wait_port returned",
    );

    expect(
        out,
        &format!("dispatching the scenario's web block to Playwright web_steps={WEB_STEPS}"),
        "2 WEB",
    )?;
    if run.npx_invocations != 1 {
        return Err(format!(
            "2 WEB: the web block ran {} npx invocations, expected exactly 1.\n{out}",
            run.npx_invocations
        ));
    }
    expect(out, "passed=1 failed=0", "2 WEB")?;
    log.record(
        2,
        "WEB",
        &format!("{WEB_STEPS} web steps → 1 npx invocation → 1 passed spec"),
    );

    expect(out, "judge_captures=1", "3 CAPTURE")?;
    let request = run
        .judge_request
        .as_deref()
        .ok_or("3 CAPTURE: the oracle never received a request")?;
    expect(request, baseline, "3 CAPTURE")?;
    log.record(
        3,
        "CAPTURE",
        "the live page's confirmation reached the judge over the captures attachment",
    );

    let store = fixture.at(".harness/last-green.json");
    let recorded = fs::read_to_string(&store)
        .map_err(|e| format!("4 ORACLE: no baseline was recorded: {e}"))?;
    expect(&recorded, baseline, "4 ORACLE")?;
    expect(&recorded, SCENARIO_NAME, "4 ORACLE")?;
    log.record(
        4,
        "ORACLE",
        "the judge scored the captured text; last-green.json recorded it",
    );

    expect(out, "HTTP probe ok", "5 NON-WEB")?;
    expect(out, "subprocess terminated", "5 NON-WEB")?;
    expect(out, r#"kind="assert_log_clean""#, "5 NON-WEB")?;
    if port_is_open(fixture.port) {
        return Err(format!(
            "5 NON-WEB: port {} is still open, so `kill` did not kill",
            fixture.port
        ));
    }
    log.record(
        5,
        "NON-WEB",
        "http probe → kill (port closed) → assert_log_clean, all runner-side",
    );

    expect(out, "verdict=pass", "6 VERDICT")?;
    log.record(6, "VERDICT", "PASS, exit 0");
    Ok(())
}

/// Phase 7 — an identical rerun is still PASS, and `.build/` is reused rather
/// than rebuilt.
///
/// The sentinel is the proof: `compose_sample` deletes the build directory
/// before writing it, so a file planted there survives exactly one thing — the
/// cache deciding it had nothing to do. That decision hangs on the plan-entry
/// digest being stable across processes, which is what the canonical
/// `BTreeMap` encoding bought.
fn rerun(fixture: &LoopFixture<'_>, log: &mut PhaseLog) -> Result<(), String> {
    let sentinel = fixture.at(&format!(".mirroir/.build/{SAMPLE_NAME}/.cache-sentinel"));
    fs::write(&sentinel, "planted after the first compose\n")
        .map_err(|e| format!("7 RERUN: plant the cache sentinel: {e}"))?;
    let manifest_before = fs::read_to_string(fixture.at(&format!(
        ".mirroir/.build/{SAMPLE_NAME}/.compose-manifest.json"
    )))
    .map_err(|e| format!("7 RERUN: read the compose manifest: {e}"))?;

    let run = fixture.run(&[])?;
    expect_exit(&run, 0, "7 RERUN")?;
    if !sentinel.is_file() {
        return Err(
            "7 RERUN: the build tree was rebuilt — the compose cache missed on an unchanged plan"
                .to_owned(),
        );
    }
    let manifest_after = fs::read_to_string(fixture.at(&format!(
        ".mirroir/.build/{SAMPLE_NAME}/.compose-manifest.json"
    )))
    .map_err(|e| format!("7 RERUN: read the compose manifest: {e}"))?;
    if manifest_before != manifest_after {
        return Err("7 RERUN: the compose manifest was rewritten on an unchanged plan".to_owned());
    }
    if fixture.at(".harness/drift-log.md").exists() {
        return Err("7 RERUN: an unchanged run filed a drift candidate".to_owned());
    }
    log.record(
        7,
        "RERUN",
        "second identical run PASS; .build/ sentinel and manifest untouched (cache hit)",
    );
    Ok(())
}

/// Phase 8 — the wedge. Reword the confirmation, change nothing else.
fn drift(fixture: &LoopFixture<'_>, baseline: &str, log: &mut PhaseLog) -> Result<String, String> {
    let reworded = reword_summary(&fixture.summary_page)?;
    let run = fixture.run(&[])?;
    expect_exit(&run, EXIT_DRIFT, "8 DRIFT")?;
    expect(&run.output, "passed=1 failed=0", "8 DRIFT")?;

    let rows = fs::read_to_string(fixture.at(".harness/drift-log.md"))
        .map_err(|e| format!("8 DRIFT: no drift-log candidate: {e}"))?;
    for fragment in [
        "| Observed at | Scenario | Metric |",
        SCENARIO_NAME,
        "response_levenshtein_pct",
    ] {
        expect(&rows, fragment, "8 DRIFT")?;
    }
    let store = fs::read_to_string(fixture.at(".harness/last-green.json"))
        .map_err(|e| format!("8 DRIFT: read the baseline: {e}"))?;
    if store.contains(&reworded) {
        return Err("8 DRIFT: the drifted run moved the baseline itself".to_owned());
    }
    expect(&store, baseline, "8 DRIFT")?;
    log.record(
        8,
        "DRIFT",
        "every assertion green, wording moved → exit 65, drift-log row, baseline untouched",
    );
    Ok(reworded)
}

/// Phase 9 — the reviewed sign-off.
fn accept(
    fixture: &LoopFixture<'_>,
    baseline: &str,
    reworded: &str,
    log: &mut PhaseLog,
) -> Result<(), String> {
    let run = fixture.accept()?;
    expect_exit(&run, 0, "9 ACCEPT")?;
    if fixture.at(".harness/drift-log.md").exists() {
        return Err("9 ACCEPT: the review queue it answers was left in place".to_owned());
    }
    let store = fs::read_to_string(fixture.at(".harness/last-green.json"))
        .map_err(|e| format!("9 ACCEPT: read the baseline: {e}"))?;
    expect(&store, reworded, "9 ACCEPT")?;
    if store.contains(baseline) {
        return Err("9 ACCEPT: the old wording is still the baseline".to_owned());
    }
    let lock = fs::read_to_string(fixture.at(".mirroir/mirroir.lock"))
        .map_err(|e| format!("9 ACCEPT: read the lockfile: {e}"))?;
    expect(&lock, "checksum: sha256:", "9 ACCEPT")?;
    log.record(
        9,
        "ACCEPT",
        "baselines regenerated (one wording swapped for the other), drift-log cleared, lockfile re-recorded",
    );
    Ok(())
}

/// Phase 10 — green again, now holding to the accepted wording.
fn green_again(fixture: &LoopFixture<'_>, log: &mut PhaseLog) -> Result<(), String> {
    let run = fixture.run(&[])?;
    expect_exit(&run, 0, "10 GREEN")?;
    if fixture.at(".harness/drift-log.md").exists() {
        return Err("10 GREEN: the accepted wording still drifts".to_owned());
    }
    log.record(10, "GREEN", "the run after accept is PASS at exit 0");
    Ok(())
}

/// Phases 11-12 — break the behavior, then read what the failure left behind.
fn break_and_artifacts(fixture: &LoopFixture<'_>, log: &mut PhaseLog) -> Result<(), String> {
    break_summary(&fixture.summary_page)?;
    let run = fixture.run(&[])?;
    expect_exit(&run, EXIT_FAIL, "11 BREAK")?;
    // The point is the message, not the count: a failure that reads "1 of 1
    // test cases failed" tells nobody which locator gave up. These three
    // fragments are Playwright's own — the assertion it ran, the label it
    // resolved, and the text it kept finding — and none of them is anything
    // the runner could have written from the scenario alone.
    for fragment in ["not.toContainText", "order-summary", "Nothing ordered yet."] {
        expect(&run.output, fragment, "11 BREAK")?;
    }
    if fixture.at(".harness/drift-log.md").exists() {
        return Err("11 BREAK: a broken page filed a drift candidate".to_owned());
    }
    log.record(
        11,
        "BREAK",
        "broken click handler → exit 1 carrying Playwright's own locator and expectation",
    );

    let workspace = fixture.at(&format!("target/playwright/{SAMPLE_NAME}/{FLOW}"));
    for artifact in [
        format!("{FLOW}.spec.ts"),
        "playwright.config.ts".to_owned(),
        "playwright-report.json".to_owned(),
        "report-html/index.html".to_owned(),
    ] {
        let path = workspace.join(&artifact);
        if !path.is_file() {
            return Err(format!("12 ARTIFACT: {} is missing", path.display()));
        }
    }
    let trace = find_file(&workspace.join("test-results"), "trace.zip")?
        .ok_or_else(|| format!("12 ARTIFACT: no trace.zip under {}", workspace.display()))?;
    log.record(
        12,
        "ARTIFACT",
        &format!(
            "spec + config + json + html report kept, trace at {}",
            trace.display()
        ),
    );
    Ok(())
}

/// Phase 13 — the lockfile leg. One byte inside the locked archetype tree.
fn supply_chain(fixture: &LoopFixture<'_>, log: &mut PhaseLog) -> Result<(), String> {
    // Undo the break first, so the only thing wrong with this run is the
    // checksum — otherwise `--frozen` could exit non-zero for the wrong reason.
    restore_summary(&fixture.summary_page)?;
    let tampered = plant_archetype_tamper(&fixture.at(".mirroir/archetypes/order-desk"))?;

    let run = fixture.run(&["--frozen"])?;
    if run.code == Some(0) {
        return Err(format!(
            "13 SUPPLY: --frozen accepted a tampered archetype tree.\n{}",
            run.output
        ));
    }
    expect(&run.output, "now hashes to", "13 SUPPLY")?;
    log.record(
        13,
        "SUPPLY",
        &format!("one byte edited in {tampered} → --frozen refuses by checksum"),
    );
    Ok(())
}

/// True when something is listening on `port` of loopback.
fn port_is_open(port: u16) -> bool {
    TcpStream::connect(("127.0.0.1", port)).is_ok()
}

/// Depth-first search for a file named `name` under `root`.
fn find_file(root: &Path, name: &str) -> Result<Option<PathBuf>, String> {
    if !root.is_dir() {
        return Ok(None);
    }
    let entries = fs::read_dir(root).map_err(|e| format!("read {}: {e}", root.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("walk {}: {e}", root.display()))?;
        let path = entry.path();
        if path.is_dir() {
            if let Some(found) = find_file(&path, name)? {
                return Ok(Some(found));
            }
        } else if path.file_name().is_some_and(|f| f == name) {
            return Ok(Some(path));
        }
    }
    Ok(None)
}
