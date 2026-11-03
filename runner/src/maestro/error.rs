// ABOUTME: Structured errors for `mirroir-run import maestro` — reading flows, unsupported commands, cycles, writes.
// ABOUTME: Converts into RunnerError via #[from]; an unsupported command is listed with its file, line and reason.

use std::fmt;
use std::io;
use std::path::PathBuf;

use thiserror::Error;

/// Where a Maestro command sits: its file, its 1-based line when the file's
/// layout let the importer find it, and its position among the commands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Location {
    /// The flow file the command was read from.
    pub file: PathBuf,
    /// 1-based line of the command's `- ` item, when it could be located.
    pub line: Option<usize>,
    /// The command's position, e.g. `command 3` or `command 3 › commands 2`.
    pub path: String,
}

impl fmt::Display for Location {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.line {
            Some(line) => write!(f, "{}:{line} ({})", self.file.display(), self.path),
            None => write!(f, "{} ({})", self.file.display(), self.path),
        }
    }
}

/// One Maestro command, selector or header key with no faithful mirroir
/// equivalent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnsupportedItem {
    /// Where it sits.
    pub location: Location,
    /// The Maestro command name (or header key) as the flow spells it.
    pub command: String,
    /// Why mirroir cannot run it as written.
    pub reason: String,
}

impl fmt::Display for UnsupportedItem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} `{}`: {}", self.location, self.command, self.reason)
    }
}

/// Errors raised while importing Maestro flows.
#[derive(Debug, Error)]
pub enum MaestroError {
    /// A flow file could not be read.
    #[error("read Maestro flow {}", path.display())]
    Read {
        /// The flow file.
        path: PathBuf,
        /// Underlying I/O failure.
        #[source]
        source: io::Error,
    },

    /// A flow file is not valid YAML.
    #[error("parse Maestro flow {}", path.display())]
    Parse {
        /// The flow file.
        path: PathBuf,
        /// Underlying YAML failure.
        #[source]
        source: serde_norway::Error,
    },

    /// A flow file is valid YAML but not shaped like a Maestro flow.
    #[error("{location}: not a Maestro flow: {reason}")]
    Shape {
        /// Where the shape breaks.
        location: Location,
        /// What was expected.
        reason: String,
    },

    /// One or more commands have no faithful mirroir equivalent. Nothing was
    /// written: dropping them would import a different test than the flow reads.
    #[error(
        "{} Maestro item(s) have no mirroir equivalent; nothing was written (pass --skip-unsupported to import without them, each recorded as a comment):\n{}",
        items.len(),
        render_items(items)
    )]
    Unsupported {
        /// Every unsupported item, in flow order.
        items: Vec<UnsupportedItem>,
    },

    /// `runFlow` files include each other in a loop.
    #[error("runFlow cycle: {}", render_chain(chain))]
    FlowCycle {
        /// The include chain, ending with the file that re-enters it.
        chain: Vec<PathBuf>,
    },

    /// An `--app` argument is not `<appId>=<display name>`.
    #[error("--app `{value}` is not `<appId>=<display name>`")]
    AppMapping {
        /// The argument as given.
        value: String,
    },

    /// Two input flows would be written to the same scenario file.
    #[error("flows {} and {} both import to {}", first.display(), second.display(), output.display())]
    OutputCollision {
        /// The scenario file both would write.
        output: PathBuf,
        /// The first flow.
        first: PathBuf,
        /// The second flow.
        second: PathBuf,
    },

    /// The scenario written for a flow did not parse back into the steps it
    /// was built from — the importer refuses to write what the runner would
    /// read differently.
    #[error("the scenario imported from {} does not read back as written: {reason}", flow.display())]
    RoundTrip {
        /// The flow being imported.
        flow: PathBuf,
        /// What differed, or the parser's refusal.
        reason: String,
    },

    /// A scenario file could not be written.
    #[error("write scenario {}", path.display())]
    Write {
        /// The scenario file.
        path: PathBuf,
        /// Underlying I/O failure.
        #[source]
        source: io::Error,
    },
}

fn render_items(items: &[UnsupportedItem]) -> String {
    items
        .iter()
        .map(|item| format!("  {item}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn render_chain(chain: &[PathBuf]) -> String {
    chain
        .iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>()
        .join(" → ")
}
