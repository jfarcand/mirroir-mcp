// ABOUTME: Artifact schema-version seam — SchemaVersion, ArtifactKind, and the probe-then-parse loaders.
// ABOUTME: An unsupported major is a hard error; a newer minor loads with its unknown keys reported.

use std::fmt;
use std::ops::RangeInclusive;
use std::result::Result as StdResult;

use serde::de::{self, DeserializeOwned, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_ignored::Path as IgnoredPath;
use tracing::warn;

use crate::error::{Result, RunnerError};

/// The key every versioned artifact carries at its root. The probe owns it, so
/// a typed shape that does not model it never reports it as unknown.
const VERSION_KEY: &str = "version";

/// An artifact's `version:` — a major and a minor.
///
/// The canonical spelling is the integer `version: 1`, which means major 1,
/// minor 0. A quoted `"MAJOR.MINOR"` string carries a minor. A bare YAML float
/// such as `1.2` is refused: `1.10` would read back as `1.1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SchemaVersion {
    /// Major version. A binary loads only the majors its [`ArtifactKind::supports`] lists.
    pub major: u32,
    /// Minor version. A minor newer than [`ArtifactKind::known_minor`] loads
    /// forward-tolerantly; one at or below it is strict.
    pub minor: u32,
}

impl SchemaVersion {
    /// A version from its two parts.
    #[must_use]
    pub const fn new(major: u32, minor: u32) -> Self {
        Self { major, minor }
    }

    fn parse(text: &str) -> Option<Self> {
        let (major, minor) = match text.split_once('.') {
            Some((major, minor)) => (major, Some(minor)),
            None => (text, None),
        };
        let digits = |part: &str| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit());
        if !digits(major) || minor.is_some_and(|m| !digits(m)) {
            return None;
        }
        Some(Self {
            major: major.parse().ok()?,
            minor: minor.map_or(Some(0), |m| m.parse().ok())?,
        })
    }
}

impl fmt::Display for SchemaVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.minor == 0 {
            write!(f, "{}", self.major)
        } else {
            write!(f, "{}.{}", self.major, self.minor)
        }
    }
}

impl Serialize for SchemaVersion {
    fn serialize<S: Serializer>(&self, serializer: S) -> StdResult<S::Ok, S::Error> {
        if self.minor == 0 {
            serializer.serialize_u32(self.major)
        } else {
            serializer.collect_str(self)
        }
    }
}

struct SchemaVersionVisitor;

impl Visitor<'_> for SchemaVersionVisitor {
    type Value = SchemaVersion;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("an integer major version or a \"MAJOR.MINOR\" string")
    }

    fn visit_u64<E: de::Error>(self, value: u64) -> StdResult<SchemaVersion, E> {
        u32::try_from(value)
            .map(|major| SchemaVersion::new(major, 0))
            .map_err(|_| E::invalid_value(de::Unexpected::Unsigned(value), &self))
    }

    fn visit_i64<E: de::Error>(self, value: i64) -> StdResult<SchemaVersion, E> {
        u32::try_from(value)
            .map(|major| SchemaVersion::new(major, 0))
            .map_err(|_| E::invalid_value(de::Unexpected::Signed(value), &self))
    }

    fn visit_str<E: de::Error>(self, value: &str) -> StdResult<SchemaVersion, E> {
        SchemaVersion::parse(value)
            .ok_or_else(|| E::invalid_value(de::Unexpected::Str(value), &self))
    }
}

impl<'de> Deserialize<'de> for SchemaVersion {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> StdResult<Self, D::Error> {
        deserializer.deserialize_any(SchemaVersionVisitor)
    }
}

