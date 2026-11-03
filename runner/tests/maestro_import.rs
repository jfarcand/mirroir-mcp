// ABOUTME: End-to-end suite for `mirroir-run import maestro`, driven through the built binary on realistic flows.
// ABOUTME: Every emitted scenario is handed back to `mirroir-run --validate`, so the runner's own parser and plan judge it.

//! `import maestro` suite.
//!
//! The fixtures under `tests/fixtures/maestro/` are a login flow, a settings
//! navigation flow that includes a subflow and uses `scrollUntilVisible`,
//! `repeat` and a platform-gated `runFlow`, and a flow full of commands
//! mirroir cannot run.

mod common;

use std::fs;

use common::{Run, Sandbox, repo_path};

/// The `--app` mapping every fixture flow needs.
const SHOP: &str = "com.example.shop=Shop";

fn fixture(name: &str) -> String {
    repo_path(&format!("tests/fixtures/maestro/{name}"))
}

fn import(sandbox: &Sandbox, flows: &[&str], extra: &[&str]) -> Result<Run, String> {
    let out = sandbox.path().join("scenarios").display().to_string();
    let mut args = vec!["import", "maestro"];
    args.extend_from_slice(flows);
    args.extend_from_slice(&["-o", &out, "--app", SHOP]);
    args.extend_from_slice(extra);
    sandbox.run(&args)
}

fn emitted(sandbox: &Sandbox, stem: &str) -> Result<(String, String), String> {
    let path = sandbox
        .path()
        .join("scenarios")
        .join(format!("{stem}.ios.yaml"));
    let body = fs::read_to_string(&path).map_err(|e| format!("read {}: {e}", path.display()))?;
    Ok((path.display().to_string(), body))
}

/// The steps section of a scenario, comments included, one entry per line.
fn step_lines(body: &str) -> Vec<&str> {
    body.split("steps:\n")
        .nth(1)
        .unwrap_or_default()
        .lines()
        .collect()
}

/// `--validate` accepts the scenario on macOS, where an ios block has an
/// executor, and plans every step as one ios block; elsewhere it refuses it
/// by host — never by its shape.
fn assert_validates(sandbox: &Sandbox, scenario: &str, steps: usize) -> Result<(), String> {
    let run = sandbox.run(&["--validate", scenario])?;
    let output = run.output();
    if cfg!(target_os = "macos") {
        if run.is_failure() || !output.contains(&format!("Some(0..{steps})")) {
            return Err(format!(
                "--validate refused or miscounted {scenario}\n{output}"
            ));
        }
    } else if !run.is_failure() || !output.contains("macOS host") {
        return Err(format!(
            "--validate did not refuse {scenario} by host\n{output}"
        ));
    }
    Ok(())
}

#[test]
fn a_login_flow_imports_step_for_step() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let run = import(&sandbox, &[&fixture("login.yaml")], &[])?;
    if run.is_failure() {
        return Err(format!("import failed\n{}", run.output()));
    }
    let (path, body) = emitted(&sandbox, "login")?;
    if !run.stdout.contains(&path) {
        return Err(format!(
            "the written path was not printed\n{}",
            run.output()
        ));
    }
    for header in [
        "version: 1\n",
        "name: \"Log in\"\n",
        "tags: [\"smoke\", \"auth\"]\n",
    ] {
        if !body.contains(header) {
            return Err(format!("missing `{header}`\n{body}"));
        }
    }
    let expected = vec![
        "  - target: { kind: \"ios\", app: \"Shop\" }",
        "  - reset_app: \"Shop\"",
        "  - launch: \"Shop\"",
        "  - tap: \"Email\"",
        "  - type: \"qa@example.com\"",
        "  # Focus the password field",
        "  - tap: \"Password\"",
        "  - type: \"${PASSWORD}\"",
        "  - press_key: \"return\"",
        "  - wait_for: { label: \"Welcome back\", timeout_s: 7 }",
        "  - screenshot: \"logged-in\"",
    ];
    assert_eq!(step_lines(&body), expected);
    assert_validates(&sandbox, &path, 10)
}

