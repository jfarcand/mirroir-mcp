// ABOUTME: The cross-surface parity gate's four phases — capture and agree, reword and refuse, accept, refuse again.
// ABOUTME: Drives the shipped samples/web-fixture parity scenario against a real chromium in a sandbox copy of the sample.

//! Cross-surface parity gate.
//!
//! `samples/web-fixture/scenarios/parity.yaml` is the gate in the shape that
//! can produce both of its halves: one contiguous web block ending in a
//! `cross_surface:` step whose `capture:` scrapes the live panel into
//! `baselines/parity.web.txt` — one of the two files that same step then
//! compares. The other half, `baselines/parity.ios.txt`, is a committed
//! stand-in for a `generate_skill` device capture. Nothing in this tree
//! produces it, and that asymmetry is the whole subject of this suite.
//!
//! Four phases, in order:
//!
//! | # | Phase | What it proves |
//! |---|---|---|
//! | 1 | PASS | the run writes the web half from the live page and both surfaces agree |
//! | 2 | REFUSE | the reworded page keeps every assertion green and pulls the surfaces apart |
//! | 3 | ACCEPT | `accept` re-records the web half and names the iOS half it did not touch |
//! | 4 | STILL REFUSED | the very next ordinary run refuses again |
//!
//! Phase 4 is the point of the suite. A cross-surface break closes on a device
//! re-capture, not on the runner: were `accept` ever changed to write
//! `parity.ios.txt` as well, the gate would be comparing a file against itself
//! and phase 4 would turn green on a tautology.
//!
//! **Phases 2 and 4 assert what the runner does, which is not what a drifted
//! judge does.** A pair below `min_similarity` is
//! `RunnerError::CrossSurfaceMismatch`, an `Err`, and `main` maps every `Err`
//! to exit 1 — so a broken parity gate is a FAILURE, filing no
//! `.harness/drift-log.md` row, rather than the DRIFT verdict at exit 65 that a
//! reworded judge response produces. The two are asserted apart here so a
//! change to either is visible.
//!
//! The browser leg is gated on `MIRROIR_PLAYWRIGHT_HOME`, the signal the
//! repository's CI lanes already use for "Playwright is provisioned here",
//! exactly as `e2e_full_loop.rs` gates its own.

mod common;

use std::env;
use std::fs;
use std::path::PathBuf;

use common::full_loop::{BrowserGate, Toolchain, announce, browser_gate};
use common::parity_tree::{
    IOS_BASELINE, PAGE, REWORDED_PAGE, SAMPLE_SOURCE, WEB_BASELINE, panel_lines, plant_sample,
    reword_scenario, shipped_ios_baseline,
};
use common::{Sandbox, free_port, repo_path, strip_ansi};

/// Exit code for a genuine failure — every `Err` the runner returns.
const EXIT_FAIL: i32 = 1;

/// Text no page in the fixture renders, planted over the web surface just
/// before `accept` runs. Phase 2's refusing run already left the reworded
/// scrape on disk, so without clobbering it first "accept re-recorded the page"
/// and "accept wrote nothing at all" leave identical bytes behind.
const SENTINEL: &str = "sentinel text no fixture page renders";

/// Ordered record of what each phase observed, printed at the end so a green
/// run is readable evidence rather than a bare `ok`.
struct PhaseLog(Vec<String>);

impl PhaseLog {
    const fn new() -> Self {
        Self(Vec::new())
    }

    fn record(&mut self, number: usize, phase: &str, evidence: &str) {
        self.0
            .push(format!("  [{number}/4] {phase:<14} {evidence}"));
    }

    fn publish(&self) {
        announce("\nPARITY GATE — phases observed:");
        for line in &self.0 {
            announce(line);
        }
        announce(&format!(
            "PARITY GATE: {}/4 phases observed\n",
            self.0.len()
        ));
    }
}

/// One invocation of the runner against the planted sample.
struct GateOutcome {
    /// Exit code; `None` when the child was killed by a signal.
    code: Option<i32>,
    /// Everything the invocation printed, with the colorizer's escapes gone.
    output: String,
}

