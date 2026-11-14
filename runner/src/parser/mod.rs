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
// ABOUTME: YAML parser for the mirroir SkillStep grammar, scenarios, SAMPLE.md, and the .mirroir/ plan.
// ABOUTME: The step grammar is shared with Swift Sources/mirroir-mcp/SkillParser.swift, which runs ios blocks.

pub mod archetype;
pub mod compiled;
pub mod env;
pub mod local_overrides;
pub mod lockfile;
pub mod mirroir;
pub mod mirroir_plan;
pub mod pack_index;
pub mod sample;
pub mod scenario;
pub mod shorthand;
pub mod step;
pub mod step_args;
pub mod step_process_args;
pub mod step_scene_args;
pub mod step_web_args;
pub mod substitute;
pub mod surface;
pub mod version;
