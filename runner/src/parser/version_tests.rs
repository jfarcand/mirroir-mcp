// ABOUTME: Unit tests for the schema-version seam — the version grammar, the major/minor gate, every loader.
// ABOUTME: Included by version.rs as its `tests` module, so `super::` names the seam.

use std::error::Error as StdError;
use std::fs;
use std::path::Path;
use std::result::Result as StdResult;

use super::{ArtifactKind, MinorPolicy, SchemaVersion, check, from_yaml_str};
use crate::error::{Result, RunnerError};
use crate::oracle::baseline::load_baseline;
use crate::oracle::judge_profiles::JudgeRegistry;
use crate::oracle::thresholds::{DriftMetric, parse_app_defaults, parse_drift_defaults};
use crate::parser::archetype::parse_archetype_manifest;
use crate::parser::local_overrides::parse_local_overrides;
use crate::parser::lockfile::parse_lockfile;
use crate::parser::mirroir::parse_mirroir_config;
use crate::parser::sample::SampleManifest;
use crate::parser::scenario::Scenario;

type TestResult = StdResult<(), Box<dyn StdError>>;

fn yaml_parse(source: serde_norway::Error) -> RunnerError {
    RunnerError::YamlParse {
        file: "test".to_owned(),
        source,
    }
}

#[test]
fn an_integer_is_a_major_with_minor_zero() -> TestResult {
    let v: SchemaVersion = serde_norway::from_str("1")?;
    assert_eq!(v, SchemaVersion::new(1, 0));
    assert_eq!(v.to_string(), "1");
    Ok(())
}

#[test]
fn a_quoted_string_carries_a_minor() -> TestResult {
    let v: SchemaVersion = serde_norway::from_str("\"1.3\"")?;
    assert_eq!(v, SchemaVersion::new(1, 3));
    assert_eq!(v.to_string(), "1.3");
    let bare: SchemaVersion = serde_norway::from_str("\"2\"")?;
    assert_eq!(bare, SchemaVersion::new(2, 0));
    Ok(())
}

#[test]
fn a_float_and_malformed_strings_are_refused() {
    for raw in [
        "1.2",
        "\"x\"",
        "\"1.\"",
        "\".1\"",
        "\"1.2.3\"",
        "-1",
        "\"-1\"",
        "true",
    ] {
        assert!(
            serde_norway::from_str::<SchemaVersion>(raw).is_err(),
            "{raw} should not parse as a version"
        );
    }
}

#[test]
fn serializes_back_to_the_form_it_was_written_in() -> TestResult {
    assert_eq!(serde_json::to_string(&SchemaVersion::new(1, 0))?, "1");
    assert_eq!(serde_json::to_string(&SchemaVersion::new(1, 4))?, "\"1.4\"");
    let round: SchemaVersion = serde_json::from_str("\"1.4\"")?;
    assert_eq!(round, SchemaVersion::new(1, 4));
    Ok(())
}

#[test]
fn the_gate_refuses_other_majors_and_relaxes_newer_minors() -> TestResult {
    let kind = ArtifactKind::Scenario;
    for major in [0, 2] {
        assert!(matches!(
            check(kind, "s", SchemaVersion::new(major, 0)),
            Err(RunnerError::UnsupportedVersion {
                artifact: ArtifactKind::Scenario,
                ..
            })
        ));
    }
    assert_eq!(
        check(kind, "s", SchemaVersion::new(1, 0))?,
        MinorPolicy::Strict
    );
    assert_eq!(
        check(kind, "s", SchemaVersion::new(1, 1))?,
        MinorPolicy::Tolerant
    );
    assert_eq!(kind.current(), SchemaVersion::new(1, 0));
    Ok(())
}

