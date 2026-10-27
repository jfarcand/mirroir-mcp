// ABOUTME: Judge profile registry — built-in profiles plus oracles/profiles.yaml overlay.
// ABOUTME: Maps a scenario's judge.profile name to an LLM endpoint, model, and timeout.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use tracing::warn;

use crate::error::{Result, RunnerError};
use crate::oracle::error::OracleError;

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
}

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
        },
        // Local, deterministic, free (assumes an Ollama daemon at default port).
        JudgeProfile {
            name: "byte-stable".to_owned(),
            base_url: "http://127.0.0.1:11434/v1/chat/completions".to_owned(),
            model: "qwen2.5:0.5b".to_owned(),
            api_key_env: None,
            timeout_s: 60,
        },
        // Local, smaller model for quick iteration.
        JudgeProfile {
            name: "cheap-local".to_owned(),
            base_url: "http://127.0.0.1:11434/v1/chat/completions".to_owned(),
            model: "qwen2.5:0.5b".to_owned(),
            api_key_env: None,
            timeout_s: 30,
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
}

const fn default_timeout_s() -> u32 {
    30
}

/// Top-level shape of `oracles/profiles.yaml`.
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
        let parsed: ProfilesFile =
            serde_norway::from_str(&raw).map_err(|source| OracleError::ProfilesParse {
                path: path.to_path_buf(),
                reason: source.to_string(),
            })?;
        for spec in parsed.profiles {
            self.apply_spec(spec, trust, path);
        }
        Ok(())
    }

    /// Apply one overlay profile under its source's [`Trust`] level. `model` and
    /// `timeout_s` are accepted from any source; `base_url` / `api_key_env` and
    /// new profiles require [`Trust::Full`].
    fn apply_spec(&mut self, spec: ProfileSpec, trust: Trust, path: &Path) {
        if let Some(existing) = self.profiles.iter_mut().find(|p| p.name == spec.name) {
            existing.model = spec.model;
            existing.timeout_s = spec.timeout_s;
            match trust {
                Trust::Full => {
                    existing.base_url = spec.base_url;
                    existing.api_key_env = spec.api_key_env;
                }
                Trust::RepoLocal => {
                    if spec.base_url != existing.base_url {
                        warn!(
                            profile = %spec.name,
                            source = %path.display(),
                            "repo-local profiles.yaml may not change base_url; keeping the trusted endpoint"
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

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::fs;
    use std::result::Result as StdResult;

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
            "profiles:\n\
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
            "profiles:\n\
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
            "profiles:\n\
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
}
