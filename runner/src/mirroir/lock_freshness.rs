// ABOUTME: Compares `mirroir.yaml`'s archetype ref set + version pins against what `mirroir.lock` records.
// ABOUTME: Produces the FreshnessVerdict; content verification lives next door in lock_checksum.rs.

use crate::mirroir::resolve_version::version_satisfies_constraint;
use crate::parser::lockfile::Lockfile;
use crate::parser::mirroir::{ArchetypeRef, ArchetypeRefKind, MirroirConfig, PlanEntrySource};

/// Outcome of [`check_lockfile_fresh`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FreshnessVerdict {
    /// Lockfile matches the config exactly.
    Fresh,
    /// Lockfile drifted from the config. `reasons` lists the specific drifts.
    Stale {
        /// Human-readable list of drift reasons (e.g., "ref X added", "version mismatch on Y").
        reasons: Vec<String>,
    },
}

/// Compare every archetype reference in `config` against `lockfile`.
///
/// Drifts that produce `Stale`:
/// - A ref appears in config but not in lockfile.
/// - A ref appears in lockfile but not in config (unused entry).
/// - A ref appears in both but the recorded `resolved.version` no longer matches the constraint in config.
///
/// Project-local refs are checksum-only (no version comparison) — the freshness
/// check trusts the directory content at compose time.
#[must_use]
pub fn check_lockfile_fresh(config: &MirroirConfig, lockfile: &Lockfile) -> FreshnessVerdict {
    let mut reasons = Vec::new();

    let config_refs: Vec<String> = collect_plan_refs(config);
    let locked_refs: Vec<&str> = lockfile
        .archetypes
        .iter()
        .map(|a| a.reference.as_str())
        .collect();

    for cref in &config_refs {
        if !locked_refs.contains(&cref.as_str()) {
            reasons.push(format!("ref `{cref}` is in mirroir.yaml but not locked"));
        }
    }
    for lref in &locked_refs {
        if !config_refs.iter().any(|c| c == lref) {
            reasons.push(format!("ref `{lref}` is locked but not in mirroir.yaml"));
        }
    }

    // Version-constraint drift: for refs present in both, the recorded
    // `resolved.version` must still satisfy the constraint declared in config.
    // Catches a hand-edited or partially-updated lockfile whose pin no longer
    // matches its own ref's `@<version>` constraint. Project-local refs carry
    // no resolved version (checksum-only) and are skipped.
    for r in collect_plan_archetype_refs(config) {
        let ref_str = format_ref(r);
        let Some(locked) = lockfile.archetypes.iter().find(|a| a.reference == ref_str) else {
            continue;
        };
        let Some(resolved_version) = locked.resolved.version.as_deref() else {
            continue;
        };
        let constraint = r.version.as_deref().unwrap_or("");
        // `None` = unparseable resolved version (non-semver pin); leave to checksum.
        if version_satisfies_constraint(resolved_version, constraint) == Some(false) {
            reasons.push(format!(
                "ref `{ref_str}` is locked at {resolved_version}, which no longer satisfies its config constraint"
            ));
        }
    }

    if reasons.is_empty() {
        FreshnessVerdict::Fresh
    } else {
        FreshnessVerdict::Stale { reasons }
    }
}

/// Collect the structured archetype refs referenced by the plan (both sets).
fn collect_plan_archetype_refs(config: &MirroirConfig) -> Vec<&ArchetypeRef> {
    let mut refs = Vec::new();
    for entry in config
        .plan
        .must_pass
        .iter()
        .chain(config.plan.nice_to_pass.iter())
    {
        if let PlanEntrySource::Archetypes { references } = &entry.source {
            refs.extend(references.iter());
        }
    }
    refs
}

fn collect_plan_refs(config: &MirroirConfig) -> Vec<String> {
    let mut refs = Vec::new();
    for entry in config
        .plan
        .must_pass
        .iter()
        .chain(config.plan.nice_to_pass.iter())
    {
        if let PlanEntrySource::Archetypes { references } = &entry.source {
            for r in references {
                refs.push(format_ref(r));
            }
        }
    }
    refs
}

