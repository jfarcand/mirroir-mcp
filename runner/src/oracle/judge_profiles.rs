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
// ABOUTME: Judge profile registry — built-in profiles plus oracles/profiles.yaml overlay.
// ABOUTME: Maps a scenario's judge.profile name to an LLM endpoint, model, timeout and pinned system prompt.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use sha2::{Digest, Sha256};
use tracing::{info, warn};

use crate::error::{Result, RunnerError};
use crate::oracle::error::OracleError;
use crate::oracle::llm_client::ApiTarget;
use crate::parser::version::{self, ArtifactKind};

/// Profile registry entry — declares how to reach one LLM provider and which
/// model to use for judging. Owned fields so profiles can be loaded at runtime
/// from `oracles/profiles.yaml` as well as compiled in as built-ins.
#[derive(Debug, Clone)]
pub struct JudgeProfile {
    /// Profile name (referenced from scenario `judge.profile`).
    pub name: String,
    /// Chat-completions base URL (e.g. `https://api.openai.com/v1/chat/completions`).
    pub base_url: String,
    /// Model identifier the provider expects.
    pub model: String,
    /// Environment variable that holds the API key. `None` for local providers
    /// like Ollama that don't authenticate.
    pub api_key_env: Option<String>,
    /// Request timeout in seconds.
    pub timeout_s: u32,
    /// The wire protocol `base_url` speaks.
    pub api_target: ApiTarget,
    /// The system prompt sent before every scoring request, with its pin.
    pub system_prompt: SystemPrompt,
}

/// A judge system prompt and the sha256 it is pinned to.
///
/// Changing a profile's system prompt changes its scores, so the text is
/// verified against its pin when the registry loads: a mismatch is a hard
/// error, never a silently different oracle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SystemPrompt {
    /// Where the text came from, for messages: a file path, or the built-in name.
    pub source: String,
    /// The prompt text.
    pub text: String,
    /// The pinned digest, formatted `sha256:<hex>`.
    pub pinned: String,
}

impl SystemPrompt {
    /// The canonical system prompt every built-in profile uses.
    #[must_use]
    pub fn canonical() -> Self {
        Self {
            source: CANONICAL_SYSTEM_PROMPT_SOURCE.to_owned(),
            text: CANONICAL_SYSTEM_PROMPT.to_owned(),
            pinned: CANONICAL_SYSTEM_PROMPT_SHA256.to_owned(),
        }
    }

    /// The digest of the text, formatted `sha256:<hex>`.
    #[must_use]
    pub fn digest(&self) -> String {
        sha256_pin(&self.text)
    }

    /// Check the text against its pin.
    ///
    /// # Errors
    ///
    /// [`OracleError::SystemPromptMismatch`] when the text's digest is not the pin.
    pub fn verify(&self, profile: &str) -> Result<()> {
        let actual = self.digest();
        if actual == self.pinned {
            info!(profile, source = %self.source, pin = %self.pinned, "judge system prompt matches pin");
            Ok(())
        } else {
            Err(OracleError::SystemPromptMismatch {
                profile: profile.to_owned(),
                source_name: self.source.clone(),
                pinned: self.pinned.clone(),
                actual,
            }
            .into())
        }
    }
}

/// Name the canonical system prompt goes by in messages.
const CANONICAL_SYSTEM_PROMPT_SOURCE: &str = "built-in judge-system.md";

/// The canonical judge system prompt, compiled in.
const CANONICAL_SYSTEM_PROMPT: &str = include_str!("prompts/judge-system.md");

/// The pin of [`CANONICAL_SYSTEM_PROMPT`]. Editing the prompt fails the load
/// until this pin is updated with it, on purpose.
const CANONICAL_SYSTEM_PROMPT_SHA256: &str =
    "sha256:dad066508492be3b83dc71a602393edcb977c36b431e2d0acb04e547bd1386ad";

/// `sha256:<hex>` of `text`.
fn sha256_pin(text: &str) -> String {
    format!("sha256:{}", hex::encode(Sha256::digest(text.as_bytes())))
}

/// Ollama's native chat endpoint on its default port.
const OLLAMA_CHAT_URL: &str = "http://127.0.0.1:11434/api/chat";

/// Built-in profiles. Users may override or add profiles via an
/// `oracles/profiles.yaml` file (see [`JudgeRegistry::load`]).
#[must_use]
pub fn builtin_profiles() -> Vec<JudgeProfile> {
    vec![
        // Hosted, fast, cheap. Costs per token but turns around in <1 s typical.
        JudgeProfile {
            name: "fast-ci".to_owned(),
            base_url: "https://api.openai.com/v1/chat/completions".to_owned(),
            model: "gpt-4o-mini".to_owned(),
            api_key_env: Some("OPENAI_API_KEY".to_owned()),
            timeout_s: 30,
            api_target: ApiTarget::OpenAi,
            system_prompt: SystemPrompt::canonical(),
        },
        // Local, deterministic, free (assumes an Ollama daemon at default port).
        JudgeProfile {
            name: "byte-stable".to_owned(),
            base_url: OLLAMA_CHAT_URL.to_owned(),
            model: "qwen2.5:0.5b".to_owned(),
            api_key_env: None,
            timeout_s: 60,
            api_target: ApiTarget::Ollama,
            system_prompt: SystemPrompt::canonical(),
        },
        // Local, smaller model for quick iteration.
        JudgeProfile {
            name: "cheap-local".to_owned(),
            base_url: OLLAMA_CHAT_URL.to_owned(),
            model: "qwen2.5:0.5b".to_owned(),
            api_key_env: None,
            timeout_s: 30,
            api_target: ApiTarget::Ollama,
            system_prompt: SystemPrompt::canonical(),
        },
    ]
}

