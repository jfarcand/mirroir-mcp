// ABOUTME: `--sample <dir>` session machinery — SAMPLE.md selection, shared boot, spawn-arg resolution.
// ABOUTME: Drives each selected scenario through `run_scenario_with_context` with manifest context active.

use std::collections::HashMap;
use std::path::Path;

use tracing::{error, info};

use crate::baseline_coverage::ensure_ios_baselines_are_referenced;
use crate::error::{Result, RunnerError};
use crate::parser::sample::SampleManifest;
use crate::parser::step::{KillArgs, PortState, SpawnArgs, WaitPortArgs};
use crate::replay::{ReplayRoots, SampleContext, load_sample_manifest, run_scenario_with_context};
use crate::scenario_set::{ScenarioSet, select_scenarios};
use crate::target::process::ProcessRegistry;
use crate::verdict::RunVerdict;

/// Implements `mirroir-run --sample <dir>`.
///
/// Loads `<dir>/SAMPLE.md`, picks the scenario list for `set`, and drives
/// each scenario through [`run_scenario_with_context`] with manifest context
/// active. Aggregates verdicts; returns [`RunnerError::SampleScenarioFailures`]
/// when at least one scenario reported FAIL, and [`RunVerdict::Drift`] when
/// none failed and at least one drifted — a sample that drifted is not a
/// failure, and it is not a clean pass either.
///
/// # Errors
///
/// * Anything [`load_sample_manifest`] returns.
/// * Anything [`select_scenarios`] returns — a set that drives none of the
///   sample's scenarios is refused here rather than replayed as a pass over
///   nothing.
/// * Anything [`ensure_ios_baselines_are_referenced`] returns — a captured
///   surface committed under `baselines/` that no declared scenario compares
///   is refused before the session boots, and so is a selected scenario that
///   will not parse, since the guard reads it to answer that question.
/// * [`RunnerError::SampleScenarioFailures`] when one or more scenarios failed.
pub async fn run_sample(
    sample_dir: &Path,
    set: ScenarioSet,
    roots: ReplayRoots<'_>,
) -> Result<RunVerdict> {
    let sample_md_path = sample_dir.join("SAMPLE.md");
    let manifest = load_sample_manifest(&sample_md_path)?;
    info!(
        dir = %sample_dir.display(),
        name = ?manifest.name,
        must_pass = manifest.session.scenarios.must_pass.len(),
        nice_to_pass = manifest.session.scenarios.nice_to_pass.len(),
        boot_once = manifest.session.boot_once,
        "sample run starting"
    );

    let selected = select_scenarios(sample_dir, &manifest, set)?;
    ensure_ios_baselines_are_referenced(sample_dir, &manifest, set, &selected)?;
    let context = SampleContext {
        sample_dir,
        manifest: &manifest,
    };

    let mut session: Option<ProcessRegistry> = if manifest.session.boot_once {
        Some(boot_session(sample_dir, &manifest).await?)
    } else {
        None
    };

    let mut failed = 0usize;
    let mut verdict = RunVerdict::Pass;
    let mut first_error: Option<String> = None;
    let total = selected.len();
    for scenario_rel in selected {
        let resolved = sample_dir.join(&scenario_rel);
        info!(scenario = %scenario_rel.display(), "running scenario");
        let outcome =
            run_scenario_with_context(&resolved, Some(context), session.as_mut(), roots).await;
        match outcome {
            Ok(scenario_verdict) => {
                verdict = verdict.merge(scenario_verdict);
                info!(
                    scenario = %scenario_rel.display(),
                    verdict = %scenario_verdict,
                    "scenario completed"
                );
            }
            Err(err) => {
                let message = format!("{}: {err}", scenario_rel.display());
                error!(scenario = %scenario_rel.display(), error = %err, "scenario failed");
                first_error.get_or_insert(message);
                failed += 1;
            }
        }
    }

    // Tear down the shared session boot, if any.
    if let Some(mut shared) = session.take() {
        let kill_args = KillArgs {
            id: SESSION_BOOT_ID.to_owned(),
            grace_s: 3,
            cleanup: None,
        };
        if let Err(err) = shared.kill_process(&kill_args).await {
            error!(error = %err, "session boot teardown failed");
        }
    }

    if failed == 0 {
        info!(dir = %sample_dir.display(), total, verdict = %verdict, "sample run completed");
        Ok(verdict)
    } else {
        Err(RunnerError::SampleScenarioFailures {
            failed,
            total,
            first_error: first_error.unwrap_or_else(|| "no failure detail recorded".to_owned()),
        })
    }
}

