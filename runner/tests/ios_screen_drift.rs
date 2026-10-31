// ABOUTME: iOS screen drift → accept end to end: an ios block's screens against its `<scenario>.compiled.json`.
// ABOUTME: A stub mirroir-mcp replays byte-exact Swift reports; the runner compares, records, and accepts.

//! The fixtures under `tests/fixtures/compiled/` are written by the Swift
//! `CompiledDriftContractTests`: the scenario, the compiled reference a
//! passing run of it records, and two reports — one whose screens match the
//! reference, one where the tap landed on London instead of Cupertino. A stub
//! `mirroir-mcp` named by `MIRROIR_MCP_BIN` hands back the chosen report and,
//! when asked to record, writes the chosen compiled skill. macOS-only: an ios
//! block is refused by host elsewhere.

#![cfg(target_os = "macos")]

mod common;

use std::fs;
use std::path::PathBuf;

use common::{Run, Sandbox, repo_path};

/// The verdict exit code for DRIFT.
const EXIT_DRIFT: i32 = 65;

/// Where the scenario sits inside the sandbox.
const SCENARIO: &str = "scenarios/world-clock.ios.yaml";

/// The reference the runner looks for next to [`SCENARIO`].
const REFERENCE: &str = "scenarios/world-clock.ios.compiled.json";

/// A `mirroir-mcp test` that records its argv, writes `$MIRROIR_TEST_REPORT`
/// to `--report-json`, and — when handed `--compiled-out` — writes
/// `$MIRROIR_TEST_COMPILED` there, as Swift does after a pass.
const STUB: &str = concat!(
    "#!/bin/sh\n",
    "PATH=/bin:/usr/bin\n",
    "export PATH\n",
    "echo \"$@\" > \"$MIRROIR_TEST_ARGS\"\n",
    "cat \"$MIRROIR_TEST_REPORT\" > \"$3\"\n",
    "while [ $# -gt 0 ]; do\n",
    "  if [ \"$1\" = --compiled-out ] && [ -n \"$MIRROIR_TEST_COMPILED\" ]; then\n",
    "    cp \"$MIRROIR_TEST_COMPILED\" \"$2\"\n",
    "  fi\n",
    "  shift\n",
    "done\n",
);

fn fixture(name: &str) -> String {
    repo_path(&format!("tests/fixtures/compiled/{name}"))
}

fn read(path: &str) -> Result<String, String> {
    fs::read_to_string(path).map_err(|e| format!("read {path}: {e}"))
}

/// A sandbox holding the fixture scenario, its reference when `with_reference`,
/// and the stub.
struct Case {
    sandbox: Sandbox,
    scenario: String,
    stub: String,
}

impl Case {
    fn new(with_reference: bool) -> Result<Self, String> {
        let sandbox = Sandbox::new()?;
        let scenario = sandbox.write(SCENARIO, &read(&fixture("world-clock.ios.yaml"))?)?;
        if with_reference {
            sandbox.write(REFERENCE, &read(&fixture("world-clock.ios.compiled.json"))?)?;
        }
        let stub = sandbox.stub_bin("mirroir-mcp", STUB)?;
        Ok(Self {
            sandbox,
            scenario,
            stub,
        })
    }

    fn reference(&self) -> PathBuf {
        self.sandbox.path().join(REFERENCE)
    }

    fn args_path(&self) -> String {
        self.sandbox
            .path()
            .join("mirroir-mcp.args")
            .display()
            .to_string()
    }

    fn handed_args(&self) -> Result<String, String> {
        read(&self.args_path())
    }

    fn drift_log(&self) -> PathBuf {
        self.sandbox.path().join(".harness/drift-log.md")
    }

    /// Run the scenario (`accept` when `accept`) with `report` handed back and
    /// `compiled` written on a `--compiled-out` (none when empty).
    fn run(&self, accept: bool, report: &str, compiled: &str) -> Result<Run, String> {
        let args_path = self.args_path();
        let env = [
            ("MIRROIR_MCP_BIN", self.stub.as_str()),
            ("MIRROIR_TEST_REPORT", report),
            ("MIRROIR_TEST_COMPILED", compiled),
            ("MIRROIR_TEST_ARGS", args_path.as_str()),
        ];
        if accept {
            self.sandbox
                .run_outside_ci(&["accept", "--run-scenario", &self.scenario], &env)
        } else {
            self.sandbox
                .run_with_env(&["--run-scenario", &self.scenario], &env)
        }
    }
}

/// Every screen matches the reference: a pass, no candidate, and nothing is
/// re-recorded — mirroir-mcp is not asked to record.
#[test]
fn matching_screens_pass_without_recording() -> Result<(), String> {
    let case = Case::new(true)?;
    let run = case.run(false, &fixture("report-match.json"), "")?;
    if run.code != Some(0) {
        return Err(format!(
            "expected a pass, got {:?}\n{}",
            run.code,
            run.output()
        ));
    }
    if case.drift_log().exists() {
        return Err("a matching run filed a drift candidate".to_owned());
    }
    let args = case.handed_args()?;
    if args.contains("--compiled-out") {
        return Err(format!(
            "a run with a reference was asked to record: {args}"
        ));
    }
    Ok(())
}

