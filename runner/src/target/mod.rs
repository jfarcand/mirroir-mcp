/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Execution targets — generic process (tokio), HTTP (reqwest), and the mirroir-mcp iOS block driver.
// ABOUTME: Browser steps compile to Playwright `.spec.ts` instead of living in a target module here.

/// Test-only support: a loopback port the OS confirmed is dark.
#[cfg(test)]
pub mod dark_port;
pub mod file_url;
pub mod http;
pub mod ios;
pub mod ios_budget;
/// Test-only: the command line mirroir-run hands to mirroir-mcp.
#[cfg(test)]
mod ios_invocation_contract;
/// Test-only: the AI-only report seam with mirroir-mcp.
#[cfg(test)]
mod ios_report_contract;
pub mod process;
pub mod process_log;
pub mod process_port;