/// Identifier used for the shared subprocess in `boot_once: true` sample
/// runs. Scenarios authored with `spawn: { from: SAMPLE.md, id: ... }` are
/// expected to use this same id so the spawn becomes an idempotent no-op.
const SESSION_BOOT_ID: &str = "session";

async fn boot_session(sample_dir: &Path, manifest: &SampleManifest) -> Result<ProcessRegistry> {
    let mut registry = ProcessRegistry::default();
    let mut env = HashMap::new();
    env.clone_from(&manifest.session.boot.env);
    let cwd = manifest
        .session
        .boot
        .cwd
        .as_ref()
        .map(|rel| sample_dir.join(rel).display().to_string());
    let args = SpawnArgs {
        id: SESSION_BOOT_ID.to_owned(),
        from: Some("SAMPLE.md".to_owned()),
        command: Some(manifest.session.boot.command.clone()),
        cwd,
        env,
        timeout_s: manifest.session.boot.timeout_s,
        expect_exit: None,
        capture_stdout: None,
    };
    info!(
        id = SESSION_BOOT_ID,
        command = %manifest.session.boot.command,
        "booting shared session subprocess"
    );
    registry.spawn(&args)?;

    if let Some(port) = manifest.session.boot_ready_port {
        let timeout_s = manifest.session.boot_ready_timeout_s.unwrap_or(60);
        info!(port, timeout_s, "waiting for session boot ready port");
        registry
            .wait_port(&WaitPortArgs {
                port,
                timeout_s,
                expect: PortState::Open,
            })
            .await?;
    }

    Ok(registry)
}