/// One profile entry as parsed from `oracles/profiles.yaml`.
#[derive(Debug, Deserialize)]
struct ProfileSpec {
    name: String,
    base_url: String,
    model: String,
    #[serde(default)]
    api_key_env: Option<String>,
    #[serde(default = "default_timeout_s")]
    timeout_s: u32,
    /// The wire protocol `base_url` speaks; chat completions when omitted.
    #[serde(default)]
    api_target: ApiTarget,
    /// A system prompt file, relative to the `profiles.yaml` that names it.
    #[serde(default)]
    system_prompt: Option<PathBuf>,
    /// The pin of `system_prompt`, formatted `sha256:<hex>`; required with it.
    #[serde(default)]
    system_prompt_sha256: Option<String>,
}

const fn default_timeout_s() -> u32 {
    30
}

/// Top-level shape of `oracles/profiles.yaml`. Its `version:` is required and
/// gated by [`ArtifactKind::JudgeProfiles`]; the built-in profiles are code,
/// not a file, and carry none.
#[derive(Debug, Deserialize)]
struct ProfilesFile {
    profiles: Vec<ProfileSpec>,
}

/// Trust level of an overlay source. A profile's endpoint (`base_url`) and
/// credential binding (`api_key_env`) may be set only by a trusted source —
/// a built-in or the user's home config — never by repo-local config, which
/// could otherwise redirect prompts + API keys to an attacker-controlled host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Trust {
    /// `~/.mirroir/oracles/profiles.yaml` — the user's own machine config.
    Full,
    /// `<repo>/oracles/profiles.yaml` or `<repo>/.mirroir/oracles/profiles.yaml`.
    RepoLocal,
}

/// Profile registry — maps profile names to [`JudgeProfile`] entries.
#[derive(Debug, Clone)]
pub struct JudgeRegistry {
    profiles: Vec<JudgeProfile>,
}

impl Default for JudgeRegistry {
    fn default() -> Self {
        Self {
            profiles: builtin_profiles(),
        }
    }
}

impl JudgeRegistry {
    /// Build a registry from an explicit profile list. Test-only — production
    /// callers use [`Self::default`] which loads the built-in profile set.
    #[cfg(test)]
    pub fn from_profiles(profiles: Vec<JudgeProfile>) -> Self {
        Self { profiles }
    }

    /// Built-ins overlaid with user profiles, with a trust boundary on the
    /// endpoint. Two sources are consulted:
    ///
    /// * **Trusted** — `<home_root>/.mirroir/oracles/profiles.yaml`. The user's
    ///   own machine config; may set every field, define new endpoints, and
    ///   override a built-in's `base_url` / `api_key_env`.
    /// * **Untrusted** — `<project_root>/oracles/profiles.yaml` and
    ///   `<project_root>/.mirroir/oracles/profiles.yaml`. Repo-local config; may
    ///   only tune `model` / `timeout_s` of an existing profile. A repo-local
    ///   `base_url` / `api_key_env` change or a brand-new profile is ignored
    ///   with a warning, so a checked-out repository cannot redirect judge
    ///   prompts + API keys to an attacker-controlled host.
    ///
    /// `home_root` is `None` when `$HOME` is unset (no trusted overlay then).
    ///
    /// # Errors
    ///
    /// [`OracleError::ProfilesParse`] when a file exists but can't be read
    /// or parsed as a `profiles:` list.
    pub fn load(home_root: Option<&Path>, project_root: &Path) -> Result<Self> {
        let mut registry = Self::default();
        if let Some(home) = home_root {
            let trusted = home.join(".mirroir").join("oracles").join("profiles.yaml");
            if trusted.is_file() {
                registry.overlay_from_file(&trusted, Trust::Full)?;
            }
        }
        let repo_candidates = [
            project_root.join("oracles").join("profiles.yaml"),
            project_root
                .join(".mirroir")
                .join("oracles")
                .join("profiles.yaml"),
        ];
        for path in repo_candidates {
            if path.is_file() {
                registry.overlay_from_file(&path, Trust::RepoLocal)?;
            }
        }
        for profile in &registry.profiles {
            profile.system_prompt.verify(&profile.name)?;
        }
        Ok(registry)
    }

