// ABOUTME: Pins the paths on which a scenario used to exit 0 without evaluating anything.
// ABOUTME: Every case asserts a non-zero exit — a run the runner cannot substantiate is never a pass.

//! Silent-pass regression suite.
//!
//! Each test drives the built `mirroir-run` binary against a scenario that
//! used to exit 0 while evaluating nothing, and asserts the runner now refuses
//! to call it a pass.

mod common;

use std::fmt::Write as _;
use std::fs;

use common::Sandbox;

/// `- report: fail` is the scenario author saying "this run failed". Skipping
/// it turns a declared failure into a green run, so the runner must exit
/// non-zero — and `- report: pass` must still exit 0.
#[test]
fn report_fail_fails_the_scenario() -> Result<(), String> {
    let sandbox = Sandbox::new()?;

    let failing = sandbox.scenario(
        "report-fail.yaml",
        "version: 1\nname: declared failure\nsteps:\n  - report: fail\n",
    )?;
    let run = sandbox.run(&["--run-scenario", &failing])?;
    if !run.is_failure() {
        return Err(format!(
            "`- report: fail` exited {:?}; a declared failure must not be a pass.\n{}",
            run.code,
            run.output()
        ));
    }

    let passing = sandbox.scenario(
        "report-pass.yaml",
        "version: 1\nname: declared pass\nsteps:\n  - report: pass\n",
    )?;
    let run = sandbox.run(&["--run-scenario", &passing])?;
    if run.is_failure() {
        return Err(format!(
            "`- report: pass` exited {:?}; a declared pass must stay green.\n{}",
            run.code,
            run.output()
        ));
    }
    Ok(())
}

/// A web scenario whose `target:` points at a port nothing is listening on
/// must never be reported green. There must also be no flag that skips the
/// web block and calls the remainder a pass: `--no-playwright` was exactly
/// that escape hatch and is gone.
#[test]
fn web_target_on_dead_port_has_no_skip_escape_hatch() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario(
        "dead-port.yaml",
        concat!(
            "version: 1\n",
            "name: web target on a dead port\n",
            "steps:\n",
            "  - target:\n",
            "      kind: web\n",
            "      browsers: [chrome]\n",
            "      url: \"http://127.0.0.1:9/\"\n",
            "  - assert_visible: \"Dashboard\"\n",
        ),
    )?;

    let skipped = sandbox.run(&["--run-scenario", &scenario, "--no-playwright"])?;
    if !skipped.is_failure() {
        return Err(format!(
            "--no-playwright exited {:?}: the web block was skipped and the run still passed.\n{}",
            skipped.code,
            skipped.output()
        ));
    }

    let run = sandbox.run(&["--run-scenario", &scenario])?;
    if !run.is_failure() {
        return Err(format!(
            "web scenario on a dead port exited {:?}; assertions that never ran are not a pass.\n{}",
            run.code,
            run.output()
        ));
    }
    Ok(())
}

/// A scenario whose only assertion sits inside a `condition:` evaluates
/// nothing at all: the runner has no live-surface evaluator for `if_visible`,
/// so the branch — and the `assert_visible` inside it — is skipped. Reporting
/// that as a pass is the same lie as skipping the web block.
#[test]
fn assertion_buried_in_a_condition_is_not_a_pass() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let scenario = sandbox.scenario(
        "condition-only.yaml",
        concat!(
            "version: 1\n",
            "name: assertion hidden inside a condition\n",
            "steps:\n",
            "  - condition:\n",
            "      if_visible: \"Cookie banner\"\n",
            "      then:\n",
            "        - tap: \"Accept all\"\n",
            "      else:\n",
            "        - assert_visible: \"Dashboard\"\n",
        ),
    )?;

    let run = sandbox.run(&["--run-scenario", &scenario])?;
    if !run.is_failure() {
        return Err(format!(
            "condition-only scenario exited {:?}; nothing was evaluated, so it is not a pass.\n{}",
            run.code,
            run.output()
        ));
    }
    Ok(())
}

/// Plant a `.mirroir/` plan whose only entry lives under `plan.nice_to_pass`,
/// optionally with a `default_set:` line. The entry is a local sample whose
/// directory exists but carries no `SAMPLE.md`, so selecting it fails loudly
/// on the manifest rather than on composition.
fn plant_nice_to_pass_only_plan(
    sandbox: &Sandbox,
    default_set: Option<&str>,
) -> Result<String, String> {
    sandbox.write(".mirroir/samples/demo/scenarios/.keep", "")?;
    let default_line = default_set.map_or_else(String::new, |set| format!("default_set: {set}\n"));
    sandbox.write(
        ".mirroir/mirroir.yaml",
        &format!(
            concat!(
                "version: 1\n",
                "{}",
                "plan:\n",
                "  nice_to_pass:\n",
                "    - name: demo\n",
                "      local: samples/demo\n",
                "      boot:\n",
                "        command: \"true\"\n",
            ),
            default_line
        ),
    )
}

