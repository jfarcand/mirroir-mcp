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
// ABOUTME: Module index for the `.mirroir/` discovery, resolution, compose, and run pipeline.
// ABOUTME: Wraps the parser layer with filesystem semantics (locating, resolving, composing, replaying).

pub mod compose;
pub mod compose_cache;
pub mod compose_synth;
pub mod discover;
pub mod error;
pub mod git;
pub mod lock;
pub mod lock_checksum;
pub mod lock_freshness;
pub mod lock_generate;
pub mod pack_install;
pub mod resolve;
pub mod resolve_version;
pub mod run;
pub mod run_io;
pub mod run_selection;