#[test]
fn the_unsupported_message_names_artifact_path_and_range() {
    let err = RunnerError::UnsupportedVersion {
        artifact: ArtifactKind::Lockfile,
        path: ".mirroir/mirroir.lock".to_owned(),
        found: SchemaVersion::new(2, 1),
        supports: 1..=1,
    };
    assert_eq!(
        err.to_string(),
        "unsupported mirroir.lock version 2.1 at .mirroir/mirroir.lock (supported majors: 1..=1)"
    );
}

/// One loader, fed a body (without its `version:` line) that carries a key
/// the schema does not define.
struct Loader {
    kind: ArtifactKind,
    body_with_unknown_key: &'static str,
    load: fn(&str) -> Result<()>,
}

fn fenced(yaml: &str) -> String {
    format!("# doc\n\n```yaml\n{yaml}```\n")
}

fn load_profiles(raw: &str) -> Result<()> {
    let dir = tempfile::tempdir().map_err(|source| RunnerError::Io {
        context: "tempdir".to_owned(),
        source,
    })?;
    let oracles = dir.path().join("oracles");
    fs::create_dir_all(&oracles)
        .and_then(|()| fs::write(oracles.join("profiles.yaml"), raw))
        .map_err(|source| RunnerError::Io {
            context: "write profiles.yaml".to_owned(),
            source,
        })?;
    JudgeRegistry::load(None, dir.path()).map(drop)
}

fn loaders() -> Vec<Loader> {
    vec![
        Loader {
            kind: ArtifactKind::Scenario,
            body_with_unknown_key: "name: s\nsteps:\n  - tap: { label: send, lable: typo }\n",
            load: |raw| {
                from_yaml_str::<Scenario>(ArtifactKind::Scenario, "s", raw, yaml_parse).map(drop)
            },
        },
        Loader {
            kind: ArtifactKind::Sample,
            body_with_unknown_key: "session:\n  boot:\n    command: echo\n    comand: typo\n  scenarios:\n    must_pass: []\n",
            load: |raw| {
                from_yaml_str::<SampleManifest>(ArtifactKind::Sample, "s", raw, yaml_parse)
                    .map(drop)
            },
        },
        Loader {
            kind: ArtifactKind::MirroirConfig,
            body_with_unknown_key: "plan:\n  must_pass: []\nnew_key: x\n",
            load: |raw| parse_mirroir_config("m", raw).map(drop),
        },
        Loader {
            kind: ArtifactKind::MirroirLocal,
            body_with_unknown_key: "plan: {}\nnew_key: x\n",
            load: |raw| parse_local_overrides("l", raw).map(drop),
        },
        Loader {
            kind: ArtifactKind::Lockfile,
            body_with_unknown_key: "generated_at: 2026-05-16T18:22:14Z\ngenerated_by: x\narchetypes: []\nnew_key: x\n",
            load: |raw| parse_lockfile("l", raw).map(drop),
        },
        Loader {
            kind: ArtifactKind::Archetype,
            body_with_unknown_key: "name: x/y\narchetype_version: 1.0.0\nprovides:\n  flows: []\n  flowz: []\n",
            load: |raw| parse_archetype_manifest("a", &fenced(raw)).map(drop),
        },
        Loader {
            kind: ArtifactKind::DriftDefaults,
            body_with_unknown_key: "fingerprint_similarity: { min: 0.9, mn: 0.8 }\n",
            load: |raw| parse_drift_defaults(Path::new("d"), raw).map(drop),
        },
        Loader {
            kind: ArtifactKind::JudgeProfiles,
            body_with_unknown_key: "profiles: []\nnew_key: x\n",
            load: load_profiles,
        },
        Loader {
            kind: ArtifactKind::AppMd,
            body_with_unknown_key: "app: x\ndrift_defaults:\n  new_metric: { max: 1 }\n",
            load: |raw| parse_app_defaults(Path::new("APP.md"), &fenced(raw)).map(drop),
        },
    ]
}