/// A sandbox copy of `samples/web-fixture/`, served on a reserved port.
struct ParityGate<'a> {
    sandbox: &'a Sandbox,
    /// The sample directory the runner is pointed at.
    sample: String,
    /// `<sample>/scenarios/parity.yaml` — phase 2 repoints its `url:`.
    scenario: PathBuf,
    /// `<sample>/baselines/` — where both halves of the gate live.
    baselines: PathBuf,
    /// `$HOME` for the child, so a developer's own `~/.mirroir/` cannot decide
    /// a threshold here.
    home: String,
    /// `PATH` for the child: the inherited one, which carries `npx`, `node`
    /// and `python3`. `Sandbox` otherwise hands the child an empty `bin/`.
    path: String,
    playwright_home: String,
    browsers_path: String,
}

impl<'a> ParityGate<'a> {
    /// Copy the shipped sample into `sandbox` and reserve its port.
    fn plant(sandbox: &'a Sandbox, toolchain: &Toolchain) -> Result<Self, String> {
        let sample_dir = plant_sample(sandbox, free_port()?)?;
        // The same file the repository's own runs resolve thresholds from, so
        // the sandbox run and a `--sample samples/web-fixture` run read one
        // policy rather than two.
        sandbox.write(
            "drift-defaults.yaml",
            &fs::read_to_string(repo_path("drift-defaults.yaml"))
                .map_err(|e| format!("read the shipped drift-defaults.yaml: {e}"))?,
        )?;
        let path = env::var_os("PATH")
            .ok_or("no PATH in this process's environment")?
            .into_string()
            .map_err(|_| "PATH is not valid UTF-8".to_owned())?;
        Ok(Self {
            sandbox,
            sample: sample_dir
                .to_str()
                .ok_or("the sandbox sample path is not valid UTF-8")?
                .to_owned(),
            scenario: sample_dir.join("scenarios").join("parity.yaml"),
            baselines: sample_dir.join("baselines"),
            home: sandbox.path().join("home").display().to_string(),
            path,
            playwright_home: toolchain.playwright_home.display().to_string(),
            browsers_path: toolchain.browsers_path.display().to_string(),
        })
    }

    /// `mirroir-run --sample <dir>`.
    fn run(&self) -> Result<GateOutcome, String> {
        self.invoke(&["--sample", self.sample.as_str()], false)
    }

    /// `mirroir-run accept --sample <dir>`, with the CI markers cleared the way
    /// a human's shell has them cleared.
    fn accept(&self) -> Result<GateOutcome, String> {
        self.invoke(&["accept", "--sample", self.sample.as_str()], true)
    }

    fn invoke(&self, args: &[&str], outside_ci: bool) -> Result<GateOutcome, String> {
        let env: [(&str, &str); 4] = [
            ("HOME", self.home.as_str()),
            ("PATH", self.path.as_str()),
            ("MIRROIR_PLAYWRIGHT_HOME", self.playwright_home.as_str()),
            ("PLAYWRIGHT_BROWSERS_PATH", self.browsers_path.as_str()),
        ];
        let run = if outside_ci {
            self.sandbox.run_outside_ci(args, &env)?
        } else {
            self.sandbox.run_with_env(args, &env)?
        };
        Ok(GateOutcome {
            code: run.code,
            output: strip_ansi(&run.output()),
        })
    }

    /// Read one of the two compared surfaces.
    fn baseline(&self, name: &str) -> Result<String, String> {
        let path = self.baselines.join(name);
        fs::read_to_string(&path).map_err(|e| format!("read {}: {e}", path.display()))
    }

    /// Overwrite one of the compared surfaces.
    fn plant_baseline(&self, name: &str, body: &str) -> Result<(), String> {
        let path = self.baselines.join(name);
        fs::write(&path, body).map_err(|e| format!("write {}: {e}", path.display()))
    }

    /// Absolute path inside the sandbox.
    fn at(&self, relative: &str) -> PathBuf {
        self.sandbox.path().join(relative)
    }
}