/// The tap landed on London: DRIFT (exit 65), the candidate names the step
/// and the texts, and the reference is left for a human to accept.
#[test]
fn a_moved_screen_is_drift_naming_the_step_and_texts() -> Result<(), String> {
    let case = Case::new(true)?;
    let before = read(&case.reference().display().to_string())?;
    let run = case.run(false, &fixture("report-drift.json"), "")?;
    if run.code != Some(EXIT_DRIFT) {
        return Err(format!(
            "expected DRIFT, got {:?}\n{}",
            run.code,
            run.output()
        ));
    }
    let log = read(&case.drift_log().display().to_string())?;
    for fragment in [
        "| fingerprint_similarity | 0.750 | 0.850 |",
        "ios block step 2",
        "missing \"Cupertino\"; new \"London\"",
    ] {
        if !log.contains(fragment) {
            return Err(format!("the drift log lacks `{fragment}`:\n{log}"));
        }
    }
    if read(&case.reference().display().to_string())? != before {
        return Err("a drifted run rewrote the reference".to_owned());
    }
    Ok(())
}

/// The scenario was edited after the reference was recorded: the screens
/// still match, and the stale reference is a candidate, not a silent pass.
#[test]
fn an_edited_scenario_makes_its_reference_a_candidate() -> Result<(), String> {
    let case = Case::new(true)?;
    let edited = format!("{}# reviewed\n", read(&case.scenario)?);
    fs::write(&case.scenario, edited).map_err(|e| format!("edit the scenario: {e}"))?;
    let run = case.run(false, &fixture("report-match.json"), "")?;
    if run.code != Some(EXIT_DRIFT) {
        return Err(format!(
            "expected DRIFT, got {:?}\n{}",
            run.code,
            run.output()
        ));
    }
    let log = read(&case.drift_log().display().to_string())?;
    if !log.contains("| compiled_source_changed | n/a | n/a |") {
        return Err(format!("the stale reference was not filed:\n{log}"));
    }
    Ok(())
}

/// No reference yet: mirroir-mcp is asked to record one from the scenario,
/// and the green run writes it next to the scenario.
#[test]
fn a_first_green_run_records_the_reference() -> Result<(), String> {
    let case = Case::new(false)?;
    let compiled = fixture("world-clock.ios.compiled.json");
    let run = case.run(false, &fixture("report-match.json"), &compiled)?;
    if run.code != Some(0) {
        return Err(format!(
            "expected a pass, got {:?}\n{}",
            run.code,
            run.output()
        ));
    }
    let args = case.handed_args()?;
    let source = format!("--compiled-source {}", case.scenario);
    if !args.contains("--compiled-out ") || !args.contains(&source) {
        return Err(format!("mirroir-mcp was not asked to record: {args}"));
    }
    if read(&case.reference().display().to_string())? != read(&compiled)? {
        return Err("the recorded reference is not what mirroir-mcp wrote".to_owned());
    }
    Ok(())
}

/// A block asked to record that passes without writing a compiled skill fails
/// the run: the next run would otherwise have nothing to compare against.
#[test]
fn a_pass_that_records_nothing_fails() -> Result<(), String> {
    let case = Case::new(false)?;
    let run = case.run(false, &fixture("report-match.json"), "")?;
    if !run.is_failure()
        || !run
            .output()
            .contains("recorded no compiled screen reference")
    {
        return Err(format!(
            "expected a refusal, got {:?}\n{}",
            run.code,
            run.output()
        ));
    }
    if case.reference().exists() {
        return Err("a reference appeared from nowhere".to_owned());
    }
    Ok(())
}

/// `accept` over a drifted screen: mirroir-mcp is asked to record even though
/// a reference exists, and the reviewed screens replace it.
#[test]
fn accept_rerecords_the_reference_from_the_drifted_run() -> Result<(), String> {
    let case = Case::new(true)?;
    let accepted = read(&fixture("world-clock.ios.compiled.json"))?.replace("Cupertino", "London");
    let accepted_path = case.sandbox.write("accepted.compiled.json", &accepted)?;
    let run = case.run(true, &fixture("report-drift.json"), &accepted_path)?;
    if run.code != Some(0) {
        return Err(format!("accept exited {:?}\n{}", run.code, run.output()));
    }
    let args = case.handed_args()?;
    if !args.contains("--compiled-out ") {
        return Err(format!("accept did not ask mirroir-mcp to record: {args}"));
    }
    if read(&case.reference().display().to_string())? != accepted {
        return Err("accept did not replace the reference".to_owned());
    }
    Ok(())
}
