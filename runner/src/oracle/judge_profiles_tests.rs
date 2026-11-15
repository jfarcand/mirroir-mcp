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
// ABOUTME: Tests for the judge profile registry: trust boundary of overlays and pinned system prompts.
// ABOUTME: Each overlay is written to a temp HOME or repo so no real ~/.mirroir config is read.

use std::error::Error as StdError;
use std::fs;
use std::result::Result as StdResult;

use std::path::Path;

use sha2::{Digest, Sha256};

use super::*;

type TestResult = StdResult<(), Box<dyn StdError>>;

#[test]
fn repo_local_overlay_tunes_model_and_timeout_but_not_endpoint() -> TestResult {
    let dir = tempfile::tempdir()?;
    let oracles = dir.path().join("oracles");
    fs::create_dir_all(&oracles)?;
    // Repo-local config tries to redirect fast-ci's endpoint + retune it.
    fs::write(
        oracles.join("profiles.yaml"),
        "version: 1\n\
         profiles:\n\
         \x20 - name: fast-ci\n\
         \x20   base_url: https://attacker.test/v1/chat/completions\n\
         \x20   model: overridden\n\
         \x20   api_key_env: STOLEN_KEY\n\
         \x20   timeout_s: 45\n",
    )?;
    // No home overlay — only the untrusted repo-local file.
    let registry = JudgeRegistry::load(None, dir.path())?;
    let fast_ci = registry.resolve("fast-ci")?;
    // model + timeout are tuned...
    if fast_ci.model != "overridden" || fast_ci.timeout_s != 45 {
        return Err(format!("model/timeout not tuned: {fast_ci:?}").into());
    }
    // ...but the endpoint + credential binding stay at the trusted built-in.
    if fast_ci.base_url != "https://api.openai.com/v1/chat/completions" {
        return Err(format!("repo-local redirected base_url: {fast_ci:?}").into());
    }
    if fast_ci.api_key_env.as_deref() != Some("OPENAI_API_KEY") {
        return Err(format!("repo-local rebound api_key_env: {fast_ci:?}").into());
    }
    Ok(())
}

#[test]
fn repo_local_overlay_ignores_new_profiles() -> TestResult {
    let dir = tempfile::tempdir()?;
    let oracles = dir.path().join("oracles");
    fs::create_dir_all(&oracles)?;
    fs::write(
        oracles.join("profiles.yaml"),
        "version: 1\n\
         profiles:\n\
         \x20 - name: my-judge\n\
         \x20   base_url: https://attacker.test/v1/chat/completions\n\
         \x20   model: my-model\n",
    )?;
    let registry = JudgeRegistry::load(None, dir.path())?;
    // A brand-new repo-local profile is not registered.
    if registry.resolve("my-judge").is_ok() {
        return Err("repo-local new profile should be ignored".into());
    }
    // Built-ins are untouched.
    registry.resolve("fast-ci")?;
    Ok(())
}

#[test]
fn home_overlay_may_define_endpoints_and_override_builtins() -> TestResult {
    let home = tempfile::tempdir()?;
    let oracles = home.path().join(".mirroir").join("oracles");
    fs::create_dir_all(&oracles)?;
    // The trusted home file adds a new endpoint and redirects a built-in.
    fs::write(
        oracles.join("profiles.yaml"),
        "version: 1\n\
         profiles:\n\
         \x20 - name: my-judge\n\
         \x20   base_url: https://example.test/v1/chat/completions\n\
         \x20   model: my-model\n\
         \x20   api_key_env: MY_KEY\n\
         \x20   timeout_s: 45\n\
         \x20 - name: fast-ci\n\
         \x20   base_url: https://self-hosted.test/v1/chat/completions\n\
         \x20   model: overridden\n",
    )?;
    let project = tempfile::tempdir()?;
    let registry = JudgeRegistry::load(Some(home.path()), project.path())?;
    let custom = registry.resolve("my-judge")?;
    if custom.base_url != "https://example.test/v1/chat/completions" || custom.timeout_s != 45 {
        return Err(format!("home profile not loaded: {custom:?}").into());
    }
    let fast_ci = registry.resolve("fast-ci")?;
    if fast_ci.base_url != "https://self-hosted.test/v1/chat/completions" {
        return Err(format!("home overlay did not redirect builtin: {fast_ci:?}").into());
    }
    Ok(())
}

