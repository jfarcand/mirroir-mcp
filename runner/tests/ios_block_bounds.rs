// ABOUTME: Pins the bounds on an `ios` block end to end: a hung mirroir-mcp is killed at its budget, never waited on.
// ABOUTME: An AI-only step inside an ios block is refused by `--validate` and the run alike, before mirroir-mcp is spawned.

//! iOS-block bounds suite, driven through the built `mirroir-run` binary with
//! a stub `mirroir-mcp` named by `MIRROIR_MCP_BIN`. Both cases are macOS-only:
//! elsewhere an `ios` block is refused by host before either bound applies.

#![cfg(target_os = "macos")]

mod common;

use std::time::{Duration, Instant};

use common::Sandbox;

/// Far above the four-second budget the scenario below earns, far below the
/// stub's thousand-second sleep.
const RUN_CEILING: Duration = Duration::from_secs(60);

/// A three-step iOS block (its `target:` included): its budget is four
/// allowances, the last one for the final-screen capture.
const IOS_SCENARIO: &str = concat!(
    "version: 1\n",
    "name: clock on ios\n",
    "steps:\n",
    "  - target: { kind: ios, app: \"Clock\" }\n",
    "  - launch: \"Clock\"\n",
    "  - assert_visible: \"Alarmes\"\n",
);

/// A `mirroir-mcp` that narrates one step and then never returns.
const HANGING_MIRROIR_MCP: &str = concat!(
    "#!/bin/sh\n",
    "PATH=/bin:/usr/bin\n",
    "export PATH\n",
    "echo 'step 1 (launch: \"Clock\")' >&2\n",
    "sleep 1000\n",
);

/// The run fails with the timeout, naming its budget and the stderr the child
/// wrote, inside a bound derived from the steps — not after the child's
/// thousand seconds.
#[test]
fn a_hung_mirroir_mcp_fails_the_run_at_its_budget() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario("clock.yaml", IOS_SCENARIO)?;
    let stub = sandbox.stub_bin("mirroir-mcp", HANGING_MIRROIR_MCP)?;

    let started = Instant::now();
    let run = sandbox.run_with_env(
        &["--run-scenario", &scenario],
        &[
            ("MIRROIR_MCP_BIN", &stub),
            ("MIRROIR_IOS_STEP_ALLOWANCE_S", "1"),
        ],
    )?;
    let elapsed = started.elapsed();

    let output = run.output();
    if !run.is_failure() {
        return Err(format!("a hung block exited {:?}\n{output}", run.code));
    }
    for fragment in ["budget for 3 step(s) and was killed", "step 1 (launch"] {
        if !output.contains(fragment) {
            return Err(format!("the failure does not name `{fragment}`\n{output}"));
        }
    }
    if elapsed >= RUN_CEILING {
        return Err(format!("the run took {elapsed:?}; the budget was 4 s"));
    }
    Ok(())
}

/// `remember:` between two device steps would be skipped by `mirroir-mcp
/// test`. Validate refuses it by name, and the run refuses it before spawning
/// mirroir-mcp at all — the stub would leave a marker if it ran.
#[test]
fn a_remember_inside_an_ios_block_is_refused_before_mirroir_mcp_runs() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario(
        "note.yaml",
        concat!(
            "version: 1\n",
            "name: a note inside the block\n",
            "steps:\n",
            "  - target: { kind: ios, app: \"Clock\" }\n",
            "  - launch: \"Clock\"\n",
            "  - remember: \"the alarm list loaded\"\n",
            "  - assert_visible: \"Alarmes\"\n",
        ),
    )?;
    let marker = sandbox.path().join("mirroir-mcp-ran");
    let stub = sandbox.stub_bin(
        "mirroir-mcp",
        &format!("#!/bin/sh\n: > '{}'\nexit 1\n", marker.display()),
    )?;

    for mode in ["--validate", "--run-scenario"] {
        let run = sandbox.run_with_env(&[mode, &scenario], &[("MIRROIR_MCP_BIN", &stub)])?;
        let output = run.output();
        if !run.is_failure() || !output.contains("step 2 (`remember`) is an AI-only step") {
            return Err(format!(
                "{mode} did not refuse the remember by name\n{output}"
            ));
        }
    }
    if marker.exists() {
        return Err("mirroir-mcp ran for a block the plan refuses".to_owned());
    }
    Ok(())
}
