// ABOUTME: Execution targets — generic process (tokio), HTTP (reqwest), and the mirroir-mcp iOS block driver.
// ABOUTME: Browser steps compile to Playwright `.spec.ts` instead of living in a target module here.

/// Test-only support: a loopback port the OS confirmed is dark.
#[cfg(test)]
pub mod dark_port;
pub mod http;
pub mod ios;
pub mod process;
pub mod process_log;
pub mod process_port;
