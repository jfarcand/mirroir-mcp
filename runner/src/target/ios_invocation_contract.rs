// ABOUTME: Pins the command line mirroir-run hands to `mirroir-mcp test` to one checked-in file.
// ABOUTME: The Swift tests check their parser against the same file, so a flag renamed on either side fails that side's suite.

use std::collections::BTreeMap;
use std::error::Error as StdError;
use std::ffi::OsString;
use std::iter;
use std::path::{Path, PathBuf};
use std::result::Result as StdResult;

use serde::Deserialize;

use super::ios::{
    BLOCK_FILE, CompiledRecording, MIRROIR_SKILLS_ENV, REPORT_FILE, TEST_SUBCOMMAND, test_arguments,
};
use crate::replay_cross_surface::IOS_CAPTURE_KEY;

type TestResult = StdResult<(), Box<dyn StdError>>;

/// The contract both languages read.
const CONTRACT: &str = include_str!("fixtures/mirroir-mcp-test-invocation.json");

/// Invocation built for a block that only runs.
const BLOCK: &str = "block";

/// Invocation built for a block whose passing run is recorded.
const RECORDING_BLOCK: &str = "recording_block";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InvocationContract {
    /// The word after `mirroir-mcp`.
    subcommand: String,
    /// The environment variables the runner sets for the child.
    environment: Vec<String>,
    /// Each command line the runner builds, without the subcommand.
    invocations: BTreeMap<String, Vec<String>>,
}

impl InvocationContract {
    fn load() -> StdResult<Self, serde_json::Error> {
        serde_json::from_str(CONTRACT)
    }

    /// The full argument vector the contract expects for `name`.
    fn expected(&self, name: &str) -> StdResult<Vec<OsString>, String> {
        let rest = self
            .invocations
            .get(name)
            .ok_or_else(|| format!("the contract has no `{name}` invocation"))?;
        Ok(iter::once(&self.subcommand)
            .chain(rest)
            .map(OsString::from)
            .collect())
    }
}

#[test]
fn the_block_invocation_matches_the_contract() -> TestResult {
    let contract = InvocationContract::load()?;
    let built = test_arguments(Path::new(REPORT_FILE), Path::new(BLOCK_FILE), None);
    assert_eq!(built, contract.expected(BLOCK)?);
    Ok(())
}

#[test]
fn the_recording_invocation_matches_the_contract() -> TestResult {
    let contract = InvocationContract::load()?;
    let recording = CompiledRecording {
        out: PathBuf::from("out.compiled.json"),
        source: PathBuf::from("flow.ios.yaml"),
    };
    let built = test_arguments(
        Path::new(REPORT_FILE),
        Path::new(BLOCK_FILE),
        Some(&recording),
    );
    assert_eq!(built, contract.expected(RECORDING_BLOCK)?);
    Ok(())
}

#[test]
fn the_subcommand_capture_key_and_environment_match_the_contract() -> TestResult {
    let contract = InvocationContract::load()?;
    assert_eq!(contract.subcommand, TEST_SUBCOMMAND);
    assert_eq!(contract.environment, [MIRROIR_SKILLS_ENV]);
    let block = contract.expected(BLOCK)?;
    let capture = block
        .iter()
        .position(|argument| argument == "--capture")
        .and_then(|flag| block.get(flag + 1))
        .ok_or("the block invocation carries no --capture value")?;
    assert_eq!(capture, IOS_CAPTURE_KEY);
    Ok(())
}

/// An entry the runner never builds would be checked by nothing on this side.
#[test]
fn every_contract_invocation_is_built_by_the_runner() -> TestResult {
    let contract = InvocationContract::load()?;
    let names: Vec<&str> = contract.invocations.keys().map(String::as_str).collect();
    assert_eq!(names, [BLOCK, RECORDING_BLOCK]);
    Ok(())
}
