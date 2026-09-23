// ABOUTME: Pins the orphan-baseline guard — a committed .ios.txt no declared scenario compares fails the sample.
// ABOUTME: Companion cases prove the guard fires only on a true orphan, never on a green sample or an unselected tier.

//! Orphan iOS-baseline regression suite.
//!
//! Each test drives the built `mirroir-run` binary against a sample whose
//! `baselines/` directory either is or is not read by the scenarios it declares.

mod common;

use common::Sandbox;

/// Plant a sample whose single `must_pass` scenario evaluates something and
/// passes, and return the sample directory's path. `baseline` names an extra
/// `baselines/` file to commit alongside it, if any.
fn plant_sample_with_baseline(sandbox: &Sandbox, baseline: Option<&str>) -> Result<String, String> {
    sandbox.write(
        "sample/scenarios/smoke.yaml",
        "version: 1\nname: declared pass\nsteps:\n  - report: pass\n",
    )?;
    if let Some(name) = baseline {
        sandbox.write(
            &format!("sample/baselines/{name}"),
            "Order total 42 dollars\nShip to Montreal\n",
        )?;
    }
    sandbox.write(
        "sample/SAMPLE.md",
        concat!(
            "# Demo\n\n",
            "```yaml\n",
            "version: 1\n",
            "session:\n",
            "  boot:\n",
            "    command: \"true\"\n",
            "  scenarios:\n",
            "    must_pass:\n",
            "      - scenarios/smoke.yaml\n",
            "```\n",
        ),
    )?;
    Ok(sandbox.path().join("sample").display().to_string())
}

/// An iOS baseline is captured on a surface this binary drives no executor
/// for, so the only thing that ever reads one is a `cross_surface:` step
/// naming it. Committed into a sample whose scenarios name it nowhere, it is
/// read by nothing and the sample reports green with the parity gate it was
/// captured for absent — the silent green a `.ios.txt` file exists to close.
#[test]
fn an_orphan_ios_baseline_is_not_a_pass() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let sample = plant_sample_with_baseline(&sandbox, Some("checkout.ios.txt"))?;
    let home = sandbox.path().display().to_string();

    let run = sandbox.run_with_env(&["--sample", &sample], &[("HOME", &home)])?;
    if !run.is_failure() {
        return Err(format!(
            "a sample carrying an unreferenced baselines/checkout.ios.txt exited {:?}; nothing compared it, so it is not a pass.\n{}",
            run.code,
            run.output()
        ));
    }
    let output = run.output();
    if !output.contains("checkout.ios.txt") {
        return Err(format!(
            "the refusal never names the orphan baseline:\n{output}"
        ));
    }
    Ok(())
}

/// The companion: the very same sample without that file is green. A guard
/// that merely made every sample fail would pass the test above and fail this
/// one.
#[test]
fn the_same_sample_without_the_orphan_baseline_stays_green() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let sample = plant_sample_with_baseline(&sandbox, None)?;
    let home = sandbox.path().display().to_string();

    let run = sandbox.run_with_env(&["--sample", &sample], &[("HOME", &home)])?;
    if run.is_failure() {
        return Err(format!(
            "a sample with no baselines/ directory exited {:?}; the guard fired where there is nothing to account for.\n{}",
            run.code,
            run.output()
        ));
    }
    Ok(())
}

/// The gate's other half: a baseline the sample *does* compare, on a run whose
/// `--scenarios` set leaves that scenario out. The sample is well formed — its
/// `must_pass` parity scenario names the capture — and the informational tier
/// has to stay runnable, so this is the tier choice the invocation made, not an
/// orphan capture.
#[test]
fn a_baseline_named_by_an_unselected_tier_still_runs_the_other_tier() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    sandbox.write(
        "sample/scenarios/parity.yaml",
        concat!(
            "version: 1\nname: parity\nsteps:\n",
            "  - cross_surface:\n",
            "      response_files:\n",
            "        - \"${MIRROIR_SAMPLE_DIR}/baselines/parity.web.txt\"\n",
            "        - \"${MIRROIR_SAMPLE_DIR}/baselines/parity.ios.txt\"\n",
            "      min_similarity: 0.5\n",
        ),
    )?;
    sandbox.write(
        "sample/scenarios/smoke.yaml",
        "version: 1\nname: declared pass\nsteps:\n  - report: pass\n",
    )?;
    for half in ["parity.ios.txt", "parity.web.txt"] {
        sandbox.write(
            &format!("sample/baselines/{half}"),
            "Order total 42 dollars\nShip to Montreal\n",
        )?;
    }
    sandbox.write(
        "sample/SAMPLE.md",
        concat!(
            "# Demo\n\n",
            "```yaml\n",
            "version: 1\n",
            "session:\n",
            "  boot:\n",
            "    command: \"true\"\n",
            "  scenarios:\n",
            "    must_pass:\n",
            "      - scenarios/parity.yaml\n",
            "    nice_to_pass:\n",
            "      - scenarios/smoke.yaml\n",
            "```\n",
        ),
    )?;
    let sample = sandbox.path().join("sample").display().to_string();
    let home = sandbox.path().display().to_string();

    let run = sandbox.run_with_env(
        &["--sample", &sample, "--scenarios", "nice-to-pass"],
        &[("HOME", &home)],
    )?;
    if run.is_failure() {
        return Err(format!(
            "`--scenarios nice-to-pass` exited {:?} on a sample whose must_pass scenario compares baselines/parity.ios.txt; the informational tier must stay runnable.\n{}",
            run.code,
            run.output()
        ));
    }
    Ok(())
}
