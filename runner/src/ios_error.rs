// ABOUTME: Structured errors for an `ios` block — writing it in mirroir-mcp's dialect and invoking mirroir-mcp.
// ABOUTME: Converts into RunnerError via #[from]; every variant carries the fields its message needs.

use std::io;
use std::path::PathBuf;

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
}
