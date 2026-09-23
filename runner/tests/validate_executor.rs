// ABOUTME: Pins that `--validate` resolves an executor for the plan it builds, not just the plan's shape.
// ABOUTME: A scenario nothing here can run is refused by its real reason — the target kind, the host, or the missing browser.

//! Executor-resolution suite for `--validate`.
//!
//! `--validate` builds the execution plan a run would execute. A plan no
//! executor can take is not a valid scenario, so both shapes below are refused
//! at validate time, with the same verdict the run path reaches — the two must
//! never disagree about one file.

mod common;

use common::Sandbox;

/// An iOS scenario, as `generate_skill emit=true` writes one.
const IOS_SCENARIO: &str = concat!(
    "version: 1\n",
    "name: acme on ios\n",
    "steps:\n",
    "  - target:\n",
    "      kind: ios\n",
    "      app: \"Acme\"\n",
    "  - launch: \"Acme\"\n",
    "  - tap: \"Sign in\"\n",
    "  - assert_visible: \"Welcome\"\n",
);

/// On macOS an `ios` block has an executor — `mirroir-mcp test` — so validate
/// accepts it and names the block. Running it without mirroir-mcp installed
/// is an error naming the missing binary, never a pass.
#[cfg(target_os = "macos")]
#[test]
fn validate_accepts_an_ios_block_and_the_run_needs_mirroir_mcp() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario("ios-target.yaml", IOS_SCENARIO)?;

    let validated = sandbox.run(&["--validate", &scenario])?;
    if validated.is_failure() {
        return Err(format!(
            "validate refused an ios block on macOS.\n{}",
            validated.output()
        ));
    }
    if !validated.output().contains("Some(0..4)") {
        return Err(format!(
            "validate did not plan the ios block\n{}",
            validated.output()
        ));
    }

    let run = sandbox.run(&["--run-scenario", &scenario])?;
    if !run.is_failure() || !run.output().contains("mirroir-mcp is not installed") {
        return Err(format!(
            "an ios block with no mirroir-mcp exited {:?}.\n{}",
            run.code,
            run.output()
        ));
    }
    Ok(())
}

/// Off macOS the iOS block cannot run: validate refuses it by name, and the
/// run path agrees.
#[cfg(not(target_os = "macos"))]
#[test]
fn validate_refuses_an_ios_block_off_macos() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario("ios-target.yaml", IOS_SCENARIO)?;
    for mode in ["--validate", "--run-scenario"] {
        let run = sandbox.run(&[mode, &scenario])?;
        if !run.is_failure() || !run.output().contains("macOS host") {
            return Err(format!(
                "{mode} did not refuse the ios block by host.\n{}",
                run.output()
            ));
        }
    }
    Ok(())
}

/// A `macos` window is driven by `mirroir-mcp test` directly; mirroir-run
/// opens no block for it, and says so by name rather than blaming contiguity.
#[test]
fn validate_rejects_a_target_kind_with_no_executor() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario(
        "macos-target.yaml",
        "version: 1\nname: window\nsteps:\n  - target: { kind: macos }\n  - tap: \"Build\"\n",
    )?;
    let validated = sandbox.run(&["--validate", &scenario])?;
    let output = validated.output();
    if !validated.is_failure() || !output.contains("kind: macos") || output.contains("splits its") {
        return Err(format!(
            "validate did not refuse the macos target by kind.\n{output}"
        ));
    }
    let run = sandbox.run(&["--run-scenario", &scenario])?;
    if !run.is_failure() {
        return Err(format!(
            "the macos target exited {:?} on --run-scenario.\n{}",
            run.code,
            run.output()
        ));
    }
    Ok(())
}

/// Web steps compile to a Playwright invocation, which needs a browser to open.
/// A scenario that declares no `target:` at all still plans a web block, and
/// validating it as if it could run is the same lie as accepting a target kind
/// nothing executes.
#[test]
fn validate_rejects_a_web_block_with_no_web_target() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario(
        "no-target.yaml",
        concat!(
            "version: 1\n",
            "name: acme with no declared surface\n",
            "steps:\n",
            "  - tap: \"Sign in\"\n",
            "  - assert_visible: \"Welcome\"\n",
        ),
    )?;

    let validated = sandbox.run(&["--validate", &scenario])?;
    if !validated.is_failure() {
        return Err(format!(
            "validate accepted a web block with no browser (exit {:?}).\n{}",
            validated.code,
            validated.output()
        ));
    }
    let output = validated.output();
    for fragment in ["target: { kind: web", "tap"] {
        if !output.contains(fragment) {
            return Err(format!(
                "the validate failure did not name `{fragment}`\n{output}"
            ));
        }
    }

    // The run path refuses the same file — validate and run agree on it.
    let run = sandbox.run(&["--run-scenario", &scenario])?;
    if !run.is_failure() {
        return Err(format!(
            "the browserless web block exited {:?} on --run-scenario.\n{}",
            run.code,
            run.output()
        ));
    }
    Ok(())
}

/// A scenario that opens on the browser and then names the phone plans two
/// blocks. The failure this pins is the phone's `tap:` compiling into the
/// browser's spec, where Playwright would happily click whatever label it is
/// handed: the emitted spec must carry the web block only.
#[cfg(target_os = "macos")]
#[test]
fn a_web_block_then_an_ios_block_never_compiles_the_phone_into_the_browser() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario(
        "web-then-ios.yaml",
        concat!(
            "version: 1\n",
            "name: web then ios\n",
            "steps:\n",
            "  - target:\n",
            "      kind: web\n",
            "      url: \"http://127.0.0.1:9/\"\n",
            "  - assert_visible: \"Dashboard\"\n",
            "  - target:\n",
            "      kind: ios\n",
            "      app: \"Acme\"\n",
            "  - tap: \"Sign in\"\n",
        ),
    )?;

    let validated = sandbox.run(&["--validate", &scenario])?;
    let output = validated.output();
    if validated.is_failure() || !output.contains("Some(0..2)") || !output.contains("Some(2..4)") {
        return Err(format!("validate did not plan both blocks\n{output}"));
    }

    let emitted = sandbox.run(&["--emit", "playwright", &scenario])?;
    if emitted.is_failure() {
        return Err(format!(
            "`--emit playwright` refused a valid two-block scenario\n{}",
            emitted.output()
        ));
    }
    let spec = sandbox.emitted_spec("web-then-ios")?;
    if spec.contains("\"Sign in\"") || !spec.contains("\"Dashboard\"") {
        return Err(format!(
            "the phone's tap compiled into the browser spec\n{spec}"
        ));
    }
    Ok(())
}