/// Every artifact the runner loads and gates on its `version:`.
///
/// The run summary the runner writes (`mirroir::run_io`) is not here: it is a
/// runner output, never loaded back, so it has no reader whose compatibility
/// this seam could gate. The Playwright report JSON is not here either — its
/// shape is Playwright's, which carries no version key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ArtifactKind {
    /// A scenario YAML file.
    Scenario,
    /// The fenced YAML block of a `SAMPLE.md`.
    Sample,
    /// `.mirroir/mirroir.yaml`.
    MirroirConfig,
    /// `.mirroir/mirroir.local.yaml`.
    MirroirLocal,
    /// `.mirroir/mirroir.lock`.
    Lockfile,
    /// An archetype pack's `archetype.md`.
    Archetype,
    /// `drift-defaults.yaml`.
    DriftDefaults,
    /// `oracles/profiles.yaml`.
    JudgeProfiles,
    /// The fenced YAML block of an `APP.md`.
    AppMd,
    /// `.harness/last-green.json`.
    LastGreen,
    /// A composed sample's `.compose-manifest.json`.
    ComposeManifest,
}

impl ArtifactKind {
    /// The majors this binary loads for the artifact.
    #[must_use]
    pub const fn supports(self) -> RangeInclusive<u32> {
        match self {
            Self::Scenario
            | Self::Sample
            | Self::MirroirConfig
            | Self::MirroirLocal
            | Self::Lockfile
            | Self::Archetype
            | Self::DriftDefaults
            | Self::JudgeProfiles
            | Self::AppMd
            | Self::LastGreen
            | Self::ComposeManifest => 1..=1,
        }
    }

    /// The newest minor of the newest supported major this binary models.
    #[must_use]
    pub const fn known_minor(self) -> u32 {
        match self {
            Self::Scenario
            | Self::Sample
            | Self::MirroirConfig
            | Self::MirroirLocal
            | Self::Lockfile
            | Self::Archetype
            | Self::DriftDefaults
            | Self::JudgeProfiles
            | Self::AppMd
            | Self::LastGreen
            | Self::ComposeManifest => 0,
        }
    }

    /// The version a writer stamps on a fresh artifact of this kind.
    #[must_use]
    pub const fn current(self) -> SchemaVersion {
        SchemaVersion::new(*self.supports().end(), self.known_minor())
    }

    /// Whether the artifact's root mapping is shared with other tools, so a
    /// top-level key the runner does not model is someone else's, not a typo.
    /// `APP.md` is: the runner reads its `drift_defaults:` while the explorer
    /// and the skill tooling read `app`, `archetype`, `locale`, and the rest.
    /// Keys nested under the runner's own keys are still checked.
    #[must_use]
    pub const fn shares_root(self) -> bool {
        matches!(self, Self::AppMd)
    }

    /// The artifact as an author knows it.
    #[must_use]
    pub const fn file_name(self) -> &'static str {
        match self {
            Self::Scenario => "scenario.yaml",
            Self::Sample => "SAMPLE.md",
            Self::MirroirConfig => "mirroir.yaml",
            Self::MirroirLocal => "mirroir.local.yaml",
            Self::Lockfile => "mirroir.lock",
            Self::Archetype => "archetype.md",
            Self::DriftDefaults => "drift-defaults.yaml",
            Self::JudgeProfiles => "profiles.yaml",
            Self::AppMd => "APP.md",
            Self::LastGreen => "last-green.json",
            Self::ComposeManifest => ".compose-manifest.json",
        }
    }
}

impl fmt::Display for ArtifactKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.file_name())
    }
}

/// How a typed parse treats keys its shape does not model.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MinorPolicy {
    /// The minor is one this binary knows: an unknown key is a typo, and an error.
    Strict,
    /// The minor is newer than this binary: unknown keys are what that minor
    /// added, so they are ignored and logged.
    Tolerant,
}

/// Gate `found` against what this binary supports for `kind`.
///
/// # Errors
///
/// [`RunnerError::UnsupportedVersion`] when the major is outside [`ArtifactKind::supports`].
pub fn check(kind: ArtifactKind, path: &str, found: SchemaVersion) -> Result<MinorPolicy> {
    let supports = kind.supports();
    if !supports.contains(&found.major) {
        return Err(RunnerError::UnsupportedVersion {
            artifact: kind,
            path: path.to_owned(),
            found,
            supports,
        });
    }
    if found.minor > kind.known_minor() {
        Ok(MinorPolicy::Tolerant)
    } else {
        Ok(MinorPolicy::Strict)
    }
}

/// The root of any versioned artifact, read before the typed parse so a newer
/// major that also adds keys reports [`RunnerError::UnsupportedVersion`]
/// instead of a parse error about the keys.
#[derive(Deserialize)]
struct Probe {
    version: SchemaVersion,
}

