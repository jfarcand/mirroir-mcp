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
// ABOUTME: OpenClaw entry point of the mirroir plugin: registers the approval gate in front of mirroir's MCP tools.
// ABOUTME: The MCP server and the operating manual come from openclaw.plugin.json; this file only adds the gate.

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { createGate } from "./approval.js";

export default definePluginEntry({
  id: "mirroir",
  name: "mirroir",
  description: "Drive a real iPhone through macOS iPhone Mirroring, with an owner approval before every call that can change it.",
  register(api) {
    api.on("before_tool_call", createGate(), { priority: 50 });
  },
});
