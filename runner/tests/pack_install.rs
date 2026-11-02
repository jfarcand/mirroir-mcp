// ABOUTME: `mirroir-run pack install` end-to-end — the published mirroir-skills pack installs and a plan composes on it.
// ABOUTME: Drives the built binary with a sandboxed $HOME; the lockfile it writes records the installed commit.

//! Pack install suite.
//!
//! Before `pack install`, adopters were told to `git clone --branch <tag>` the
//! pack by hand — a tag the pack repository never published — and a hand copy
//! left lockfiles without provenance. These tests drive the installer against
//! the real mirroir-skills checkout so a pack that cannot install fails here.

mod common;

use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

use common::{Sandbox, skills_dir};

/// The pack archetype the published `mirroir-skills` INDEX.md lists.
const ARCHETYPE: &str = "atmosphere/ai-console";

/// `HOME` inside the sandbox and the inherited `PATH`: the install shells out
/// to `git`, which the sandbox's own `bin/` does not carry.
fn environment(sandbox: &Sandbox) -> Result<(String, String), String> {
    let path = env::var("PATH").map_err(|e| format!("PATH: {e}"))?;
    Ok((sandbox.path().join("home").display().to_string(), path))
}

fn head_commit(checkout: &Path) -> Result<String, String> {
    let output = Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(checkout)
        .output()
        .map_err(|e| format!("git rev-parse: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "{} is not a git checkout; pack install needs the mirroir-skills repository",
            checkout.display()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// The exit criterion of M6: the pack an adopter is told to install installs
/// through the runner, lands where `<pack>/<name>@<version>` refs resolve, and
/// a plan referencing it composes — with the lockfile recording the commit the
/// install fetched instead of nothing.
#[test]
fn the_published_pack_installs_and_a_plan_composes_against_it() -> Result<(), String> {
    let skills = skills_dir()?;
    let commit = head_commit(&skills)?;
    let sandbox = Sandbox::new()?;
    let (home, path) = environment(&sandbox)?;
    let env = [("HOME", home.as_str()), ("PATH", path.as_str())];
    let source = skills.display().to_string();

    let install = sandbox.run_with_env(&["pack", "install", &source], &env)?;
    if install.code != Some(0) {
        return Err(format!(
            "pack install exited {:?}\n{}",
            install.code,
            install.output()
        ));
    }
    let packs = Path::new(&home).join(".mirroir/skills/mirroir-skills");
    let versions: Vec<String> = fs::read_dir(&packs)
        .map_err(|e| format!("read {}: {e}", packs.display()))?
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    let [version] = versions.as_slice() else {
        return Err(format!(
            "expected one installed version, found {versions:?}"
        ));
    };
    let manifest = packs
        .join(version)
        .join("archetypes")
        .join(ARCHETYPE)
        .join("archetype.md");
    if !manifest.is_file() {
        return Err(format!("no {} after install", manifest.display()));
    }

    let again = sandbox.run_with_env(&["pack", "install", &source], &env)?;
    if again.code != Some(0) || !again.output().contains("already installed") {
        return Err(format!(
            "reinstalling the same commit was not a no-op: exited {:?}\n{}",
            again.code,
            again.output()
        ));
    }

    let config = sandbox.write(
        ".mirroir/mirroir.yaml",
        &format!(
            concat!(
                "version: 1\n",
                "plan:\n",
                "  must_pass:\n",
                "    - name: console\n",
                "      archetypes: [mirroir-skills/{archetype}@v1]\n",
                "      flows: [chat-stream]\n",
                "      vars: {{ PORT: \"18080\" }}\n",
                "      boot:\n",
                "        command: \"true\"\n",
            ),
            archetype = ARCHETYPE
        ),
    )?;
    let compose = sandbox.run_with_env(&["--config", &config, "--compose-only"], &env)?;
    if compose.code != Some(0) {
        return Err(format!(
            "compose against the installed pack exited {:?}\n{}",
            compose.code,
            compose.output()
        ));
    }
    let lock = fs::read_to_string(sandbox.path().join(".mirroir/mirroir.lock"))
        .map_err(|e| format!("no lockfile written: {e}"))?;
    if !lock.contains(&format!("commit: {commit}")) {
        return Err(format!(
            "the lockfile does not record the installed commit {commit}:\n{lock}"
        ));
    }
    Ok(())
}

/// A source that is not a pack is refused and installs nothing.
#[test]
fn a_repository_without_an_index_is_refused() -> Result<(), String> {
    let sandbox = Sandbox::new()?;
    let (home, path) = environment(&sandbox)?;
    let repo = sandbox.path().join("not-a-pack");
    fs::create_dir_all(&repo).map_err(|e| format!("create repo: {e}"))?;
    for args in [
        vec!["init", "--quiet"],
        vec![
            "-c",
            "user.name=fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            "empty",
        ],
    ] {
        let status = Command::new("git")
            .args(&args)
            .current_dir(&repo)
            .status()
            .map_err(|e| format!("git {args:?}: {e}"))?;
        if !status.success() {
            return Err(format!("git {args:?} failed"));
        }
    }

    let run = sandbox.run_with_env(
        &["pack", "install", &repo.display().to_string()],
        &[("HOME", home.as_str()), ("PATH", path.as_str())],
    )?;
    if run.code != Some(1) || !run.output().contains("no readable INDEX.md") {
        return Err(format!(
            "a pack without INDEX.md was not refused: exited {:?}\n{}",
            run.code,
            run.output()
        ));
    }
    let skills = Path::new(&home).join(".mirroir/skills");
    let left: Vec<_> = fs::read_dir(&skills)
        .map_err(|e| format!("read {}: {e}", skills.display()))?
        .filter_map(Result::ok)
        .map(|entry| entry.file_name())
        .collect();
    if !left.is_empty() {
        return Err(format!("a refused install left {left:?} behind"));
    }
    Ok(())
}