/// A plan that declares entries only under `nice_to_pass` and names no
/// `default_set:` used to select the empty `must_pass` tier, compose zero
/// samples, and exit 0 with `"samples": []` — a green run over a plan that
/// declares real work. The selection has to refuse instead, and say which
/// tier does hold the entries.
#[test]
fn plan_with_only_nice_to_pass_entries_is_not_a_pass() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let config = plant_nice_to_pass_only_plan(&sandbox, None)?;
    let home = sandbox.path().display().to_string();

    let run = sandbox.run_with_env(&["--config", &config], &[("HOME", &home)])?;
    if !run.is_failure() {
        return Err(format!(
            "a plan whose only entry sits in nice_to_pass exited {:?}; selecting nothing is not a pass.\n{}",
            run.code,
            run.output()
        ));
    }
    let output = run.output();
    if !output.contains("nice_to_pass") {
        return Err(format!(
            "the refusal never names the tier that holds the entries:\n{output}"
        ));
    }
    if !output.contains("default_set") || !output.contains("--scenarios") {
        return Err(format!(
            "the refusal never names the two ways to select the entries:\n{output}"
        ));
    }
    Ok(())
}

/// The companion to the test above: naming the set the entries live in makes
/// the very same plan select them. The run still fails — the local sample has
/// no `SAMPLE.md` — but on the manifest, not on the selection. A fix that
/// merely made every plan fail would pass the test above and fail this one.
#[test]
fn default_set_all_selects_the_entry_the_bare_run_filtered_out() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let config = plant_nice_to_pass_only_plan(&sandbox, Some("all"))?;
    let home = sandbox.path().display().to_string();

    let run = sandbox.run_with_env(&["--config", &config], &[("HOME", &home)])?;
    if !run.is_failure() {
        return Err(format!(
            "`default_set: all` over a sample with no SAMPLE.md exited {:?}.\n{}",
            run.code,
            run.output()
        ));
    }
    let output = run.output();
    if !output.contains("SAMPLE.md") {
        return Err(format!(
            "`default_set: all` did not reach the sample: nothing mentions SAMPLE.md.\n{output}"
        ));
    }
    if output.contains("selected 0 of") {
        return Err(format!(
            "`default_set: all` still filtered the entry out.\n{output}"
        ));
    }
    Ok(())
}

/// The other half of the same hole: when a set *does* select something, the
/// entries it filtered out used to vanish from the run summary entirely —
/// `"skipped": 0` while an entry of the plan sat unselected. The report has to
/// account for every entry the plan declares, or it is not a record of the plan.
#[test]
fn a_set_filtered_entry_is_reported_as_skipped_not_dropped() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    sandbox.write(".mirroir/samples/core/scenarios/.keep", "")?;
    sandbox.write(".mirroir/samples/extra/scenarios/.keep", "")?;
    let config = sandbox.write(
        ".mirroir/mirroir.yaml",
        concat!(
            "version: 1\n",
            "plan:\n",
            "  must_pass:\n",
            "    - name: core\n",
            "      local: samples/core\n",
            "      boot:\n",
            "        command: \"true\"\n",
            "  nice_to_pass:\n",
            "    - name: extra\n",
            "      local: samples/extra\n",
            "      boot:\n",
            "        command: \"true\"\n",
        ),
    )?;
    let home = sandbox.path().display().to_string();

    let run = sandbox.run_with_env(&["--config", &config], &[("HOME", &home)])?;
    if !run.is_failure() {
        return Err(format!(
            "the must_pass sample has no SAMPLE.md; the run exited {:?}.\n{}",
            run.code,
            run.output()
        ));
    }

    let report_path = sandbox.path().join("mirroir-run-report.json");
    let report = fs::read_to_string(&report_path).map_err(|e| format!("read run report: {e}"))?;
    if !report.contains("\"skipped\": 1") {
        return Err(format!(
            "`extra` was filtered out by the must_pass set and the totals never counted it:\n{report}"
        ));
    }
    if !report.contains("\"samples\": 2") {
        return Err(format!(
            "the summary accounts for fewer samples than the plan declares:\n{report}"
        ));
    }
    if !report.contains("\"name\": \"extra\"") {
        return Err(format!(
            "the filtered entry is missing from samples[] entirely:\n{report}"
        ));
    }
    Ok(())
}

