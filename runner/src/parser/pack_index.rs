// ABOUTME: Parser for a pack's `INDEX.md` — the manifest naming the pack, its version, and its archetypes.
// ABOUTME: Frontmatter is a fenced YAML block (deserialized); the markdown body is human documentation.

use serde::Deserialize;

use crate::error::{Result, RunnerError};
use crate::parser::sample::extract_yaml_block;
use crate::parser::version::{self, ArtifactKind, SchemaVersion};

/// Filename of the manifest at the root of every archetype pack.
pub const PACK_INDEX_FILE: &str = "INDEX.md";

/// Parsed frontmatter of a pack's `INDEX.md`.
///
/// `pack install` reads it from the fetched checkout to decide where the pack
/// goes — `~/.mirroir/skills/<name>/<pack_version>/` — and which archetypes it
/// must find there before the install is allowed to land.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PackIndex {
    /// Frontmatter schema version, gated by [`ArtifactKind::PackIndex`].
    pub version: SchemaVersion,
    /// Pack identifier: the `<pack>` in `<pack>/<name>@<version>` refs and the
    /// directory under `~/.mirroir/skills/`.
    pub name: String,
    /// Exact semver (`1.0.0`) of this pack revision: the install directory.
    pub pack_version: String,
    /// Optional human-readable description.
    #[serde(default)]
    pub description: Option<String>,
    /// Where the pack is published (informational).
    #[serde(default)]
    pub repository: Option<String>,
    /// SPDX license identifier (informational).
    #[serde(default)]
    pub license: Option<String>,
    /// Archetype names the pack ships, each a directory under `archetypes/`.
    pub archetypes: Vec<String>,
}

/// Parse an `INDEX.md` source string.
///
/// # Errors
///
/// * [`RunnerError::SampleMissingYaml`] when the file has no fenced YAML block.
/// * [`RunnerError::UnsupportedVersion`] / [`RunnerError::YamlParse`] from the
///   versioned typed parse.
pub fn parse_pack_index(source_label: &str, markdown: &str) -> Result<PackIndex> {
    let body = extract_yaml_block(markdown).ok_or_else(|| RunnerError::SampleMissingYaml {
        path: source_label.to_owned(),
    })?;
    version::from_yaml_str(ArtifactKind::PackIndex, source_label, &body, |source| {
        RunnerError::YamlParse {
            file: source_label.to_owned(),
            source,
        }
    })
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    const INDEX: &str = concat!(
        "```yaml\n",
        "version: 1\n",
        "name: mirroir-skills\n",
        "pack_version: 1.0.0\n",
        "description: |\n",
        "  Canonical archetype pack.\n",
        "repository: https://github.com/jfarcand/mirroir-skills\n",
        "license: Apache-2.0\n",
        "archetypes:\n",
        "  - atmosphere/ai-console\n",
        "```\n\n",
        "# mirroir-skills\n",
    );

    #[test]
    fn the_index_names_the_pack_its_version_and_archetypes() -> TestResult {
        let index = parse_pack_index("INDEX.md", INDEX)?;
        assert_eq!(index.name, "mirroir-skills");
        assert_eq!(index.pack_version, "1.0.0");
        assert_eq!(index.archetypes, vec!["atmosphere/ai-console".to_owned()]);
        Ok(())
    }

    #[test]
    fn an_index_without_a_yaml_block_is_refused() -> TestResult {
        match parse_pack_index("INDEX.md", "# just prose\n") {
            Err(RunnerError::SampleMissingYaml { .. }) => Ok(()),
            other => Err(format!("expected SampleMissingYaml, got {other:?}").into()),
        }
    }

    #[test]
    fn an_unknown_key_is_a_typo_not_ignored() -> TestResult {
        let typo = INDEX.replace("license:", "licence:");
        match parse_pack_index("INDEX.md", &typo) {
            Err(RunnerError::UnknownFields { keys, .. }) if keys == ["licence"] => Ok(()),
            other => Err(format!("expected UnknownFields, got {other:?}").into()),
        }
    }
}
