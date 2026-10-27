// ABOUTME: Parses `.mirroir/mirroir.local.yaml` and merges it into the base config.
// ABOUTME: Maps merge per-key (instance wins); arrays replace (don't append); `skip: true` excludes.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::Deserialize;

use crate::error::{Result, RunnerError};
use crate::mirroir::error::MirroirError;
use crate::parser::mirroir::{
    ArchetypeRef, MIRROIR_SCHEMA_VERSION, MirroirConfig, PlanEntry, PlanEntrySource,
};

/// Partial schema for `mirroir.local.yaml`. Same top-level shape as
/// `mirroir.yaml` but every entry field is optional except `name`.
#[derive(Debug, Clone, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct MirroirLocalOverrides {
    /// Schema version (must match `mirroir.yaml`'s version).
    pub version: u32,
    /// Plan tier overrides.
    #[serde(default)]
    pub plan: PlanOverrides,
    /// Suite-level env additions (merged per-key into `MirroirConfig.env`).
    #[serde(default)]
    pub env: Option<HashMap<String, String>>,
}

/// Per-tier list of entry overrides. Each entry is identified by its `name`.
#[derive(Debug, Clone, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct PlanOverrides {
    #[serde(default)]
    pub must_pass: Vec<PlanEntryOverride>,
    #[serde(default)]
    pub nice_to_pass: Vec<PlanEntryOverride>,
}

/// Override for one plan entry. `name` matches the base entry; all other
/// fields are optional and apply the merge rules in the architecture spec.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlanEntryOverride {
    /// Matches `PlanEntry.name` of the base entry to override.
    pub name: String,
    /// `${VAR}` overrides — merged per-key (instance wins).
    #[serde(default)]
    pub vars: Option<HashMap<String, String>>,
    /// Boot wiring overrides — see [`PlanEntryBootOverride`].
    #[serde(default)]
    pub boot: Option<PlanEntryBootOverride>,
    /// Flow list override — **REPLACES** the base flow list when set.
    #[serde(default)]
    pub flows: Option<Vec<String>>,
    /// When true, exclude this entry from the run.
    #[serde(default)]
    pub skip: Option<bool>,
    /// Switch the entry to a different archetype reference (rare).
    #[serde(default)]
    pub archetypes: Option<Vec<String>>,
    /// Switch the entry to a local sample path (rare).
    #[serde(default)]
    pub local: Option<PathBuf>,
}

/// Optional boot-field overrides. Each `Some` replaces the base value.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlanEntryBootOverride {
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    /// Env additions — merged per-key into base `boot.env` (instance wins).
    #[serde(default)]
    pub env: Option<HashMap<String, String>>,
    #[serde(default)]
    pub timeout_s: Option<u32>,
    #[serde(default)]
    pub boot_once: Option<bool>,
    #[serde(default)]
    pub boot_ready_port: Option<u16>,
    #[serde(default)]
    pub boot_ready_timeout_s: Option<u32>,
}

/// Parse the YAML body of a `mirroir.local.yaml` file.
///
/// # Errors
///
/// * [`RunnerError::YamlParse`] on serde failure.
/// * [`RunnerError::UnsupportedVersion`] when `version` mismatches the base.
pub fn parse_local_overrides(source_label: &str, yaml: &str) -> Result<MirroirLocalOverrides> {
    let parsed: MirroirLocalOverrides =
        serde_norway::from_str(yaml).map_err(|source| RunnerError::YamlParse {
            file: source_label.to_owned(),
            source,
        })?;
    if parsed.version != MIRROIR_SCHEMA_VERSION {
        return Err(RunnerError::UnsupportedVersion {
            artifact: "mirroir.local.yaml".to_owned(),
            found: parsed.version,
            expected: MIRROIR_SCHEMA_VERSION..=MIRROIR_SCHEMA_VERSION,
        });
    }
    Ok(parsed)
}