/// Apply manifest defaults to a `spawn:` step that wrote `from: SAMPLE.md`.
///
/// Inline values on the step always win — the manifest only fills fields the
/// scenario left blank. The env map merges with inline overrides taking
/// precedence per-key. When `from: SAMPLE.md` is set without a sample context
/// (e.g. user ran `--run-scenario` on a scenario authored for sample mode),
/// returns [`RunnerError::SpawnFromSampleNoContext`].
pub fn resolve_spawn_args(
    args: &SpawnArgs,
    context: Option<&SampleContext<'_>>,
) -> Result<SpawnArgs> {
    if args.from.as_deref() != Some("SAMPLE.md") {
        return Ok(args.clone());
    }
    let Some(ctx) = context else {
        return Err(RunnerError::SpawnFromSampleNoContext {
            id: args.id.clone(),
        });
    };
    let boot = &ctx.manifest.session.boot;
    let mut resolved = args.clone();

    if resolved.command.is_none() {
        resolved.command = Some(boot.command.clone());
    }
    if resolved.cwd.is_none()
        && let Some(rel) = &boot.cwd
    {
        let abs = ctx.sample_dir.join(rel);
        resolved.cwd = Some(abs.display().to_string());
    }
    if resolved.timeout_s.is_none() {
        resolved.timeout_s = boot.timeout_s;
    }
    for (k, v) in &boot.env {
        resolved.env.entry(k.clone()).or_insert_with(|| v.clone());
    }
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use std::env;
    use std::error::Error as StdError;
    use std::fs;
    use std::path::PathBuf;
    use std::result::Result as StdResult;

    use super::*;
    use crate::parser::sample::{Boot, SAMPLE_SCHEMA_VERSION, Scenarios, Session};
    use crate::replay::load_sample_manifest_with_extras;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn manifest_with_boot(boot: Boot) -> SampleManifest {
        SampleManifest {
            version: SAMPLE_SCHEMA_VERSION,
            name: None,
            description: None,
            session: Session {
                boot,
                scenarios: Scenarios {
                    must_pass: Vec::new(),
                    nice_to_pass: Vec::new(),
                },
                boot_once: false,
                boot_ready_port: None,
                boot_ready_timeout_s: None,
            },
        }
    }

    fn spawn_args(id: &str) -> SpawnArgs {
        SpawnArgs {
            id: id.to_owned(),
            from: None,
            command: None,
            cwd: None,
            env: HashMap::new(),
            timeout_s: None,
            expect_exit: None,
            capture_stdout: None,
        }
    }

    #[test]
    fn resolve_spawn_passthrough_when_from_is_not_sample_md() -> TestResult {
        let mut args = spawn_args("server");
        args.command = Some("./bin/server --port 8080".to_owned());
        let resolved = resolve_spawn_args(&args, None)?;
        assert_eq!(
            resolved.command.as_deref(),
            Some("./bin/server --port 8080")
        );
        Ok(())
    }

    #[test]
    fn resolve_spawn_errors_when_sample_md_without_context() -> TestResult {
        let mut args = spawn_args("server");
        args.from = Some("SAMPLE.md".to_owned());
        let res = resolve_spawn_args(&args, None);
        let Err(RunnerError::SpawnFromSampleNoContext { id }) = res else {
            return Err(format!("expected SpawnFromSampleNoContext, got {res:?}").into());
        };
        if id != "server" {
            return Err(format!("wrong id `{id}`").into());
        }
        Ok(())
    }

    #[test]
    fn resolve_spawn_fills_command_and_cwd_from_manifest() -> TestResult {
        let mut env_map = HashMap::new();
        env_map.insert("SPRING_PROFILES_ACTIVE".to_owned(), "ci".to_owned());
        let manifest = manifest_with_boot(Boot {
            command: "java -jar target/foo.jar".to_owned(),
            cwd: Some("subdir".to_owned()),
            env: env_map,
            timeout_s: Some(45),
        });
        let sample_dir = PathBuf::from("/samples/foo");
        let context = SampleContext {
            sample_dir: &sample_dir,
            manifest: &manifest,
        };
        let mut args = spawn_args("server");
        args.from = Some("SAMPLE.md".to_owned());

        let resolved = resolve_spawn_args(&args, Some(&context))?;
        assert_eq!(
            resolved.command.as_deref(),
            Some("java -jar target/foo.jar")
        );
        assert_eq!(resolved.cwd.as_deref(), Some("/samples/foo/subdir"));
        assert_eq!(resolved.timeout_s, Some(45));
        assert_eq!(
            resolved.env.get("SPRING_PROFILES_ACTIVE"),
            Some(&"ci".to_owned())
        );
        Ok(())
    }

    #[test]
    fn resolve_spawn_inline_command_wins_over_manifest() -> TestResult {
        let manifest = manifest_with_boot(Boot {
            command: "java -jar target/foo.jar".to_owned(),
            cwd: None,
            env: HashMap::new(),
            timeout_s: None,
        });
        let sample_dir = PathBuf::from("/samples/foo");
        let context = SampleContext {
            sample_dir: &sample_dir,
            manifest: &manifest,
        };
        let mut args = spawn_args("server");
        args.from = Some("SAMPLE.md".to_owned());
        args.command = Some("./bin/override --debug".to_owned());
        args.env
            .insert("SPRING_PROFILES_ACTIVE".to_owned(), "dev".to_owned());

        let resolved = resolve_spawn_args(&args, Some(&context))?;
        assert_eq!(resolved.command.as_deref(), Some("./bin/override --debug"));
        assert_eq!(
            resolved.env.get("SPRING_PROFILES_ACTIVE"),
            Some(&"dev".to_owned())
        );
        Ok(())
    }

    #[test]
    fn load_sample_manifest_substitutes_env_vars_in_yaml_body() -> TestResult {
        let tmp = tempfile::tempdir()?;
        let sample_md = tmp.path().join("SAMPLE.md");
        let markdown = "# Sample\n\n```yaml\nversion: 1\nname: sub-test\nsession:\n  boot:\n    command: \"java -jar app.jar\"\n    cwd: \"${TEST_HOME:-default-cwd}\"\n  scenarios:\n    must_pass:\n      - smoke.yaml\n```\n";
        fs::write(&sample_md, markdown)?;

        // Substitution via extras (no process-env mutation — keep tests hermetic).
        let with_value = load_sample_manifest_with_extras(
            &sample_md,
            &[("TEST_HOME", "/tmp/atmosphere-test-home".to_owned())],
        )?;
        assert_eq!(
            with_value.session.boot.cwd.as_deref(),
            Some("/tmp/atmosphere-test-home")
        );

        // Default-fallback when the var is absent from extras and process env.
        let with_default = load_sample_manifest_with_extras(&sample_md, &[])?;
        // Skip the assertion if a real TEST_HOME leaked in from the developer's
        // environment — the substitution semantics are exercised by the value
        // branch above either way.
        if env::var("TEST_HOME").is_err() {
            assert_eq!(
                with_default.session.boot.cwd.as_deref(),
                Some("default-cwd")
            );
        }
        Ok(())
    }
}
