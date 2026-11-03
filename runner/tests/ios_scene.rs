// ABOUTME: Pins a `scene:` step end to end: its verdict sets the exit code (0 pass, 66 inconclusive, 1 otherwise).
// ABOUTME: A stub mirroir-mcp replays the byte-exact Swift scene reports; the runner never records a reference for them.

//! Scene suite, driven through the built `mirroir-run` binary with a stub
//! `mirroir-mcp` named by `MIRROIR_MCP_BIN` that hands back a chosen report.
//! The reports are the contract fixtures under `src/target/fixtures/`, which
//! the Swift writer is pinned to. macOS-only: an `ios` block is refused by
//! host elsewhere.

#![cfg(target_os = "macos")]

mod common;

use std::fs;

use common::{Run, Sandbox, repo_path};

/// The exit code for a run whose only failures are inconclusive scenes.
const EXIT_INCONCLUSIVE: i32 = 66;

/// A `mirroir-mcp test` that records its argv and writes
/// `$MIRROIR_TEST_REPORT` to `--report-json`.
const STUB: &str = concat!(
    "#!/bin/sh\n",
    "PATH=/bin:/usr/bin\n",
    "export PATH\n",
    "echo \"$@\" > \"$MIRROIR_TEST_ARGS\"\n",
    "cat \"$MIRROIR_TEST_REPORT\" > \"$3\"\n",
);

/// `target`, `launch`, then the scene at block step 2 — the block shape the
/// scene fixtures were written for.
fn scenario(skill: &str) -> String {
    format!(
        concat!(
            "version: 1\n",
            "name: scene\n",
            "steps:\n",
            "  - target: {{ kind: ios, app: \"Scene Frames\" }}\n",
            "  - launch: \"Scene Frames\"\n",
            "  - scene: {{ skill: {}, budget: {{ max_frames: 3, max_tokens: 200000, max_seconds: 60 }} }}\n",
        ),
        skill
    )
}

fn fixture(name: &str) -> String {
    repo_path(&format!("src/target/fixtures/{name}"))
}

/// Run the scene scenario for `skill` with the stub handing back `report`;
/// returns the run and the argv the stub was handed.
fn run(skill: &str, report: &str) -> Result<(Sandbox, Run, String), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.write("scenarios/scene.ios.yaml", &scenario(skill))?;
    let stub = sandbox.stub_bin("mirroir-mcp", STUB)?;
    let args_path = sandbox.path().join("mirroir-mcp.args");
    let args_text = args_path.display().to_string();
    let report = fixture(report);
    let run = sandbox.run_with_env(
        &["--run-scenario", &scenario],
        &[
            ("MIRROIR_MCP_BIN", &stub),
            ("MIRROIR_TEST_REPORT", &report),
            ("MIRROIR_TEST_ARGS", &args_text),
        ],
    )?;
    let args = fs::read_to_string(&args_path).unwrap_or_default();
    Ok((sandbox, run, args))
}

fn expect(run: &Run, code: i32, fragment: &str) -> Result<(), String> {
    let output = run.output();
    if run.code != Some(code) || !output.contains(fragment) {
        return Err(format!(
            "expected exit {code} naming `{fragment}`, got {:?}\n{output}",
            run.code
        ));
    }
    Ok(())
}

/// A passing scene passes the run. A scene is never compiled, so mirroir-mcp
/// is not asked to record a reference and none appears next to the scenario.
#[test]
fn a_passing_scene_passes_without_recording_a_reference() -> Result<(), String> {
    let (sandbox, run, args) = run("scene-frames-reach", "mirroir-mcp-report-scene-pass.json")?;
    expect(&run, 0, "")?;
    if !args.starts_with("test --report-json ") || args.contains("--compiled-out") {
        return Err(format!("a scene block was asked to record: {args}"));
    }
    if sandbox
        .path()
        .join("scenarios/scene.ios.compiled.json")
        .exists()
    {
        return Err("a reference was promoted for a scene block".to_owned());
    }
    Ok(())
}

/// A scene that ran out of budget is inconclusive: exit 66, not 1.
#[test]
fn an_inconclusive_scene_exits_66() -> Result<(), String> {
    let (_sandbox, run, _) = run(
        "scene-frames-impossible",
        "mirroir-mcp-report-scene-inconclusive.json",
    )?;
    expect(&run, EXIT_INCONCLUSIVE, "is inconclusive: max_frames")
}

/// A block that passed with no verdict for its scene proved nothing about
/// the scene: the run fails rather than passing on the other steps.
#[test]
fn a_passing_report_with_no_scene_entry_is_not_a_pass() -> Result<(), String> {
    let (_sandbox, run, _) = run("scene-frames-reach", "mirroir-mcp-report.json")?;
    expect(&run, 1, "reported no verdict for it")
}

/// A step before the scene failed, so the scene never ran: the block's own
/// failure is the verdict, not a missing scene.
#[test]
fn a_step_failing_before_the_scene_keeps_its_own_error() -> Result<(), String> {
    let (_sandbox, run, _) = run(
        "scene-frames-reach",
        "mirroir-mcp-report-not-evaluated.json",
    )?;
    expect(&run, 1, "not evaluated: verify needs an AI client")?;
    if run.output().contains("reported no verdict") {
        return Err(format!(
            "the missing scene replaced the real failure\n{}",
            run.output()
        ));
    }
    Ok(())
}

/// A scene outside an `ios` block has no device, and a budget key typo has
/// no meaning: `--validate` refuses both before anything runs — the typo at
/// parse, since the budget denies unknown keys.
#[test]
fn validate_refuses_a_stray_scene_and_a_budget_typo() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let cases = [
        (
            "stray.yaml",
            concat!(
                "version: 1\nname: stray\nsteps:\n",
                "  - scene: { skill: s, budget: { max_frames: 3, max_tokens: 1000, max_seconds: 60 } }\n",
            ),
            "step 0 (`scene`) drives an iPhone",
        ),
        (
            "typo.yaml",
            concat!(
                "version: 1\nname: typo\nsteps:\n",
                "  - target: { kind: ios, app: \"Scene Frames\" }\n",
                "  - scene: { skill: s, budget: { max_frames: 3, max_tokens: 1000, max_seconds: 60, max_touches: 2 } }\n",
            ),
            "YAML parse failed",
        ),
    ];
    for (name, body, fragment) in cases {
        let path = sandbox.scenario(name, body)?;
        expect(&sandbox.run(&["--validate", &path])?, 1, fragment)?;
    }
    Ok(())
}
