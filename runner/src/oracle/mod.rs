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
// ABOUTME: Oracle module — drift detection, thresholds, baselines, LLM judge scoring, profile registry.
// ABOUTME: Owns the DRIFT verdict: every assertion green, and the semantics moved past a declared threshold.

pub mod baseline;
pub mod drift;
pub mod drift_log;
pub mod drift_session;
pub mod error;
pub mod judge;
pub mod judge_profiles;
pub mod llm_client;
pub mod screen_drift;
pub mod thresholds;
