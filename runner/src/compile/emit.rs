// ABOUTME: `--emit playwright <path>` — compile a sample or a single scenario to disk without running it.
// ABOUTME: Writes the exact workspace a run executes, so the reviewed spec is the spec that runs.

use std::path::{Path, PathBuf};

use tracing::info;

use crate::compile::playwright::compile_scenario;
use crate::compile::playwright_prelude::ScenarioSource;
use crate::compile::workspace::{PlaywrightWorkspace, path_stem};
use crate::error::Result;
use crate::parser::sample::SampleManifest;
use crate::replay::{load_sample_manifest, load_scenario_with_extras};
use crate::replay_plan::ScenarioPlan;
use crate::scenario_set::{ScenarioSet, select_scenarios};

/// One scenario's emitted artifacts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmittedScenario {
    /// Scenario YAML the spec was compiled from.
    pub source: PathBuf,
    /// The compiled `.spec.ts`.
    pub spec: PathBuf,
    /// The `playwright.config.ts` written beside it.
    pub config: PathBuf,
}

/// Compile every scenario `target` selects and write each one's workspace to
/// disk.
///
/// `target` is either a sample directory — in which case `set` picks the
/// scenario list out of its `SAMPLE.md` — or a single scenario YAML file.
/// `cwd` roots the `target/playwright/` output tree.
///
/// Nothing is invoked: this is the compile half of a run, made inspectable.
/// The directories it writes are the ones `--sample` / `--run-scenario`
/// execute, so what a reviewer reads is what Playwright receives.
///
/// # Errors
///
/// * Anything [`load_sample_manifest`], [`select_scenarios`] or
///   [`load_scenario_with_extras`] returns.
/// * [`crate::error::RunnerError::NoWebTarget`] for a scenario with no web
///   block, and [`crate::error::RunnerError::NoExecutorForTargetKind`] for one
///   whose `target:` names a surface this binary cannot drive.
/// * [`crate::compile::error::PlaywrightError::Workspace`] when a directory
///   or file can't be written.
pub async fn emit_playwright(
    target: &Path,
    set: ScenarioSet,
    cwd: &Path,
) -> Result<Vec<EmittedScenario>> {
    let (sample_name, scenarios) = resolve_targets(target, set)?;
    let mut emitted = Vec::with_capacity(scenarios.len());
    for source in scenarios {
        emitted.push(emit_one(&source, sample_name.as_deref(), target, cwd).await?);
    }
    Ok(emitted)
}

/// Expand `target` into the scenario files to compile, plus the sample name
/// their output nests under.
fn resolve_targets(target: &Path, set: ScenarioSet) -> Result<(Option<String>, Vec<PathBuf>)> {
    if !target.is_dir() {
        return Ok((None, vec![target.to_path_buf()]));
    }
    let manifest: SampleManifest = load_sample_manifest(&target.join("SAMPLE.md"))?;
    let selected = select_scenarios(target, &manifest, set)?;
    let resolved = selected.iter().map(|rel| target.join(rel)).collect();
    Ok((Some(path_stem(target)), resolved))
}

/// Compile one scenario and write its workspace.
async fn emit_one(
    source: &Path,
    sample_name: Option<&str>,
    sample_dir: &Path,
    cwd: &Path,
) -> Result<EmittedScenario> {
    let extras: Vec<(&str, String)> = if sample_name.is_some() {
        vec![("MIRROIR_SAMPLE_DIR", sample_dir.display().to_string())]
    } else {
        Vec::new()
    };
    let scenario = load_scenario_with_extras(source, &extras)?;
    let plan = ScenarioPlan::build(&scenario.steps)?;
    let spec = compile_scenario(&scenario, &plan, &ScenarioSource::read(source)?)?;

    let workspace = PlaywrightWorkspace::for_scenario(cwd, sample_name, &path_stem(source));
    workspace.materialize(&spec.spec_ts, &spec.browsers).await?;
    let spec_path = workspace.spec_path();
    let config_path = workspace.config_path();

    info!(
        source = %source.display(),
        spec = %spec_path.display(),
        browsers = ?spec.browsers,
        "emitted playwright spec"
    );
    Ok(EmittedScenario {
        source: source.to_path_buf(),
        spec: spec_path,
        config: config_path,
    })
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use tempfile::TempDir;
    use tokio::fs::{read_dir, read_to_string, write};

    use super::{ScenarioSet, emit_playwright};

    type TestResult = StdResult<(), Box<dyn StdError>>;

    const SCENARIO: &str = r#"
version: 1
name: emit me
steps:
  - target: { kind: web, browsers: [chrome], url: "http://127.0.0.1:1/" }
  - tap: "go"
  - assert_visible: "done"
"#;

    #[tokio::test]
    async fn a_single_scenario_emits_a_spec_and_a_config_side_by_side() -> TestResult {
        let dir = TempDir::new()?;
        let source = dir.path().join("checkout.yaml");
        write(&source, SCENARIO).await?;

        let emitted = emit_playwright(&source, ScenarioSet::MustPass, dir.path()).await?;
        let [only] = emitted.as_slice() else {
            return Err(format!("expected one emitted scenario, got {}", emitted.len()).into());
        };
        let expected_spec = dir
            .path()
            .join("target/playwright/checkout/checkout.spec.ts");
        if only.spec != expected_spec {
            return Err(format!(
                "wrote {} not {}",
                only.spec.display(),
                expected_spec.display()
            )
            .into());
        }
        let spec_body = read_to_string(&only.spec).await?;
        if !spec_body.contains("await _by(page, \"go\").click(") {
            return Err(format!("spec lost its tap:\n{spec_body}").into());
        }
        let config_body = read_to_string(&only.config).await?;
        if !config_body.contains("retries: 0") {
            return Err(format!("config lost its retry policy:\n{config_body}").into());
        }
        Ok(())
    }

    #[tokio::test]
    async fn emitting_twice_overwrites_rather_than_accumulating() -> TestResult {
        let dir = TempDir::new()?;
        let source = dir.path().join("checkout.yaml");
        write(&source, SCENARIO).await?;
        emit_playwright(&source, ScenarioSet::MustPass, dir.path()).await?;
        let second = emit_playwright(&source, ScenarioSet::MustPass, dir.path()).await?;
        let mut entries = read_dir(dir.path().join("target/playwright/checkout")).await?;
        let mut emitted: Vec<String> = Vec::new();
        while let Some(entry) = entries.next_entry().await? {
            let name = entry.file_name().to_string_lossy().into_owned();
            // A provisioned MIRROIR_PLAYWRIGHT_HOME contributes a node_modules
            // symlink to every workspace. It is not an emitted artifact, and
            // counting it would make this test depend on whether the developer
            // running it has a browser installed.
            if name != "node_modules" {
                emitted.push(name);
            }
        }
        emitted.sort();
        if emitted != ["checkout.spec.ts", "playwright.config.ts"] {
            return Err(format!("expected spec + config, found {emitted:?}").into());
        }
        if second.len() != 1 {
            return Err(format!("expected one scenario, got {}", second.len()).into());
        }
        Ok(())
    }
}
