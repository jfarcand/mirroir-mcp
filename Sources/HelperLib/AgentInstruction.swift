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
// ABOUTME: The sentences an error ends with when only the user can fix it, so an agent stops instead of looping.
// ABOUTME: Shared by the permission policy (HelperLib) and the session and connection errors (mirroir-mcp).

/// What an agent must do with an error only the user can clear.
public enum AgentInstruction {

    /// Ends every error whose fix needs the user's hands.
    public static let waitForUser =
        "Stop and tell the user what to do; retry once only after they say it is done, never in a loop."

    /// Ends every permission refusal: the permissions file is the user's to change.
    public static let userDecides =
        "Whether to allow it is the user's decision: ask them, and do not edit the permissions "
        + "file or retry until they have changed it."
}
