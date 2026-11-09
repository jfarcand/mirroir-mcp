// ABOUTME: Installs the tracing subscriber and decides whether its output may carry ANSI colour.
// ABOUTME: Colour is for a person at a terminal: a pipe or NO_COLOR gets plain text a script can read.

use std::env;
use std::error::Error;
use std::ffi::OsStr;
use std::io::{self, IsTerminal};

use tracing_subscriber::{EnvFilter, fmt};

/// The `NO_COLOR` convention (<https://no-color.org>): set and not empty turns colour off.
const NO_COLOR: &str = "NO_COLOR";

/// Whether log output may be coloured: only for a terminal, and never when
/// `NO_COLOR` holds a non-empty value.
#[must_use]
pub fn color_enabled(is_terminal: bool, no_color: Option<&OsStr>) -> bool {
    is_terminal && no_color.is_none_or(OsStr::is_empty)
}

/// Install the global tracing subscriber. Its level comes from `RUST_LOG`
/// (`info` when unset), and its colour from [`color_enabled`] for stdout.
///
/// # Errors
///
/// Returns the subscriber's error when a global subscriber is already installed.
pub fn init_tracing() -> Result<(), Box<dyn Error + Send + Sync>> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let ansi = color_enabled(io::stdout().is_terminal(), env::var_os(NO_COLOR).as_deref());
    fmt::fmt()
        .with_env_filter(filter)
        .with_ansi(ansi)
        .try_init()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_terminal_without_no_color_is_coloured() {
        assert!(color_enabled(true, None));
    }

    #[test]
    fn color_needs_a_terminal() {
        assert!(!color_enabled(false, None));
    }

    #[test]
    fn no_color_disables_color() {
        assert!(!color_enabled(true, Some(OsStr::new("1"))));
    }

    #[test]
    fn an_empty_no_color_is_ignored() {
        assert!(color_enabled(true, Some(OsStr::new(""))));
    }
}