/// A newer major that also adds keys reports the version, not the keys:
/// the probe runs before the typed parse.
#[test]
fn every_loader_refuses_a_newer_major_before_parsing_its_keys() -> TestResult {
    for loader in loaders() {
        let raw = format!("version: 2\n{}", loader.body_with_unknown_key);
        match (loader.load)(&raw) {
            Err(RunnerError::UnsupportedVersion {
                artifact, found, ..
            }) if artifact == loader.kind && found == SchemaVersion::new(2, 0) => {}
            other => {
                return Err(format!(
                    "{}: expected UnsupportedVersion, got {other:?}",
                    loader.kind
                )
                .into());
            }
        }
    }
    Ok(())
}

#[test]
fn every_loader_ignores_unknown_keys_at_a_newer_minor() -> TestResult {
    for loader in loaders() {
        let raw = format!("version: \"1.1\"\n{}", loader.body_with_unknown_key);
        (loader.load)(&raw)
            .map_err(|e| format!("{}: a newer minor should load, got {e}", loader.kind))?;
    }
    Ok(())
}

#[test]
fn every_loader_refuses_unknown_keys_at_a_known_minor() -> TestResult {
    for loader in loaders() {
        let raw = format!("version: 1\n{}", loader.body_with_unknown_key);
        match (loader.load)(&raw) {
            Err(RunnerError::UnknownFields { artifact, keys, .. })
                if artifact == loader.kind && keys.len() == 1 => {}
            other => {
                return Err(
                    format!("{}: expected UnknownFields, got {other:?}", loader.kind).into(),
                );
            }
        }
    }
    Ok(())
}

#[test]
fn a_typo_inside_a_step_record_names_its_dotted_path() -> TestResult {
    let raw =
        "version: 1\nname: s\nsteps:\n  - report: pass\n  - tap: { label: send, lable: typo }\n";
    let Err(RunnerError::UnknownFields { keys, .. }) =
        from_yaml_str::<Scenario>(ArtifactKind::Scenario, "s", raw, yaml_parse)
    else {
        return Err("expected UnknownFields".into());
    };
    assert_eq!(keys, vec!["steps.1.tap.lable".to_owned()]);
    Ok(())
}

#[test]
fn an_app_md_shares_its_root_but_checks_drift_defaults() -> TestResult {
    let foreign = fenced(
        "version: 1\napp: x\nlocale: fr_CA\ndrift_defaults:\n  fingerprint_similarity: { min: 0.7 }\n",
    );
    let layer =
        parse_app_defaults(Path::new("APP.md"), &foreign)?.ok_or("drift_defaults dropped")?;
    assert_eq!(layer.get(DriftMetric::FingerprintSimilarity), Some(0.7));
    Ok(())
}

#[test]
fn an_app_md_and_a_profiles_file_require_a_version() {
    assert!(parse_app_defaults(Path::new("APP.md"), &fenced("app: x\n")).is_err());
    assert!(load_profiles("profiles: []\n").is_err());
}

#[test]
fn a_last_green_store_goes_through_the_same_gate() -> TestResult {
    let dir = tempfile::tempdir()?;
    let harness = dir.path().join(".harness");
    fs::create_dir_all(&harness)?;
    let store = harness.join("last-green.json");

    fs::write(&store, r#"{"version": 2, "scenarios": {}, "new_key": 1}"#)?;
    assert!(matches!(
        load_baseline(dir.path(), "x"),
        Err(RunnerError::UnsupportedVersion {
            artifact: ArtifactKind::LastGreen,
            ..
        })
    ));
    fs::write(
        &store,
        r#"{"version": "1.1", "scenarios": {}, "new_key": 1}"#,
    )?;
    assert!(load_baseline(dir.path(), "x")?.is_none());
    fs::write(&store, r#"{"version": 1, "scenarios": {}, "new_key": 1}"#)?;
    assert!(matches!(
        load_baseline(dir.path(), "x"),
        Err(RunnerError::UnknownFields {
            artifact: ArtifactKind::LastGreen,
            ..
        })
    ));
    Ok(())
}