/// The four phases, in the order a break travels through them.
#[test]
fn the_parity_gate_closes_on_a_device_recapture() -> Result<(), String> {
    let toolchain = match browser_gate()? {
        BrowserGate::Ready(toolchain) => toolchain,
        BrowserGate::NotProvisioned(reason) => return report_no_browser(&reason),
    };
    let sandbox = Sandbox::new()?;
    let gate = ParityGate::plant(&sandbox, &toolchain)?;
    let mut log = PhaseLog::new();
    announce(&format!(
        "\nPARITY GATE: driving {} against the sandbox copy of {SAMPLE_SOURCE}",
        toolchain.chromium.display()
    ));

    pass(&gate, &mut log)?;
    let refused = refuse(&gate, &mut log)?;
    accept(&gate, &mut log)?;
    still_refused(&gate, &refused, &mut log)?;

    log.publish();
    Ok(())
}

/// Phase 1 — the run produces the web half and the two surfaces agree.
fn pass(gate: &ParityGate<'_>, log: &mut PhaseLog) -> Result<(), String> {
    if gate.baselines.join(WEB_BASELINE).exists() {
        return Err(format!(
            "1 PASS: {WEB_BASELINE} was planted; the run has to produce it"
        ));
    }
    let run = gate.run()?;
    expect_exit(&run, 0, "1 PASS")?;
    expect(&run.output, "cross_surface capture written", "1 PASS")?;
    expect(
        &run.output,
        "cross_surface: all pairs above threshold",
        "1 PASS",
    )?;

    let captured = gate.baseline(WEB_BASELINE)?;
    for line in panel_lines(PAGE)? {
        expect(&captured, &line, "1 PASS")?;
    }
    if gate.at(".harness/drift-log.md").exists() {
        return Err("1 PASS: an agreeing run filed a drift candidate".to_owned());
    }
    log.record(
        1,
        "PASS",
        &format!("{WEB_BASELINE} scraped from the live panel; both surfaces above min_similarity"),
    );
    Ok(())
}

/// Phase 2 — the reworded page. Every assertion still holds; the token sets
/// come apart.
///
/// Returns the refusal's outcome so phase 4 can insist on the same exit code.
fn refuse(gate: &ParityGate<'_>, log: &mut PhaseLog) -> Result<GateOutcome, String> {
    reword_scenario(&gate.scenario)?;
    let run = gate.run()?;
    expect_exit(&run, EXIT_FAIL, "2 REFUSE")?;
    // On the refusal's own line, not merely somewhere in the transcript: a run
    // names both files in its progress logging before it decides anything, so a
    // whole-output search would hold even if the error named neither.
    let refusal = line_with(&run.output, "cross_surface mismatch", "2 REFUSE")?;
    expect(refusal, WEB_BASELINE, "2 REFUSE")?;
    expect(refusal, IOS_BASELINE, "2 REFUSE")?;

    // The capture is written before the comparison runs — the scrape *is* the
    // web surface, so the refusing run leaves the reworded text on disk. What
    // it must not do is move the iOS surface with it.
    let captured = gate.baseline(WEB_BASELINE)?;
    for line in panel_lines(REWORDED_PAGE)? {
        expect(&captured, &line, "2 REFUSE")?;
    }
    expect_ios_untouched(gate, "2 REFUSE")?;

    // A mismatch is an error, not the DRIFT verdict: no candidate row is filed,
    // and the exit code is 1 rather than 65.
    if gate.at(".harness/drift-log.md").exists() {
        return Err(
            "2 REFUSE: a cross_surface mismatch filed a drift candidate; it exits 1, not 65"
                .to_owned(),
        );
    }
    log.record(
        2,
        "REFUSE",
        "reworded panel, every assertion green → exit 1 naming both surfaces, no drift row",
    );
    Ok(run)
}

