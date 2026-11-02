// ABOUTME: Tests for `pack install` against real git fixture repositories built in a tempdir.
// ABOUTME: Included by pack_install.rs as its `tests` module; covers layout, idempotence, refusals, refs, provenance.

use std::error::Error as StdError;
use std::fs;
use std::path::Path;
use std::result::Result as StdResult;

use tempfile::TempDir;

use super::install_pack;
use crate::error::RunnerError;
use crate::mirroir::error::MirroirError;
use crate::mirroir::git::{checkout_head, gather_git_source, run_git};
use crate::mirroir::resolve::{ArchetypeOrigin, resolve_archetype, skills_root};
use crate::parser::mirroir::{ArchetypeRef, ArchetypeRefKind};

type TestResult = StdResult<(), Box<dyn StdError>>;

/// A pack repository on disk: `INDEX.md` at `version` plus one archetype.
struct FixturePack {
    dir: TempDir,
}

impl FixturePack {
    fn new(pack_version: &str) -> StdResult<Self, Box<dyn StdError>> {
        let fixture = Self {
            dir: TempDir::new()?,
        };
        run_git(
            fixture.path(),
            &["init", "--quiet", "--initial-branch=main"],
        )?;
        fixture.write_index("demo-pack", pack_version, "web/console")?;
        fixture.write_archetype("web/console", "web/console")?;
        fixture.commit("initial")?;
        Ok(fixture)
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn source(&self) -> String {
        self.path().display().to_string()
    }

    fn write(&self, relative: &str, body: &str) -> StdResult<(), Box<dyn StdError>> {
        let path = self.path().join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, body)?;
        Ok(())
    }

    fn write_index(
        &self,
        name: &str,
        pack_version: &str,
        archetype: &str,
    ) -> StdResult<(), Box<dyn StdError>> {
        self.write(
            "INDEX.md",
            &format!(
                "```yaml\nversion: 1\nname: {name}\npack_version: {pack_version}\narchetypes:\n  - {archetype}\n```\n\n# {name}\n"
            ),
        )
    }

    fn write_archetype(&self, directory: &str, declared: &str) -> StdResult<(), Box<dyn StdError>> {
        self.write(
            &format!("archetypes/{directory}/archetype.md"),
            &format!(
                "```yaml\nversion: 1\nname: {declared}\narchetype_version: 1.0.0\nprovides:\n  flows:\n    - smoke\n```\n"
            ),
        )
    }

    fn commit(&self, message: &str) -> StdResult<String, Box<dyn StdError>> {
        run_git(self.path(), &["add", "--all"])?;
        run_git(
            self.path(),
            &[
                "-c",
                "user.name=fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "--quiet",
                "--allow-empty",
                "-m",
                message,
            ],
        )?;
        Ok(run_git(self.path(), &["rev-parse", "HEAD"])?)
    }
}

/// Entries left in `~/.mirroir/skills/` besides installed packs — a staging
/// directory that outlived its install.
fn leftovers(home: &Path) -> StdResult<Vec<String>, Box<dyn StdError>> {
    let mut names = Vec::new();
    for entry in fs::read_dir(skills_root(home))? {
        let name = entry?.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            names.push(name);
        }
    }
    Ok(names)
}

#[test]
fn a_pack_lands_at_its_index_name_and_version_and_resolves() -> TestResult {
    let pack = FixturePack::new("1.2.0")?;
    let home = TempDir::new()?;

    let installed = install_pack(&pack.source(), None, home.path())?;

    assert!(installed.fresh);
    let expected = home.path().join(".mirroir/skills/demo-pack/1.2.0");
    assert_eq!(installed.directory, expected);
    assert_eq!(
        installed.commit,
        run_git(pack.path(), &["rev-parse", "HEAD"])?
    );
    assert_eq!(leftovers(home.path())?, Vec::<String>::new());

    let reference = ArchetypeRef {
        kind: ArchetypeRefKind::Pack,
        pack: Some("demo-pack".to_owned()),
        name: "web/console".to_owned(),
        version: Some("v1".to_owned()),
    };
    let resolved = resolve_archetype(&reference, home.path(), home.path(), None)?;
    assert_eq!(
        resolved.origin,
        ArchetypeOrigin::Pack {
            pack: "demo-pack".to_owned(),
            name: "web/console".to_owned(),
            version: "1.2.0".to_owned(),
        }
    );
    // The install is a git checkout: lockfiles record where it came from.
    assert_eq!(gather_git_source(&expected)?.commit, installed.commit);
    Ok(())
}

#[test]
fn reinstalling_the_same_commit_changes_nothing() -> TestResult {
    let pack = FixturePack::new("1.0.0")?;
    let home = TempDir::new()?;
    install_pack(&pack.source(), None, home.path())?;

    let again = install_pack(&pack.source(), None, home.path())?;

    assert!(!again.fresh);
    assert_eq!(leftovers(home.path())?, Vec::<String>::new());
    Ok(())
}

/// An installed version is immutable: lockfiles pin its checksum, so a new
/// commit under the same `pack_version` is refused and the install is kept.
#[test]
fn a_different_commit_under_an_installed_version_is_refused() -> TestResult {
    let pack = FixturePack::new("1.0.0")?;
    let home = TempDir::new()?;
    let first = install_pack(&pack.source(), None, home.path())?;
    pack.write("archetypes/web/console/APP.md", "# changed\n")?;
    let second = pack.commit("change the archetype")?;

    match install_pack(&pack.source(), None, home.path()) {
        Err(RunnerError::Mirroir(MirroirError::PackVersionConflict {
            installed,
            incoming,
            ..
        })) => {
            assert_eq!(installed, first.commit);
            assert_eq!(incoming, second);
        }
        other => return Err(format!("expected PackVersionConflict, got {other:?}").into()),
    }
    assert_eq!(
        run_git(&first.directory, &["rev-parse", "HEAD"])?,
        first.commit
    );
    assert_eq!(leftovers(home.path())?, Vec::<String>::new());
    Ok(())
}

