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
// ABOUTME: Archetype reference parsing for `mirroir.yaml` plan entries.
// ABOUTME: Classifies `<pack>/<name>[@v]`, `./<path>`, and `user/<name>[@v]` refs into a typed ArchetypeRef.

use crate::error::Result;
use crate::mirroir::error::MirroirError;

/// A parsed archetype reference. The runner consumes this via the resolver
/// (see Stage 2) to locate the archetype on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArchetypeRef {
    /// Which lookup chain to follow at resolve time.
    pub kind: ArchetypeRefKind,
    /// Pack identifier (e.g., `mirroir-skills`). `None` for project-local and user-global refs.
    pub pack: Option<String>,
    /// Archetype name within its origin (e.g., `atmosphere/ai-console`) — or a relative path for project-local refs.
    pub name: String,
    /// Version pin or constraint (e.g., `1.0.3`, `v1`, `1`). `None` for floating-latest or project-local.
    pub version: Option<String>,
}

/// Origin family of an [`ArchetypeRef`]. Drives the resolution chain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArchetypeRefKind {
    /// Pack-prefixed: `<pack>/<name>[@<version>]` → `~/.mirroir/skills/<pack>/<v>/archetypes/<name>/`.
    Pack,
    /// Project-local: `./<path>` → `<repo>/.mirroir/<path>/`.
    ProjectLocal,
    /// User-global: `user/<name>[@<version>]` → `~/.mirroir/archetypes/<name>/<v>/`.
    UserGlobal,
}

impl ArchetypeRef {
    /// Parse a single archetype reference string.
    ///
    /// Accepts:
    /// - `<pack>/<name>[@<version>]` — pack-prefixed
    /// - `./<path>` — project-local
    /// - `user/<name>[@<version>]` — user-global
    ///
    /// Rejects bare `<name>` (would be ambiguous between pack and user-global).
    ///
    /// # Errors
    ///
    /// Returns [`MirroirError::InvalidArchetypeRef`] on any of:
    /// - Empty string
    /// - Bare name with no prefix
    /// - `<pack>/` with no name component
    /// - `user/` with no name component
    pub fn parse(input: &str) -> Result<Self> {
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Err(MirroirError::InvalidArchetypeRef {
                value: input.to_owned(),
                reason: "empty reference".to_owned(),
            }
            .into());
        }

        // Project-local: anything starting with `./` or `../`.
        if trimmed.starts_with("./") || trimmed.starts_with("../") {
            return Ok(Self {
                kind: ArchetypeRefKind::ProjectLocal,
                pack: None,
                name: trimmed.to_owned(),
                version: None,
            });
        }

        // Split `@<version>` off the right.
        let (path_part, version) = trimmed
            .rsplit_once('@')
            .map_or((trimmed, None), |(left, right)| {
                (left, Some(right.to_owned()))
            });

        // Split prefix from the rest. Need at least `<prefix>/<something>`.
        let Some((prefix, rest)) = path_part.split_once('/') else {
            return Err(MirroirError::InvalidArchetypeRef {
                value: input.to_owned(),
                reason: "bare names without a prefix are ambiguous; use `<pack>/<name>`, `./<path>`, or `user/<name>`".to_owned(),
            }.into());
        };
        if rest.is_empty() {
            return Err(MirroirError::InvalidArchetypeRef {
                value: input.to_owned(),
                reason: format!("`{prefix}/` is missing the name component"),
            }
            .into());
        }

        if prefix == "user" {
            Ok(Self {
                kind: ArchetypeRefKind::UserGlobal,
                pack: None,
                name: rest.to_owned(),
                version,
            })
        } else {
            Ok(Self {
                kind: ArchetypeRefKind::Pack,
                pack: Some(prefix.to_owned()),
                name: rest.to_owned(),
                version,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;
    use crate::error::RunnerError;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    #[test]
    fn parse_pack_ref_with_version() -> TestResult {
        let r = ArchetypeRef::parse("mirroir-skills/atmosphere/ai-console@v1")?;
        assert_eq!(r.kind, ArchetypeRefKind::Pack);
        assert_eq!(r.pack.as_deref(), Some("mirroir-skills"));
        assert_eq!(r.name, "atmosphere/ai-console");
        assert_eq!(r.version.as_deref(), Some("v1"));
        Ok(())
    }

    #[test]
    fn parse_pack_ref_without_version() -> TestResult {
        let r = ArchetypeRef::parse("mirroir-skills/atmosphere/ai-console")?;
        assert_eq!(r.kind, ArchetypeRefKind::Pack);
        assert_eq!(r.version, None);
        Ok(())
    }

    #[test]
    fn parse_project_local_ref() -> TestResult {
        let r = ArchetypeRef::parse("./archetypes/my-custom")?;
        assert_eq!(r.kind, ArchetypeRefKind::ProjectLocal);
        assert_eq!(r.pack, None);
        assert_eq!(r.name, "./archetypes/my-custom");
        assert_eq!(r.version, None);
        Ok(())
    }

    #[test]
    fn parse_user_global_ref() -> TestResult {
        let r = ArchetypeRef::parse("user/internal-dashboard@1.0.0")?;
        assert_eq!(r.kind, ArchetypeRefKind::UserGlobal);
        assert_eq!(r.pack, None);
        assert_eq!(r.name, "internal-dashboard");
        assert_eq!(r.version.as_deref(), Some("1.0.0"));
        Ok(())
    }

    #[test]
    fn reject_bare_name() -> TestResult {
        let result = ArchetypeRef::parse("just-a-name");
        let Err(RunnerError::Mirroir(MirroirError::InvalidArchetypeRef { value, .. })) = result
        else {
            return Err(format!("expected MirroirInvalidArchetypeRef, got {result:?}").into());
        };
        assert_eq!(value, "just-a-name");
        Ok(())
    }

    #[test]
    fn reject_empty_ref() {
        let result = ArchetypeRef::parse("   ");
        assert!(matches!(
            result,
            Err(RunnerError::Mirroir(
                MirroirError::InvalidArchetypeRef { .. }
            ))
        ));
    }

    #[test]
    fn reject_prefix_with_no_name() {
        let result = ArchetypeRef::parse("mirroir-skills/");
        assert!(matches!(
            result,
            Err(RunnerError::Mirroir(
                MirroirError::InvalidArchetypeRef { .. }
            ))
        ));
    }
}