#[test]
fn load_without_files_returns_builtins() -> TestResult {
    let project = tempfile::tempdir()?;
    let registry = JudgeRegistry::load(None, project.path())?;
    registry.resolve("fast-ci")?;
    Ok(())
}

#[test]
fn builtin_profiles_includes_fast_ci_byte_stable_cheap_local() {
    let registry = JudgeRegistry::default();
    for name in &["fast-ci", "byte-stable", "cheap-local"] {
        assert!(
            registry.resolve(name).is_ok(),
            "missing builtin profile: {name}"
        );
    }
}

#[test]
fn the_canonical_system_prompt_matches_its_pin() -> TestResult {
    let prompt = SystemPrompt::canonical();
    assert_eq!(prompt.digest(), prompt.pinned);
    prompt.verify("built-in")?;
    Ok(())
}

#[test]
fn every_builtin_profile_loads_with_a_verified_system_prompt() -> TestResult {
    let dir = tempfile::tempdir()?;
    let registry = JudgeRegistry::load(None, dir.path())?;
    for name in ["fast-ci", "byte-stable", "cheap-local"] {
        assert_eq!(
            registry.resolve(name)?.system_prompt,
            SystemPrompt::canonical()
        );
    }
    Ok(())
}

fn write_prompt_overlay(dir: &Path, prompt: &str, pin: &str) -> TestResult {
    let oracles = dir.join("oracles");
    fs::create_dir_all(&oracles)?;
    fs::write(oracles.join("strict.md"), prompt)?;
    fs::write(
        oracles.join("profiles.yaml"),
        format!(
            "version: 1\n\
             profiles:\n\
             \x20 - name: byte-stable\n\
             \x20   base_url: http://127.0.0.1:11434/api/chat\n\
             \x20   model: qwen2.5:0.5b\n\
             \x20   system_prompt: strict.md\n\
             \x20   system_prompt_sha256: \"{pin}\"\n"
        ),
    )?;
    Ok(())
}

#[test]
fn a_profile_system_prompt_file_that_matches_its_pin_is_used() -> TestResult {
    let dir = tempfile::tempdir()?;
    let text = "Score strictly.";
    let pin = format!("sha256:{}", hex::encode(Sha256::digest(text.as_bytes())));
    write_prompt_overlay(dir.path(), text, &pin)?;
    let registry = JudgeRegistry::load(None, dir.path())?;
    let prompt = &registry.resolve("byte-stable")?.system_prompt;
    assert_eq!(prompt.text, text);
    assert_eq!(prompt.pinned, pin);
    Ok(())
}

#[test]
fn a_system_prompt_that_does_not_match_its_pin_fails_the_load() -> TestResult {
    let dir = tempfile::tempdir()?;
    write_prompt_overlay(dir.path(), "Score strictly, edited.", "sha256:0000")?;
    let res = JudgeRegistry::load(None, dir.path());
    let Err(RunnerError::Oracle(OracleError::SystemPromptMismatch {
        profile, pinned, ..
    })) = res
    else {
        return Err(format!("expected SystemPromptMismatch, got {res:?}").into());
    };
    assert_eq!(profile, "byte-stable");
    assert_eq!(pinned, "sha256:0000");
    Ok(())
}

#[test]
fn a_system_prompt_without_its_pin_is_a_parse_error() -> TestResult {
    let dir = tempfile::tempdir()?;
    let oracles = dir.path().join("oracles");
    fs::create_dir_all(&oracles)?;
    fs::write(oracles.join("strict.md"), "x")?;
    fs::write(
        oracles.join("profiles.yaml"),
        "version: 1\n\
         profiles:\n\
         \x20 - name: byte-stable\n\
         \x20   base_url: http://127.0.0.1:11434/api/chat\n\
         \x20   model: qwen2.5:0.5b\n\
         \x20   system_prompt: strict.md\n",
    )?;
    let res = JudgeRegistry::load(None, dir.path());
    assert!(
        matches!(
            res,
            Err(RunnerError::Oracle(OracleError::ProfilesParse { .. }))
        ),
        "{res:?}"
    );
    Ok(())
}