/// Phase 3 — `accept` re-records what it drives and names what it does not.
fn accept(gate: &ParityGate<'_>, log: &mut PhaseLog) -> Result<(), String> {
    // Phase 2's refusing run left the reworded scrape on disk, so the file
    // already holds what a re-record would write. Plant text no page renders
    // first: now only a genuine scrape can put the panel's words back, and an
    // `accept` that stopped writing `capture.to` is visible instead of inferred.
    gate.plant_baseline(WEB_BASELINE, SENTINEL)?;

    let run = gate.accept()?;
    expect_exit(&run, 0, "3 ACCEPT")?;
    let untouched = line_with(
        &run.output,
        "accept left this cross_surface baseline alone",
        "3 ACCEPT",
    )?;
    expect(untouched, IOS_BASELINE, "3 ACCEPT")?;
    expect(
        &run.output,
        "cross_surface pair is still below threshold after accept",
        "3 ACCEPT",
    )?;

    // The web half is re-recorded from the live page, over the sentinel…
    let captured = gate.baseline(WEB_BASELINE)?;
    if captured.contains(SENTINEL) {
        return Err(format!(
            "3 ACCEPT: accept left the planted sentinel in {WEB_BASELINE}; it did not re-record \
             the web surface from the live page"
        ));
    }
    for line in panel_lines(REWORDED_PAGE)? {
        expect(&captured, &line, "3 ACCEPT")?;
    }
    // …and the iOS half is byte-identical to the file that shipped.
    expect_ios_untouched(gate, "3 ACCEPT")?;
    log.record(
        3,
        "ACCEPT",
        &format!("{WEB_BASELINE} re-recorded from the page, {IOS_BASELINE} named and left alone"),
    );
    Ok(())
}

/// Phase 4 — the point. Accepting did not close the gate, and the next ordinary
/// run says so in the same words as phase 2.
fn still_refused(
    gate: &ParityGate<'_>,
    refused: &GateOutcome,
    log: &mut PhaseLog,
) -> Result<(), String> {
    let run = gate.run()?;
    expect_exit(&run, EXIT_FAIL, "4 STILL REFUSED")?;
    expect(&run.output, "cross_surface mismatch", "4 STILL REFUSED")?;
    if run.code != refused.code {
        return Err(format!(
            "4 STILL REFUSED: the run after accept exited {:?}, the one before it {:?}",
            run.code, refused.code
        ));
    }
    expect_ios_untouched(gate, "4 STILL REFUSED")?;
    log.record(
        4,
        "STILL REFUSED",
        "accept moved the web surface only; the gate stays shut until the device is re-captured",
    );
    Ok(())
}

/// Assert the iOS surface is byte-identical to the one this repository ships.
fn expect_ios_untouched(gate: &ParityGate<'_>, phase: &str) -> Result<(), String> {
    if gate.baseline(IOS_BASELINE)? == shipped_ios_baseline()? {
        return Ok(());
    }
    Err(format!(
        "{phase}: {IOS_BASELINE} was rewritten. Only a device capture writes that surface; \
         a runner that regenerates it turns the parity gate into a comparison with itself."
    ))
}

/// Report a host with no browser, loudly, on the real stderr.
fn report_no_browser(reason: &str) -> Result<(), String> {
    let guidance = "The parity gate needs a browser. Provision one the way the\n\
         runner-full-loop CI lane does:\n\
         \x20 export MIRROIR_PLAYWRIGHT_HOME=$HOME/.cache/mirroir-playwright\n\
         \x20 mkdir -p \"$MIRROIR_PLAYWRIGHT_HOME\" && cd \"$MIRROIR_PLAYWRIGHT_HOME\"\n\
         \x20 npm init -y && npm install @playwright/test && npx playwright install chromium";
    // The lane that owes the loop sets MIRROIR_E2E_REQUIRED; there a missing
    // browser is a false green, so it goes red instead of quietly green.
    if env::var_os("MIRROIR_E2E_REQUIRED").is_some() {
        return Err(format!(
            "PARITY GATE: {reason}, but MIRROIR_E2E_REQUIRED is set. This lane must \
             exercise the gate, not skip it.\n{guidance}"
        ));
    }
    announce(&format!(
        "\nPARITY GATE: NOT RUN — {reason}.\n{guidance}\n\
         Nothing below this line was exercised.\n"
    ));
    Ok(())
}

/// The one line of `haystack` carrying `needle`, so a following assertion reads
/// that message rather than the whole transcript.
fn line_with<'a>(haystack: &'a str, needle: &str, phase: &str) -> Result<&'a str, String> {
    haystack
        .lines()
        .find(|line| line.contains(needle))
        .ok_or_else(|| format!("{phase}: no line carries `{needle}`:\n{haystack}"))
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
fn expect_exit(outcome: &GateOutcome, code: i32, phase: &str) -> Result<(), String> {
    if outcome.code == Some(code) {
        Ok(())
    } else {
        Err(format!(
            "{phase}: exited {:?}, expected {code}.\n{}",
            outcome.code, outcome.output
        ))
    }
}