/// Apply local overrides to a parsed base config.
///
/// Merge rules:
/// - Suite-level `env`: per-key merge (override wins).
/// - Plan entries matched by `name`: per-field merge.
/// - Within an entry: `vars` and `boot.env` merge per-key; arrays (`flows`,
///   `archetypes`) replace; scalars (`boot.command`, `boot.cwd`, …) replace
///   when `Some`.
/// - `skip: true` flips the entry's skip flag for this run.
/// - Override entries whose `name` doesn't match any base entry are appended
///   as new entries (must include either `archetypes` or `local` plus `boot`,
///   per base schema rules — enforced at use time, not here).
///
/// # Errors
///
/// Returns [`MirroirError::InvalidArchetypeRef`] if an override declares
/// an unparseable archetype reference. Other validation (e.g., new entries
/// missing `boot`) surfaces when the runner consumes the merged config.
pub fn apply_overrides(base: &mut MirroirConfig, overrides: MirroirLocalOverrides) -> Result<()> {
    if let Some(env_overrides) = overrides.env {
        for (k, v) in env_overrides {
            base.env.insert(k, v);
        }
    }

    apply_tier_overrides(&mut base.plan.must_pass, overrides.plan.must_pass)?;
    apply_tier_overrides(&mut base.plan.nice_to_pass, overrides.plan.nice_to_pass)?;
    Ok(())
}

fn apply_tier_overrides(
    base_tier: &mut [PlanEntry],
    tier_overrides: Vec<PlanEntryOverride>,
) -> Result<()> {
    for ov in tier_overrides {
        if let Some(existing) = base_tier.iter_mut().find(|e| e.name == ov.name) {
            apply_entry_override(existing, ov)?;
        } else {
            // No matching base entry — overrides that introduce a new entry
            // would need a complete shape. We accept the override but it
            // cannot become a `PlanEntry` without a base to merge into;
            // this is rare enough that v1 simply ignores it with a tracing
            // warning. The runner can re-author the entry in mirroir.yaml.
            tracing::warn!(
                entry_name = %ov.name,
                "mirroir.local.yaml entry has no matching base — ignored",
            );
        }
    }
    Ok(())
}

fn apply_entry_override(entry: &mut PlanEntry, ov: PlanEntryOverride) -> Result<()> {
    if let Some(skip) = ov.skip {
        entry.skip = skip;
    }
    if let Some(vars) = ov.vars {
        for (k, v) in vars {
            entry.vars.insert(k, v);
        }
    }
    if let Some(flows) = ov.flows {
        entry.flows = flows;
    }
    if let Some(boot_ov) = ov.boot {
        apply_boot_override(entry, boot_ov);
    }

    // Source switch — rare. Mutually exclusive with `archetypes` / `local`.
    match (ov.archetypes, ov.local) {
        (Some(refs), None) => {
            let parsed = refs
                .iter()
                .map(|s| ArchetypeRef::parse(s))
                .collect::<Result<Vec<_>>>()?;
            entry.source = PlanEntrySource::Archetypes { references: parsed };
        }
        (None, Some(path)) => {
            entry.source = PlanEntrySource::Local { path };
        }
        (Some(_), Some(_)) => {
            return Err(MirroirError::PlanEntryAmbiguous {
                entry_name: entry.name.clone(),
                reason: "override sets both `archetypes:` and `local:`".to_owned(),
            }
            .into());
        }
        (None, None) => {}
    }

    Ok(())
}