#[test]
fn a_navigation_flow_inlines_subflows_and_unrolls_repeat() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let run = import(&sandbox, &[&fixture("settings-navigation.yaml")], &[])?;
    if run.is_failure() {
        return Err(format!("import failed\n{}", run.output()));
    }
    let (path, body) = emitted(&sandbox, "settings-navigation")?;
    let steps: Vec<&str> = step_lines(&body)
        .into_iter()
        .filter(|line| line.starts_with("  - "))
        .collect();
    let expected = vec![
        "  - target: { kind: \"ios\", app: \"Shop\" }",
        "  - launch: \"Shop\"",
        "  - tap: \"Account\"",
        "  - wait_for: { label: \"Settings\", timeout_s: 7 }",
        "  - scroll_to: \"Notifications\"",
        "  - tap: \"Notifications\"",
        "  - tap: \"Newsletter\"",
        "  - tap: \"Newsletter\"",
        "  - swipe: \"up\"",
        "  - swipe: \"up\"",
        "  - wait_for: { label: \"Saved\", timeout_s: 10 }",
        "  - assert_not_visible: \"Error\"",
    ];
    assert_eq!(steps, expected);
    if !body.contains("runFlow left out — `when: platform: Android` excludes iOS") {
        return Err(format!("the Android-only include was not noted\n{body}"));
    }
    assert_validates(&sandbox, &path, 12)
}

#[test]
fn unsupported_commands_fail_the_import_with_their_lines_and_write_nothing() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let run = import(
        &sandbox,
        &[&fixture("login.yaml"), &fixture("unsupported.yaml")],
        &[],
    )?;
    let output = run.output();
    if !run.is_failure() || !output.contains("4 Maestro item(s) have no mirroir equivalent") {
        return Err(format!("the import did not refuse the flow\n{output}"));
    }
    for item in [
        "unsupported.yaml:4 (command 1) `launchApp`: `clearState`",
        "unsupported.yaml:6 (command 2) `tapOn`: `id`: id selectors match the accessibility tree",
        "unsupported.yaml:9 (command 4) `back`",
        "unsupported.yaml:10 (command 5) `evalScript`",
    ] {
        if !output.contains(item) {
            return Err(format!("missing `{item}`\n{output}"));
        }
    }
    if sandbox.path().join("scenarios").exists() {
        return Err("a refused import wrote scenarios".to_owned());
    }
    Ok(())
}

#[test]
fn skip_unsupported_warns_and_records_each_skipped_command() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let run = import(
        &sandbox,
        &[&fixture("unsupported.yaml")],
        &["--skip-unsupported"],
    )?;
    let output = run.output();
    if run.is_failure() {
        return Err(format!("import failed\n{output}"));
    }
    if output
        .matches("skipped a Maestro command with no mirroir equivalent")
        .count()
        != 4
    {
        return Err(format!("expected four warnings\n{output}"));
    }
    let (path, body) = emitted(&sandbox, "unsupported")?;
    let lines = step_lines(&body);
    let skipped = lines
        .iter()
        .filter(|line| line.starts_with("  # skipped (no mirroir equivalent): "))
        .count();
    let steps = lines.iter().filter(|line| line.starts_with("  - ")).count();
    if skipped != 4 || steps != 3 {
        return Err(format!("expected 4 skipped comments and 3 steps\n{body}"));
    }
    assert_validates(&sandbox, &path, 3)
}

#[test]
fn a_bundle_id_without_an_app_name_is_unsupported() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let out = sandbox.path().join("scenarios").display().to_string();
    let run = sandbox.run(&["import", "maestro", &fixture("login.yaml"), "-o", &out])?;
    let output = run.output();
    if !run.is_failure() || !output.contains("pass `--app com.example.shop=<name>`") {
        return Err(format!("the unmapped bundle id was not refused\n{output}"));
    }
    Ok(())
}

#[test]
fn a_run_flow_cycle_is_refused() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let run = import(
        &sandbox,
        &[&fixture("cycle-a.yaml")],
        &["--skip-unsupported"],
    )?;
    let output = run.output();
    if !run.is_failure() || !output.contains("runFlow cycle") || !output.contains("cycle-b.yaml") {
        return Err(format!("the include cycle was not refused\n{output}"));
    }
    Ok(())
}

#[test]
fn two_flows_with_one_stem_are_refused() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let other = sandbox.write("elsewhere/login.yaml", "- tapOn: \"Go\"\n")?;
    let run = import(&sandbox, &[&fixture("login.yaml"), &other], &[])?;
    let output = run.output();
    if !run.is_failure() || !output.contains("both import to") {
        return Err(format!("the colliding stems were not refused\n{output}"));
    }
    Ok(())
}
