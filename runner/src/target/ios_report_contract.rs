// ABOUTME: Pins how mirroir-run reads a mirroir-mcp report whose skill held an AI-only step.
// ABOUTME: The fixture is byte-exact Swift writer output, checked on the Swift side by AIOnlyStepContractTests.

use std::result::Result as StdResult;

use crate::compile::report::parse_report_body;
use crate::compile::report_error::{ReportEngine, ReportError};
use crate::error::RunnerError;

/// The report `mirroir-mcp test --report-json` writes for a skill whose
/// device steps passed around a `verify:` it could not evaluate.
const NOT_EVALUATED_REPORT: &str = include_str!("fixtures/mirroir-mcp-report-not-evaluated.json");

/// A skill that holds a not-evaluated AI-only step is a failure of the block,
/// carrying mirroir-mcp's reason, never a pass on its other steps.
#[test]
fn a_not_evaluated_step_fails_the_block_with_its_reason() -> StdResult<(), String> {
    let res = parse_report_body(
        ReportEngine::MirroirMcp,
        "report.json",
        NOT_EVALUATED_REPORT,
    );
    let Err(RunnerError::Report(ReportError::TestFailures {
        failed,
        total,
        failures,
        ..
    })) = res
    else {
        return Err(format!("expected TestFailures, got {res:?}"));
    };
    if failed != 1 || total != 1 {
        return Err(format!("wrong counts: failed={failed} total={total}"));
    }
    let Some(first) = failures.first() else {
        return Err("no failure detail captured".to_owned());
    };
    if first.title != "check-alarms"
        || !first
            .message
            .contains("not evaluated: verify needs an AI client")
    {
        return Err(format!("wrong failure: {first:?}"));
    }
    Ok(())
}