/// Probe a YAML body, gate its version, then parse it into `T`.
///
/// `on_parse` maps a YAML error (a missing `version:` included) into the
/// loader's own error variant.
///
/// # Errors
///
/// * Whatever `on_parse` builds when the body is not valid YAML for `T`.
/// * [`RunnerError::UnsupportedVersion`] for an unsupported major.
/// * [`RunnerError::UnknownFields`] for unknown keys under [`MinorPolicy::Strict`].
pub fn from_yaml_str<T: DeserializeOwned>(
    kind: ArtifactKind,
    path: &str,
    raw: &str,
    on_parse: impl Fn(serde_norway::Error) -> RunnerError,
) -> Result<T> {
    let probe: Probe = serde_norway::from_str(raw).map_err(&on_parse)?;
    let policy = check(kind, path, probe.version)?;
    let mut unknown = Vec::new();
    let parsed = serde_ignored::deserialize(serde_norway::Deserializer::from_str(raw), |p| {
        record(kind, &mut unknown, &p);
    })
    .map_err(&on_parse)?;
    report_unknown(kind, path, probe.version, policy, unknown)?;
    Ok(parsed)
}

/// Probe a JSON body, gate its version, then parse it into `T`.
///
/// # Errors
///
/// Same as [`from_yaml_str`], with `on_parse` mapping JSON errors.
pub fn from_json_str<T: DeserializeOwned>(
    kind: ArtifactKind,
    path: &str,
    raw: &str,
    on_parse: impl Fn(serde_json::Error) -> RunnerError,
) -> Result<T> {
    let probe: Probe = serde_json::from_str(raw).map_err(&on_parse)?;
    let policy = check(kind, path, probe.version)?;
    let mut unknown = Vec::new();
    let mut deserializer = serde_json::Deserializer::from_str(raw);
    let parsed = serde_ignored::deserialize(&mut deserializer, |p| record(kind, &mut unknown, &p))
        .map_err(&on_parse)?;
    deserializer.end().map_err(&on_parse)?;
    report_unknown(kind, path, probe.version, policy, unknown)?;
    Ok(parsed)
}

fn record(kind: ArtifactKind, unknown: &mut Vec<String>, path: &IgnoredPath<'_>) {
    let top_level = matches!(
        path,
        IgnoredPath::Map {
            parent: IgnoredPath::Root,
            ..
        }
    );
    if top_level && kind.shares_root() {
        return;
    }
    let dotted = dotted(path);
    if dotted != VERSION_KEY {
        unknown.push(dotted);
    }
}

/// A key path as an author would write it: `steps.0.tap.lable`. The wrappers
/// serde inserts for options and newtypes are not keys and are left out.
fn dotted(path: &IgnoredPath<'_>) -> String {
    let (parent, segment) = match path {
        IgnoredPath::Root => return String::new(),
        IgnoredPath::Seq { parent, index } => (*parent, index.to_string()),
        IgnoredPath::Map { parent, key } => (*parent, key.clone()),
        IgnoredPath::Some { parent }
        | IgnoredPath::NewtypeStruct { parent }
        | IgnoredPath::NewtypeVariant { parent } => return dotted(parent),
    };
    let prefix = dotted(parent);
    if prefix.is_empty() {
        segment
    } else {
        format!("{prefix}.{segment}")
    }
}

fn report_unknown(
    kind: ArtifactKind,
    path: &str,
    version: SchemaVersion,
    policy: MinorPolicy,
    keys: Vec<String>,
) -> Result<()> {
    if keys.is_empty() {
        return Ok(());
    }
    match policy {
        MinorPolicy::Strict => Err(RunnerError::UnknownFields {
            artifact: kind,
            path: path.to_owned(),
            keys,
        }),
        MinorPolicy::Tolerant => {
            warn!(
                artifact = %kind,
                path,
                %version,
                ?keys,
                "artifact minor is newer than this binary knows; ignoring its unknown keys"
            );
            Ok(())
        }
    }
}

#[cfg(test)]
#[path = "version_tests.rs"]
mod tests;
