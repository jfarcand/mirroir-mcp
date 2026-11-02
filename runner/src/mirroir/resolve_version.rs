// ABOUTME: Semver-ish version parsing + constraint matching for archetype resolution.
// ABOUTME: Picks the best installed pack version and answers lockfile freshness checks.

use std::fs;
use std::path::Path;

use crate::error::{Result, RunnerError};
use crate::mirroir::error::MirroirError;

/// Resolve a concrete version (directory name) for a pack/user-global archetype.
///
/// Precedence: a `locked_version` pin wins; then an exact `@x.y.z` constraint;
/// otherwise the highest installed directory under `root` that satisfies the
/// constraint.
///
/// # Errors
///
/// [`MirroirError::ArchetypeNotFound`] when `root` is unreadable or no
/// installed version satisfies the constraint.
pub fn resolve_version_from_constraint(
    root: &Path,
    ref_constraint: Option<&str>,
    locked_version: Option<&str>,
) -> Result<String> {
    if let Some(v) = locked_version {
        return Ok(v.to_owned());
    }
    if let Some(v) = ref_constraint
        && let Some(parsed) = parse_exact_version(v)
    {
        return Ok(format!("{}.{}.{}", parsed.0, parsed.1, parsed.2));
    }
    let entries = read_installed_versions(root)?;
    let constraint = Constraint::parse(ref_constraint.unwrap_or(""));
    let mut matches: Vec<InstalledVersion> = entries
        .into_iter()
        .filter_map(|(v, dir)| {
            if constraint.matches(v) {
                Some((v, dir))
            } else {
                None
            }
        })
        .collect();
    matches.sort_by_key(|(v, _)| *v);
    let best = matches.pop().ok_or_else(|| {
        RunnerError::Mirroir(MirroirError::ArchetypeNotFound {
            reference: format!(
                "no installed version matching `{}` at {}",
                ref_constraint.unwrap_or("<any>"),
                root.display(),
            ),
            searched: vec![root.to_path_buf()],
        })
    })?;
    Ok(best.1)
}

/// Triple of (parsed (major,minor,patch), directory name) yielded from a pack root scan.
type InstalledVersion = ((u32, u32, u32), String);

fn read_installed_versions(root: &Path) -> Result<Vec<InstalledVersion>> {
    let Ok(entries) = fs::read_dir(root) else {
        return Err(MirroirError::ArchetypeNotFound {
            reference: format!("pack/archetype root `{}` does not exist", root.display()),
            searched: vec![root.to_path_buf()],
        }
        .into());
    };
    let mut versions = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let Some(name_os) = path.file_name() else {
            continue;
        };
        let Some(name) = name_os.to_str() else {
            continue;
        };
        if let Some(v) = parse_version_lax(name) {
            versions.push((v, name.to_owned()));
        }
    }
    Ok(versions)
}

/// Parse strings like `1.0.3` or `v1.0.3` into a `(u32, u32, u32)` triple.
/// Returns `None` for incomplete versions (e.g., `1.2`, `v1`).
#[must_use]
pub fn parse_exact_version(s: &str) -> Option<(u32, u32, u32)> {
    let trimmed = s.strip_prefix('v').unwrap_or(s);
    let parts: Vec<&str> = trimmed.split('.').collect();
    if parts.len() != 3 {
        return None;
    }
    let parts_iter = parts.iter().map(|p| p.parse::<u32>().ok());
    let mut iter = parts_iter;
    let major = iter.next()??;
    let minor = iter.next()??;
    let patch = iter.next()??;
    Some((major, minor, patch))
}

/// Returns `Some(true)` when `resolved_version` satisfies the `@<version>`
/// `constraint`, `Some(false)` when it parses but violates it, or `None` when
/// the resolved version isn't semver-parseable (the caller should then fall
/// back to a checksum comparison). Used by the lockfile freshness check.
pub fn version_satisfies_constraint(resolved_version: &str, constraint: &str) -> Option<bool> {
    let parsed = parse_version_lax(resolved_version)?;
    Some(Constraint::parse(constraint).matches(parsed))
}

/// Parse a directory name as a version. Accepts `1.0.3`, `v1.0.3`, `1.0`,
/// `v1.0`, `1`, `v1`. Missing components default to 0 so they sort correctly.
fn parse_version_lax(s: &str) -> Option<(u32, u32, u32)> {
    let trimmed = s.strip_prefix('v').unwrap_or(s);
    let mut parts = trimmed.split('.');
    let major = parts.next()?.parse::<u32>().ok()?;
    let minor = parts
        .next()
        .and_then(|p| p.parse::<u32>().ok())
        .unwrap_or(0);
    let patch = parts
        .next()
        .and_then(|p| p.parse::<u32>().ok())
        .unwrap_or(0);
    if parts.next().is_some() {
        return None; // 1.2.3.4 is not a version
    }
    Some((major, minor, patch))
}

/// Version constraint extracted from the `@<v>` portion of an `ArchetypeRef`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Constraint {
    Any,
    Major(u32),
    Minor(u32, u32),
    Exact(u32, u32, u32),
}

impl Constraint {
    fn parse(s: &str) -> Self {
        let trimmed = s.trim();
        if trimmed.is_empty() || trimmed == "latest" {
            return Self::Any;
        }
        let trimmed = trimmed.strip_prefix('v').unwrap_or(trimmed);
        let parts: Vec<&str> = trimmed.split('.').collect();
        match parts.as_slice() {
            [a] => a.parse::<u32>().ok().map_or(Self::Any, Self::Major),
            [a, b] => match (a.parse::<u32>(), b.parse::<u32>()) {
                (Ok(maj), Ok(min)) => Self::Minor(maj, min),
                _ => Self::Any,
            },
            [a, b, c] => match (a.parse::<u32>(), b.parse::<u32>(), c.parse::<u32>()) {
                (Ok(maj), Ok(min), Ok(patch)) => Self::Exact(maj, min, patch),
                _ => Self::Any,
            },
            _ => Self::Any,
        }
    }

    fn matches(&self, version: (u32, u32, u32)) -> bool {
        match *self {
            Self::Any => true,
            Self::Major(maj) => version.0 == maj,
            Self::Minor(maj, min) => version.0 == maj && version.1 == min,
            Self::Exact(maj, min, patch) => version == (maj, min, patch),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constraint_parse_handles_v_prefix() {
        assert_eq!(Constraint::parse("v1"), Constraint::Major(1));
        assert_eq!(Constraint::parse("1"), Constraint::Major(1));
        assert_eq!(Constraint::parse("v1.2"), Constraint::Minor(1, 2));
        assert_eq!(Constraint::parse("1.2.3"), Constraint::Exact(1, 2, 3));
        assert_eq!(Constraint::parse(""), Constraint::Any);
        assert_eq!(Constraint::parse("latest"), Constraint::Any);
    }

    #[test]
    fn version_satisfies_constraint_checks_resolved_pin() {
        assert_eq!(version_satisfies_constraint("1.4.0", "v1"), Some(true));
        assert_eq!(version_satisfies_constraint("2.0.0", "v1"), Some(false));
        assert_eq!(version_satisfies_constraint("not-semver", "v1"), None);
    }
}