fn apply_boot_override(entry: &mut PlanEntry, boot_ov: PlanEntryBootOverride) {
    if let Some(command) = boot_ov.command {
        entry.boot.command = command;
    }
    if let Some(cwd) = boot_ov.cwd {
        entry.boot.cwd = Some(cwd);
    }
    if let Some(env_ov) = boot_ov.env {
        for (k, v) in env_ov {
            entry.boot.env.insert(k, v);
        }
    }
    if let Some(timeout_s) = boot_ov.timeout_s {
        entry.boot.timeout_s = Some(timeout_s);
    }
    if let Some(boot_once) = boot_ov.boot_once {
        entry.boot.boot_once = boot_once;
    }
    if let Some(port) = boot_ov.boot_ready_port {
        entry.boot.boot_ready_port = Some(port);
    }
    if let Some(timeout) = boot_ov.boot_ready_timeout_s {
        entry.boot.boot_ready_timeout_s = Some(timeout);
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;
    use crate::parser::mirroir::parse_mirroir_config;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn base_config() -> StdResult<MirroirConfig, Box<dyn StdError>> {
        let yaml = r#"
version: 1
env:
  CI: "true"
plan:
  must_pass:
    - name: alpha
      archetypes: [mirroir-skills/foo/bar@v1]
      flows: [chat-stream]
      vars: { PORT: "8080" }
      boot:
        command: "boot-alpha"
        env: { LLM_MODE: fake }
    - name: beta
      local: apps/beta
      boot:
        command: "boot-beta"
"#;
        Ok(parse_mirroir_config("base", yaml)?)
    }

    fn find_entry<'a>(
        config: &'a MirroirConfig,
        name: &str,
    ) -> StdResult<&'a PlanEntry, Box<dyn StdError>> {
        config
            .plan
            .must_pass
            .iter()
            .find(|e| e.name == name)
            .ok_or_else(|| format!("entry `{name}` not found").into())
    }

    #[test]
    fn vars_override_merges_per_key() -> TestResult {
        let mut base = base_config()?;
        let ov_yaml = r#"
version: 1
plan:
  must_pass:
    - name: alpha
      vars: { PORT: "18080", EXTRA: "value" }
"#;
        let overrides = parse_local_overrides("override", ov_yaml)?;
        apply_overrides(&mut base, overrides)?;
        let alpha = find_entry(&base, "alpha")?;
        assert_eq!(alpha.vars.get("PORT").map(String::as_str), Some("18080"));
        assert_eq!(alpha.vars.get("EXTRA").map(String::as_str), Some("value"));
        Ok(())
    }

    #[test]
    fn flows_override_replaces_array() -> TestResult {
        let mut base = base_config()?;
        let ov_yaml = r"
version: 1
plan:
  must_pass:
    - name: alpha
      flows: [only-this]
";
        let overrides = parse_local_overrides("override", ov_yaml)?;
        apply_overrides(&mut base, overrides)?;
        let alpha = find_entry(&base, "alpha")?;
        assert_eq!(alpha.flows, vec!["only-this".to_owned()]);
        Ok(())
    }

    #[test]
    fn boot_env_override_merges_per_key() -> TestResult {
        let mut base = base_config()?;
        let ov_yaml = r#"
version: 1
plan:
  must_pass:
    - name: alpha
      boot:
        env: { LLM_MODE: real, NEW: "x" }
"#;
        let overrides = parse_local_overrides("override", ov_yaml)?;
        apply_overrides(&mut base, overrides)?;
        let alpha = find_entry(&base, "alpha")?;
        assert_eq!(
            alpha.boot.env.get("LLM_MODE").map(String::as_str),
            Some("real")
        );
        assert_eq!(alpha.boot.env.get("NEW").map(String::as_str), Some("x"));
        Ok(())
    }

    #[test]
    fn skip_true_flips_the_skip_flag() -> TestResult {
        let mut base = base_config()?;
        let ov_yaml = r"
version: 1
plan:
  must_pass:
    - name: beta
      skip: true
";
        let overrides = parse_local_overrides("override", ov_yaml)?;
        apply_overrides(&mut base, overrides)?;
        let beta = find_entry(&base, "beta")?;
        assert!(beta.skip);
        Ok(())
    }

    #[test]
    fn unmatched_override_name_logs_warning_does_not_error() -> TestResult {
        let mut base = base_config()?;
        let ov_yaml = r#"
version: 1
plan:
  must_pass:
    - name: does-not-exist
      vars: { x: "y" }
"#;
        let overrides = parse_local_overrides("override", ov_yaml)?;
        apply_overrides(&mut base, overrides)?;
        // Original entries untouched.
        assert_eq!(base.plan.must_pass.len(), 2);
        Ok(())
    }

    #[test]
    fn version_mismatch_rejects() {
        let ov_yaml = "version: 99\nplan: {}\n";
        assert!(matches!(
            parse_local_overrides("override", ov_yaml),
            Err(RunnerError::UnsupportedVersion { .. })
        ));
    }
}
