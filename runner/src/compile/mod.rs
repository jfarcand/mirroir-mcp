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
// ABOUTME: Compilation targets — Playwright for a web block, the mirroir-mcp skill dialect for an iOS block.
// ABOUTME: Both engines report in the Playwright JSON-reporter shape, ingested by `report`.

pub mod captures;
pub mod emit;
pub mod error;
pub mod invoke;
pub mod mirroir_block;
pub mod playwright;
pub mod playwright_config;
pub mod playwright_emit;
pub mod playwright_keys;
pub mod playwright_measure;
pub mod playwright_prelude;
pub mod report;
pub mod report_error;
pub mod workspace;
