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
// ABOUTME: `mirroir.lock` verification end-to-end — an edited archetype tree fails --locked and --frozen.
// ABOUTME: The lockfile recorded a checksum from the start; until now nothing recomputed it.

//! Lockfile verification suite.
//!
//! `mirroir.lock` records `checksum: sha256:…` for every resolved archetype.
//! Comparing ref strings and version pins accepts a tree whose *contents*
//! moved under a pin that did not — a locally edited archetype, a pack
//! rewritten in place, a tampered install. These tests pin the recompute.

mod common;

use std::fs;
use std::path::Path;

use common::Sandbox;

/// Plant a `.mirroir/` plan with one project-local archetype and return the
/// path of its `mirroir.yaml`.
fn plant_plan(sandbox: &Sandbox) -> Result<String, String> {
    sandbox.write(
        ".mirroir/archetypes/demo/archetype.md",
        concat!(
            "```yaml\n",
            "version: 1\n",
            "name: demo/local\n",
            "archetype_version: 1.0.0\n",
            "provides:\n",
            "  flows:\n",
            "    - smoke\n",
            "```\n",
        ),
    )?;
    sandbox.write(
        ".mirroir/archetypes/demo/APP.md",
        concat!(
            "# Demo\n\n",
            "```yaml\n",
            "version: 1\n",
            "app: demo\n",
            "surface: web\n",
            "url: \"http://127.0.0.1:18999/\"\n",
            "```\n",
        ),
    )?;
    sandbox.write(
        ".mirroir/archetypes/demo/scenarios/smoke.yaml",
        concat!(
            "version: 1\n",
            "name: demo smoke\n",
            "steps:\n",
            "  - http:\n",
            "      method: GET\n",
            "      url: \"http://127.0.0.1:18999/\"\n",
            "      expect_status: 200\n",
        ),
    )?;
    sandbox.write(
        ".mirroir/mirroir.yaml",
        concat!(
            "version: 1\n",
            "plan:\n",
            "  must_pass:\n",
            "    - name: demo\n",
            "      archetypes: [\"./archetypes/demo\"]\n",
            "      flows: [smoke]\n",
            "      boot:\n",
            "        command: \"true\"\n",
        ),
    )
}

/// Compose-only invocation in the given lockfile mode.
fn compose(
    sandbox: &Sandbox,
    config: &str,
    mode: Option<&str>,
) -> Result<(Option<i32>, String), String> {
    let home = sandbox.path().display().to_string();
    let mut args = vec!["--config", config, "--compose-only"];
    if let Some(flag) = mode {
        args.push(flag);
    }
    let run = sandbox.run_with_env(&args, &[("HOME", &home)])?;
    Ok((run.code, run.output()))
}

/// The exit criterion: lock a tree, edit one byte inside it, and `--frozen`
/// exits non-zero. Before the checksum was recomputed, both `--locked` and
/// `--frozen` exited 0 on that edit — the ref string and the version pin were
/// untouched, and nothing else was checked.
#[test]
fn an_edited_archetype_byte_fails_locked_and_frozen() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let config = plant_plan(&sandbox)?;

    // Default mode writes the lockfile.
    let (code, output) = compose(&sandbox, &config, None)?;
    if code != Some(0) {
        return Err(format!("the first compose exited {code:?}\n{output}"));
    }
    let lock = sandbox.path().join(".mirroir").join("mirroir.lock");
    let recorded = fs::read_to_string(&lock).map_err(|e| format!("no lockfile written: {e}"))?;
    if !recorded.contains("checksum: sha256:") {
        return Err(format!("the lockfile records no checksum:\n{recorded}"));
    }

    // A truthful lockfile satisfies both gates.
    for flag in ["--locked", "--frozen"] {
        let (code, output) = compose(&sandbox, &config, Some(flag))?;
        if code != Some(0) {
            return Err(format!(
                "{flag} rejected an untouched tree: exited {code:?}\n{output}"
            ));
        }
    }

    // One byte, inside a file the lockfile hashed.
    let manifest = sandbox.path().join(".mirroir/archetypes/demo/archetype.md");
    let before = fs::read_to_string(&manifest).map_err(|e| format!("read manifest: {e}"))?;
    fs::write(&manifest, before.replace("demo/local", "demo/locaL"))
        .map_err(|e| format!("edit manifest: {e}"))?;

    for flag in ["--locked", "--frozen"] {
        let (code, output) = compose(&sandbox, &config, Some(flag))?;
        if code == Some(0) {
            return Err(format!(
                "{flag} accepted an edited archetype tree\n{output}"
            ));
        }
        if !output.contains("now hashes to") {
            return Err(format!(
                "{flag} failed for some other reason than the checksum:\n{output}"
            ));
        }
    }
    Ok(())
}

/// `mirroir-run accept` is the way back: it re-resolves and re-checksums the
/// lockfile, so the deliberate edit is blessed and the gates go green again.
#[test]
fn accept_re_records_the_lockfile_after_a_deliberate_edit() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let config = plant_plan(&sandbox)?;
    let home = sandbox.path().display().to_string();

    compose(&sandbox, &config, None)?;
    let manifest = sandbox.path().join(".mirroir/archetypes/demo/archetype.md");
    let before = fs::read_to_string(&manifest).map_err(|e| format!("read manifest: {e}"))?;
    fs::write(&manifest, before.replace("demo/local", "demo/locaL"))
        .map_err(|e| format!("edit manifest: {e}"))?;

    let (code, output) = compose(&sandbox, &config, Some("--frozen"))?;
    if code == Some(0) {
        return Err(format!(
            "--frozen accepted the edit before accept ran\n{output}"
        ));
    }

    let accepted = sandbox.run_outside_ci(
        &["accept", "--config", &config, "--scenarios", "must-pass"],
        &[("HOME", &home)],
    )?;
    let lock = sandbox.path().join(".mirroir").join("mirroir.lock");
    if !Path::new(&lock).is_file() {
        return Err(format!("accept left no lockfile\n{}", accepted.output()));
    }

    let (code, output) = compose(&sandbox, &config, Some("--frozen"))?;
    if code != Some(0) {
        return Err(format!(
            "--frozen still refuses after accept re-recorded the lockfile: {code:?}\n{output}"
        ));
    }
    Ok(())
}