    /// Load the registry for the current run: the trusted home overlay (from
    /// `$HOME`, if set) plus untrusted repo-local overlays (from the current
    /// directory).
    ///
    /// # Errors
    ///
    /// Propagates [`OracleError::ProfilesParse`] from [`Self::load`], or
    /// [`RunnerError::Io`] when the current directory can't be read.
    pub fn load_from_cwd() -> Result<Self> {
        let cwd = env::current_dir().map_err(|source| RunnerError::Io {
            context: "resolve current directory for judge profiles".to_owned(),
            source,
        })?;
        let home = env::var_os("HOME").map(PathBuf::from);
        Self::load(home.as_deref(), &cwd)
    }

    fn overlay_from_file(&mut self, path: &Path, trust: Trust) -> Result<()> {
        let raw = fs::read_to_string(path).map_err(|source| OracleError::ProfilesParse {
            path: path.to_path_buf(),
            reason: source.to_string(),
        })?;
        let parsed: ProfilesFile = version::from_yaml_str(
            ArtifactKind::JudgeProfiles,
            &path.display().to_string(),
            &raw,
            |source| {
                OracleError::ProfilesParse {
                    path: path.to_path_buf(),
                    reason: source.to_string(),
                }
                .into()
            },
        )?;
        for mut spec in parsed.profiles {
            let prompt = system_prompt_of(&mut spec, path)?;
            self.apply_spec(spec, prompt, trust, path);
        }
        Ok(())
    }

    /// Apply one overlay profile under its source's [`Trust`] level. `model` and
    /// `timeout_s` and a pinned `system_prompt` are accepted from any source (a
    /// prompt changes scores, not where prompts and keys go); `base_url` /
    /// `api_key_env` and new profiles require [`Trust::Full`].
    fn apply_spec(
        &mut self,
        spec: ProfileSpec,
        prompt: Option<SystemPrompt>,
        trust: Trust,
        path: &Path,
    ) {
        if let Some(existing) = self.profiles.iter_mut().find(|p| p.name == spec.name) {
            existing.model = spec.model;
            existing.timeout_s = spec.timeout_s;
            if let Some(prompt) = prompt {
                existing.system_prompt = prompt;
            }
            match trust {
                Trust::Full => {
                    existing.base_url = spec.base_url;
                    existing.api_key_env = spec.api_key_env;
                    existing.api_target = spec.api_target;
                }
                Trust::RepoLocal => {
                    if spec.base_url != existing.base_url {
                        warn!(
                            profile = %spec.name,
                            source = %path.display(),
                            "repo-local profiles.yaml may not change base_url; keeping the trusted endpoint"
                        );
                    }
                    if spec.api_target != existing.api_target {
                        warn!(
                            profile = %spec.name,
                            source = %path.display(),
                            "repo-local profiles.yaml may not change api_target; keeping the trusted protocol"
                        );
                    }
                    if spec.api_key_env != existing.api_key_env {
                        warn!(
                            profile = %spec.name,
                            source = %path.display(),
                            "repo-local profiles.yaml may not change api_key_env; keeping the trusted binding"
                        );
                    }
                }
            }
        } else {
            match trust {
                Trust::Full => self.profiles.push(JudgeProfile {
                    name: spec.name,
                    base_url: spec.base_url,
                    model: spec.model,
                    api_key_env: spec.api_key_env,
                    timeout_s: spec.timeout_s,
                    api_target: spec.api_target,
                    system_prompt: prompt.unwrap_or_else(SystemPrompt::canonical),
                }),
                Trust::RepoLocal => warn!(
                    profile = %spec.name,
                    source = %path.display(),
                    "ignoring repo-local judge profile; new endpoints must be defined in ~/.mirroir/oracles/profiles.yaml or compiled in as built-ins"
                ),
            }
        }
    }

    /// Look up a profile by name.
    ///
    /// # Errors
    ///
    /// [`OracleError::UnknownProfile`] when the name isn't in the registry.
    pub fn resolve(&self, name: &str) -> Result<&JudgeProfile> {
        self.profiles
            .iter()
            .find(|p| p.name == name)
            .ok_or_else(|| {
                OracleError::UnknownProfile {
                    profile: name.to_owned(),
                }
                .into()
            })
    }
}

/// Read the system prompt a profile entry names, relative to `profiles_path`.
/// The pin is checked when the registry finishes loading.
fn system_prompt_of(spec: &mut ProfileSpec, profiles_path: &Path) -> Result<Option<SystemPrompt>> {
    match (spec.system_prompt.take(), spec.system_prompt_sha256.take()) {
        (None, None) => Ok(None),
        (Some(file), Some(pinned)) => {
            let path = profiles_path
                .parent()
                .unwrap_or_else(|| Path::new("."))
                .join(file);
            let text = fs::read_to_string(&path).map_err(|source| OracleError::ProfilesParse {
                path: path.clone(),
                reason: format!("system prompt of profile `{}`: {source}", spec.name),
            })?;
            Ok(Some(SystemPrompt {
                source: path.display().to_string(),
                text,
                pinned,
            }))
        }
        _ => Err(OracleError::ProfilesParse {
            path: profiles_path.to_path_buf(),
            reason: format!(
                "profile `{}` must declare system_prompt and system_prompt_sha256 together",
                spec.name
            ),
        }
        .into()),
    }
}

#[cfg(test)]
#[path = "judge_profiles_tests.rs"]
mod tests;
