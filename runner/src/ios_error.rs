// ABOUTME: Structured errors for an `ios` block — writing it in mirroir-mcp's dialect and invoking mirroir-mcp.
// ABOUTME: Converts into RunnerError via #[from]; every variant carries the fields its message needs.

use std::io;
use std::num::ParseIntError;
use std::path::PathBuf;
use std::time::Duration;

use thiserror::Error;

/// Errors raised while handing an `ios` block to `mirroir-mcp test`.
#[derive(Debug, Error)]
pub enum IosError {
    /// A step in the block uses something mirroir-mcp's skill dialect cannot
    /// express. Dropping it would run a different test than the file reads,
    /// so the block is refused, naming the step and what cannot cross.
    #[error("ios block step {index} (`{kind}`) cannot run in mirroir-mcp: {reason}")]
    NotExpressible {
        /// Index of the step, as the scenario file reads.
        index: usize,
        /// Step kind at `index`.
        kind: &'static str,
        /// What the dialect lacks.
        reason: String,
    },

    /// An AI-only step sits inside an `ios` block. `mirroir-mcp test` cannot
    /// evaluate a step only a model reads, so it reports it not evaluated and
    /// the block fails however its device steps went. The plan refuses the
    /// shape before anything runs instead; the step belongs after the block's
    /// last device step, where the runner records it.
    #[error(
        "ios block step {index} (`{kind}`) is an AI-only step mirroir-mcp cannot evaluate; the block opened at step {block_start} would fail on it. Move it after the block's last device step"
    )]
    AiOnlyStepInBlock {
        /// Index of the step, as the scenario file reads.
        index: usize,
        /// Step kind at `index`.
        kind: &'static str,
        /// Index of the `target:` that opened the block.
        block_start: usize,
    },

    /// No `mirroir-mcp` binary to run the block with.
    #[error(
        "mirroir-mcp is not installed: set MIRROIR_MCP_BIN or put `mirroir-mcp` on PATH (brew install jfarcand/tap/mirroir-mcp)"
    )]
    NotInstalled,

    /// Writing the block file or reading the report failed.
    #[error("ios block workspace: {context}")]
    Workspace {
        /// What was being done.
        context: String,
        /// Underlying I/O error.
        #[source]
        source: io::Error,
    },

    /// `mirroir-mcp test` exited without writing the report the verdict is
    /// read from — refused its input, or could not reach the device.
    #[error(
        "mirroir-mcp test exited (status: {status:?}) without writing {report}\nstderr tail:\n{stderr_tail}"
    )]
    NoReport {
        /// Exit status, `None` if killed by signal.
        status: Option<i32>,
        /// The report path it was asked to write.
        report: PathBuf,
        /// Stderr captured from the subprocess (truncated).
        stderr_tail: String,
    },

    /// `mirroir-mcp test` outlived the budget its block's steps earn. Its
    /// whole process group was killed, so nothing it spawned keeps running,
    /// and the block is a failure — never a pass, never a hang.
    #[error(
        "mirroir-mcp test ran {elapsed:.1?} against a {budget:?} budget for {steps} step(s) and was killed\nstderr tail:\n{stderr_tail}"
    )]
    BlockTimeout {
        /// How long the child ran before it was killed.
        elapsed: Duration,
        /// The budget it was given.
        budget: Duration,
        /// Steps in the block the budget was derived from.
        steps: usize,
        /// Stderr captured from the subprocess before the kill (truncated).
        stderr_tail: String,
    },

    /// The per-step allowance override is not a whole number of seconds.
    #[error("{variable}={value:?} is not a whole number of seconds")]
    InvalidStepAllowance {
        /// The environment variable that carried it.
        variable: &'static str,
        /// The value it carried.
        value: String,
        /// Why it did not parse.
        #[source]
        source: ParseIntError,
    },
}
