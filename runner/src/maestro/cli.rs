// ABOUTME: `mirroir-run import maestro <flow.yaml>... [-o <dir>]` — converts Maestro flows into mirroir-run scenarios.
// ABOUTME: Imports every flow first and writes nothing while any command is unsupported, unless --skip-unsupported.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::result::Result as StdResult;

use clap::{Args, Subcommand};
use tracing::{info, warn};

use crate::error::Result;
use crate::maestro::emit::{SCENARIO_SUFFIX, render_scenario};
use crate::maestro::error::{MaestroError, UnsupportedItem};
use crate::maestro::import::{ImportedFlow, import_flow};
use crate::maestro::map::AppNames;
use crate::verdict::RunVerdict;

/// `mirroir-run import …` — convert another tool's tests into scenarios.
#[derive(Args, Debug)]
pub struct ImportArgs {
    /// The format to import.
    #[command(subcommand)]
    pub command: ImportCommand,
}

/// Formats `import` reads.
#[derive(Subcommand, Debug)]
pub enum ImportCommand {
    /// Convert Maestro flow files into mirroir-run iOS scenarios, one
    /// `<stem>.ios.yaml` per flow, with `runFlow` includes inlined.
    Maestro(MaestroImportArgs),
}

/// Arguments of `mirroir-run import maestro`.
#[derive(Args, Debug)]
pub struct MaestroImportArgs {
    /// Maestro flow files to import.
    #[arg(required = true, value_name = "FLOW")]
    pub flows: Vec<PathBuf>,

    /// Directory the scenarios are written to.
    #[arg(short = 'o', long = "out-dir", value_name = "DIR", default_value = ".")]
    pub out_dir: PathBuf,

    /// The home-screen name Spotlight finds for a bundle id, e.g.
    /// `--app com.apple.mobilenotes=Notes`. mirroir launches apps by name,
    /// so every `appId` a flow launches or stops needs one. Repeatable.
    #[arg(long = "app", value_name = "APP_ID=NAME")]
    pub apps: Vec<String>,

    /// Import without the commands that have no mirroir equivalent: each is
    /// printed as a warning and recorded as a comment where it stood.
    /// Without this flag the import fails, listing every one.
    #[arg(long)]
    pub skip_unsupported: bool,
}

/// Dispatch an `import` subcommand.
///
/// # Errors
///
/// Anything [`import_maestro`] returns.
pub fn run_import(args: &ImportArgs) -> Result<RunVerdict> {
    match &args.command {
        ImportCommand::Maestro(maestro) => {
            for written in import_maestro(maestro)? {
                println!("{}", written.display());
            }
            Ok(RunVerdict::Pass)
        }
    }
}

/// Import every flow in `args`, then write one scenario per flow.
///
/// Returns the written scenario paths, in argument order.
///
/// # Errors
///
/// * [`MaestroError::Unsupported`] listing every unsupported item across all
///   flows, before anything is written — unless `--skip-unsupported`.
/// * [`MaestroError::OutputCollision`] when two flows share a file stem.
/// * Any read, parse, cycle, round-trip or write failure.
pub fn import_maestro(args: &MaestroImportArgs) -> Result<Vec<PathBuf>> {
    let apps = AppNames::parse(&args.apps)?;
    let mut imported: Vec<(PathBuf, ImportedFlow)> = Vec::new();
    let mut claimed: HashMap<PathBuf, PathBuf> = HashMap::new();
    for flow in &args.flows {
        let flow_import = import_flow(flow, &apps)?;
        let output = output_path(&args.out_dir, flow, &flow_import.name);
        if let Some(first) = claimed.insert(output.clone(), flow.clone()) {
            return Err(MaestroError::OutputCollision {
                output,
                first,
                second: flow.clone(),
            }
            .into());
        }
        imported.push((output, flow_import));
    }
    let unsupported: Vec<UnsupportedItem> = imported
        .iter()
        .flat_map(|(_, flow)| flow.unsupported.iter().cloned())
        .collect();
    if !unsupported.is_empty() && !args.skip_unsupported {
        return Err(MaestroError::Unsupported { items: unsupported }.into());
    }
    for item in &unsupported {
        warn!(item = %item, "skipped a Maestro command with no mirroir equivalent");
    }
    let rendered = imported
        .iter()
        .map(|(output, flow)| Ok((output, render_scenario(flow)?)))
        .collect::<StdResult<Vec<_>, MaestroError>>()?;
    fs::create_dir_all(&args.out_dir).map_err(|source| MaestroError::Write {
        path: args.out_dir.clone(),
        source,
    })?;
    let mut written = Vec::new();
    for (output, text) in rendered {
        fs::write(output, text).map_err(|source| MaestroError::Write {
            path: output.clone(),
            source,
        })?;
        written.push(output.clone());
    }
    info!(
        flows = args.flows.len(),
        skipped = unsupported.len(),
        out_dir = %args.out_dir.display(),
        "imported Maestro flows"
    );
    Ok(written)
}

/// `<out_dir>/<flow stem>.ios.yaml` — the flow's name for a path that has
/// no file stem.
fn output_path(out_dir: &Path, flow: &Path, name: &str) -> PathBuf {
    let stem = flow.file_stem().map_or_else(
        || name.to_owned(),
        |stem| stem.to_string_lossy().into_owned(),
    );
    out_dir.join(format!("{stem}{SCENARIO_SUFFIX}"))
}