/// Render an [`ArchetypeRef`] back to its canonical `<pack>/<name>[@<version>]`
/// (or `user/<name>` / project-local path) string form.
#[must_use]
pub fn format_ref(r: &ArchetypeRef) -> String {
    let base = match (&r.pack, r.kind) {
        (Some(p), _) => format!("{p}/{}", r.name),
        (None, ArchetypeRefKind::UserGlobal) => format!("user/{}", r.name),
        (None, ArchetypeRefKind::Pack | ArchetypeRefKind::ProjectLocal) => r.name.clone(),
    };
    match &r.version {
        Some(v) => format!("{base}@{v}"),
        None => base,
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use chrono::Utc;

    use super::*;
    use crate::parser::lockfile::{LockedArchetype, LockedOrigin, ResolvedRecord};
    use crate::parser::mirroir::parse_mirroir_config;
    use crate::parser::version::ArtifactKind;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn config_with_one_archetype() -> StdResult<MirroirConfig, Box<dyn StdError>> {
        let yaml = r#"
version: 1
plan:
  must_pass:
    - name: alpha
      archetypes: [mirroir-skills/foo/bar@v1]
      flows: [smoke]
      boot:
        command: "echo"
"#;
        Ok(parse_mirroir_config("test", yaml)?)
    }

    fn empty_lockfile() -> Lockfile {
        Lockfile {
            version: ArtifactKind::Lockfile.current(),
            generated_at: Utc::now(),
            generated_by: "test".to_owned(),
            archetypes: Vec::new(),
        }
    }

    fn locked(reference: &str, name: &str, version: &str) -> LockedArchetype {
        LockedArchetype {
            reference: reference.to_owned(),
            resolved: ResolvedRecord {
                kind: LockedOrigin::Pack,
                pack: Some("mirroir-skills".to_owned()),
                name: name.to_owned(),
                version: Some(version.to_owned()),
                source: None,
                checksum: "sha256:xx".to_owned(),
            },
        }
    }

    #[test]
    fn fresh_when_lockfile_has_all_refs() -> TestResult {
        let config = config_with_one_archetype()?;
        let mut lock = empty_lockfile();
        lock.archetypes
            .push(locked("mirroir-skills/foo/bar@v1", "foo/bar", "1.0.0"));
        assert_eq!(
            check_lockfile_fresh(&config, &lock),
            FreshnessVerdict::Fresh
        );
        Ok(())
    }

    #[test]
    fn stale_when_lockfile_missing_ref() -> TestResult {
        let config = config_with_one_archetype()?;
        let lock = empty_lockfile();
        match check_lockfile_fresh(&config, &lock) {
            FreshnessVerdict::Stale { reasons } => {
                assert!(reasons.iter().any(|r| r.contains("foo/bar")));
                Ok(())
            }
            FreshnessVerdict::Fresh => Err("expected Stale, got Fresh".into()),
        }
    }

    #[test]
    fn stale_when_lockfile_has_extra_ref() -> TestResult {
        let config = config_with_one_archetype()?;
        let mut lock = empty_lockfile();
        lock.archetypes
            .push(locked("mirroir-skills/foo/bar@v1", "foo/bar", "1.0.0"));
        lock.archetypes
            .push(locked("mirroir-skills/extra/one@v1", "extra/one", "1.0.0"));
        match check_lockfile_fresh(&config, &lock) {
            FreshnessVerdict::Stale { reasons } => {
                assert!(reasons.iter().any(|r| r.contains("extra/one")));
                Ok(())
            }
            FreshnessVerdict::Fresh => Err("expected Stale, got Fresh".into()),
        }
    }

    /// Config ref pins `@v1` (major 1); the lockfile records a resolved version
    /// of 2.0.0 — the ref string matches but the pin no longer satisfies the
    /// constraint, which the set-diff alone would miss.
    #[test]
    fn stale_when_locked_version_violates_constraint() -> TestResult {
        let config = config_with_one_archetype()?;
        let mut lock = empty_lockfile();
        lock.archetypes
            .push(locked("mirroir-skills/foo/bar@v1", "foo/bar", "2.0.0"));
        match check_lockfile_fresh(&config, &lock) {
            FreshnessVerdict::Stale { reasons } => {
                assert!(
                    reasons.iter().any(|r| r.contains("no longer satisfies")),
                    "expected constraint-drift reason, got {reasons:?}"
                );
                Ok(())
            }
            FreshnessVerdict::Fresh => Err("expected Stale on version drift, got Fresh".into()),
        }
    }

    #[test]
    fn format_ref_renders_every_kind() {
        assert_eq!(
            format_ref(&ArchetypeRef {
                kind: ArchetypeRefKind::Pack,
                pack: Some("mirroir-skills".to_owned()),
                name: "foo/bar".to_owned(),
                version: Some("v1".to_owned()),
            }),
            "mirroir-skills/foo/bar@v1"
        );
        assert_eq!(
            format_ref(&ArchetypeRef {
                kind: ArchetypeRefKind::UserGlobal,
                pack: None,
                name: "dashboard".to_owned(),
                version: None,
            }),
            "user/dashboard"
        );
        assert_eq!(
            format_ref(&ArchetypeRef {
                kind: ArchetypeRefKind::ProjectLocal,
                pack: None,
                name: "./archetypes/custom".to_owned(),
                version: None,
            }),
            "./archetypes/custom"
        );
    }
}
