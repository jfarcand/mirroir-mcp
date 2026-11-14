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
// ABOUTME: `mirroir-run import maestro` — converts Maestro flow YAML into mirroir-run iOS scenarios.
// ABOUTME: Faithful commands map to steps the runner's parser reads back; the rest fail the import or are skipped loudly.

pub mod cli;
pub mod emit;
pub mod error;
pub mod flow;
pub mod header;
pub mod import;
pub mod import_args;
pub mod interpolate;
pub mod map;
pub mod map_gestures;
pub mod refused;
pub mod selector;