/// A hand-copied install (the documented `cp`/clone-less layout) holds no
/// commit to compare, so it is never silently replaced.
#[test]
fn a_directory_that_is_no_checkout_is_never_overwritten() -> TestResult {
    let pack = FixturePack::new("1.0.0")?;
    let home = TempDir::new()?;
    let copied = home.path().join(".mirroir/skills/demo-pack/1.0.0");
    fs::create_dir_all(&copied)?;
    fs::write(copied.join("INDEX.md"), "hand copy\n")?;

    match install_pack(&pack.source(), None, home.path()) {
        Err(RunnerError::Mirroir(MirroirError::PackVersionConflict { installed, .. })) => {
            assert!(installed.contains("no git checkout"), "{installed}");
        }
        other => return Err(format!("expected PackVersionConflict, got {other:?}").into()),
    }
    assert_eq!(fs::read_to_string(copied.join("INDEX.md"))?, "hand copy\n");
    Ok(())
}

/// A hand copy nested in a repository (a `$HOME` kept in git) must not be
/// mistaken for a checkout: neither its commit nor its provenance is the
/// enclosing repository's.
#[test]
fn a_hand_copy_inside_another_repository_has_no_commit_of_its_own() -> TestResult {
    let pack = FixturePack::new("1.0.0")?;
    let home = TempDir::new()?;
    run_git(home.path(), &["init", "--quiet"])?;
    let copied = home.path().join(".mirroir/skills/demo-pack/1.0.0");
    fs::create_dir_all(&copied)?;

    assert_eq!(checkout_head(&copied), None);
    assert!(gather_git_source(&copied).is_err());
    match install_pack(&pack.source(), None, home.path()) {
        Err(RunnerError::Mirroir(MirroirError::PackVersionConflict { installed, .. })) => {
            assert!(installed.contains("no git checkout"), "{installed}");
            Ok(())
        }
        other => Err(format!("expected PackVersionConflict, got {other:?}").into()),
    }
}

#[test]
fn a_ref_installs_that_tag_not_the_default_branch() -> TestResult {
    let pack = FixturePack::new("1.0.0")?;
    let tagged = run_git(pack.path(), &["rev-parse", "HEAD"])?;
    run_git(pack.path(), &["tag", "v1.0.0"])?;
    pack.write_index("demo-pack", "1.1.0", "web/console")?;
    pack.commit("bump")?;
    let home = TempDir::new()?;

    let installed = install_pack(&pack.source(), Some("v1.0.0"), home.path())?;

    assert_eq!(installed.index.pack_version, "1.0.0");
    assert_eq!(installed.commit, tagged);
    let source = gather_git_source(&installed.directory)?;
    assert_eq!(source.tag.as_deref(), Some("v1.0.0"));
    Ok(())
}

/// Each refusal leaves `~/.mirroir/skills/` exactly as it was.
fn assert_refused(pack: &FixturePack, needle: &str) -> TestResult {
    let home = TempDir::new()?;
    match install_pack(&pack.source(), None, home.path()) {
        Err(RunnerError::Mirroir(MirroirError::PackInvalid { reason, .. })) => {
            assert!(reason.contains(needle), "{reason}");
        }
        other => return Err(format!("expected PackInvalid, got {other:?}").into()),
    }
    assert_eq!(leftovers(home.path())?, Vec::<String>::new());
    assert!(!home.path().join(".mirroir/skills/demo-pack").exists());
    Ok(())
}

#[test]
fn a_listed_archetype_that_is_missing_is_refused() -> TestResult {
    let pack = FixturePack::new("1.0.0")?;
    pack.write_index("demo-pack", "1.0.0", "web/absent")?;
    pack.commit("list an archetype that does not exist")?;
    assert_refused(&pack, "web/absent")
}

#[test]
fn an_archetype_that_names_itself_differently_is_refused() -> TestResult {
    let pack = FixturePack::new("1.0.0")?;
    pack.write_archetype("web/console", "web/other")?;
    pack.commit("misname")?;
    assert_refused(&pack, "declares itself as `web/other`")
}

#[test]
fn a_version_that_is_not_exact_semver_is_refused() -> TestResult {
    let pack = FixturePack::new("v1.0")?;
    assert_refused(&pack, "pack_version `v1.0`")
}

#[test]
fn a_pack_name_with_a_separator_is_refused() -> TestResult {
    let pack = FixturePack::new("1.0.0")?;
    pack.write_index("../escape", "1.0.0", "web/console")?;
    pack.commit("escape")?;
    assert_refused(&pack, "not a single directory name")
}

#[test]
fn a_source_that_cannot_be_fetched_leaves_nothing_behind() -> TestResult {
    let home = TempDir::new()?;
    let missing = home.path().join("no-such-repo").display().to_string();
    match install_pack(&missing, None, home.path()) {
        Err(RunnerError::Io { context, .. }) => assert!(context.contains("clone"), "{context}"),
        other => return Err(format!("expected Io, got {other:?}").into()),
    }
    assert_eq!(leftovers(home.path())?, Vec::<String>::new());
    Ok(())
}