/// Following the remedy the plan-level refusal prints must not land the user
/// in the same hole one layer down. A `SAMPLE.md` declares its own tiers,
/// independently of which plan tier the entry sits in, so `default_set:
/// nice_to_pass` over a sample whose scenarios sit under `must_pass:` selects
/// no scenario at all. The sample used to report `pass` for replaying nothing
/// — a worse silent green than the one the plan-level guard closed, because
/// the report positively claims a sample passed.
#[test]
fn a_set_that_selects_no_scenario_inside_the_sample_is_not_a_pass() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let config = plant_nice_to_pass_only_plan(&sandbox, Some("nice_to_pass"))?;
    sandbox.write(
        ".mirroir/samples/demo/scenarios/smoke.yaml",
        "version: 1\nname: declared pass\nsteps:\n  - report: pass\n",
    )?;
    sandbox.write(
        ".mirroir/samples/demo/SAMPLE.md",
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
    let home = sandbox.path().display().to_string();

    let run = sandbox.run_with_env(&["--config", &config], &[("HOME", &home)])?;
    if !run.is_failure() {
        return Err(format!(
            "`default_set: nice_to_pass` over a SAMPLE.md that declares only must_pass scenarios exited {:?}; zero scenarios ran, so it is not a pass.\n{}",
            run.code,
            run.output()
        ));
    }
    let output = run.output();
    if !output.contains("must_pass") || !output.contains("nice_to_pass") {
        return Err(format!(
            "the refusal names neither the set in effect nor the tier that holds the scenarios:\n{output}"
        ));
    }

    let report_path = sandbox.path().join("mirroir-run-report.json");
    let report = fs::read_to_string(&report_path).map_err(|e| format!("read run report: {e}"))?;
    if report.contains("\"passed\": 1") {
        return Err(format!(
            "the summary claims a sample passed while zero of its scenarios ran:\n{report}"
        ));
    }
    Ok(())
}

/// Plant a `must_pass` plan of `entries` — `(name, skip)` pairs — each a
/// local sample whose `SAMPLE.md` declares one `report: pass` scenario, so an
/// entry that is actually replayed passes.
fn plant_must_pass_plan(sandbox: &Sandbox, entries: &[(&str, bool)]) -> Result<String, String> {
    let mut plan = String::from("version: 1\nplan:\n  must_pass:\n");
    for (name, skip) in entries {
        sandbox.write(
            &format!(".mirroir/samples/{name}/scenarios/smoke.yaml"),
            "version: 1\nname: declared pass\nsteps:\n  - report: pass\n",
        )?;
        sandbox.write(
            &format!(".mirroir/samples/{name}/SAMPLE.md"),
            concat!(
                "# Sample\n\n",
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
        write!(
            plan,
            "    - name: {name}\n      local: samples/{name}\n      boot:\n        command: \"true\"\n"
        )
        .map_err(|e| format!("render plan entry: {e}"))?;
        if *skip {
            plan.push_str("      skip: true\n");
        }
    }
    sandbox.write(".mirroir/mirroir.yaml", &plan)
}

/// The selection guard counts entries a set *selects*, and an entry marked
/// `skip: true` is selected and then never replayed. A plan whose every
/// selected entry was skipped used to exit 0 with `verdict=pass` over zero
/// replayed samples — the exact tree `generate_skill emit=true` writes.
#[test]
fn a_plan_whose_every_selected_entry_is_skipped_is_not_a_pass() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let config = plant_must_pass_plan(&sandbox, &[("demo", true)])?;
    let home = sandbox.path().display().to_string();

    let run = sandbox.run_with_env(&["--config", &config], &[("HOME", &home)])?;
    if !run.is_failure() {
        return Err(format!(
            "a plan whose only selected entry is `skip: true` exited {:?}; nothing was replayed, so it is not a pass.\n{}",
            run.code,
            run.output()
        ));
    }
    let output = run.output();
    if !output.contains("skip: true") {
        return Err(format!(
            "the refusal never names the `skip: true` that emptied the run:\n{output}"
        ));
    }

    let report_path = sandbox.path().join("mirroir-run-report.json");
    let report = fs::read_to_string(&report_path).map_err(|e| format!("read run report: {e}"))?;
    if !report.contains("\"skipped\": 1") {
        return Err(format!(
            "the summary must still account for the skipped entry:\n{report}"
        ));
    }
    Ok(())
}

/// The companion to the test above: a skipped entry beside one that replays
/// and passes is still a pass. A fix that failed every plan holding a skipped
/// entry would pass the test above and fail this one.
#[test]
fn a_skipped_entry_beside_a_replayed_one_still_passes() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let config = plant_must_pass_plan(&sandbox, &[("parked", true), ("live", false)])?;
    let home = sandbox.path().display().to_string();

    let run = sandbox.run_with_env(&["--config", &config], &[("HOME", &home)])?;
    if run.is_failure() {
        return Err(format!(
            "one replayed, passing entry beside a skipped one exited {:?}.\n{}",
            run.code,
            run.output()
        ));
    }
    Ok(())
}
