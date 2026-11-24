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
// ABOUTME: Tests for the mirroir approval gate: what passes, what asks, what is refused, and how long "allow always" lasts.
// ABOUTME: Runs with `node --test` and no OpenClaw: the gate is a plain function of the hook's event and context.

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  createGate, describeCall, mirroirTool, DESCRIPTION_LIMIT, MAX_REMEMBERED_SESSIONS, OWNER_ONLY, TOO_LONG,
} from "./approval.js";

const owner = { sessionKey: "s1", requester: { senderIsOwner: true } };
const tap = { toolName: "mirroir__tap", params: { text: "Allow" } };

test("a tool of another server or plugin is not gated", () => {
  assert.equal(createGate()({ toolName: "exec", params: {} }, owner), undefined);
  assert.equal(createGate()({ toolName: "other__tap", params: {} }, owner), undefined);
  assert.equal(mirroirTool("mirroirtap"), null);
});

test("reading the screen passes without a prompt", () => {
  const gate = createGate();
  for (const tool of ["describe_screen", "screenshot", "listen", "get_notes"]) {
    assert.equal(gate({ toolName: `mirroir__${tool}`, params: {} }, owner), undefined, tool);
  }
});

test("a call that can change the phone asks the owner and shows the whole call", () => {
  const result = createGate()(tap, owner);
  assert.equal(result.requireApproval.title, "mirroir: tap");
  assert.equal(result.requireApproval.description, 'mirroir tap {"text":"Allow"}');
  assert.deepEqual(result.requireApproval.allowedDecisions, ["allow-once", "allow-always", "deny"]);
});

test("a sender OpenClaw knows is not the owner is refused before any prompt", () => {
  const result = createGate()(tap, { sessionKey: "s1", requester: { senderIsOwner: false } });
  assert.deepEqual(result, { block: true, blockReason: OWNER_ONLY });
});

test("a requester with no owner field still gets the prompt", () => {
  const result = createGate()(tap, { sessionKey: "s1" });
  assert.ok(result.requireApproval);
});

test("allow always lasts for that tool in that session only", () => {
  const gate = createGate();
  gate(tap, owner).requireApproval.onResolution("allow-always");
  assert.equal(gate({ toolName: "mirroir__tap", params: { text: "Next" } }, owner), undefined);
  assert.ok(gate({ toolName: "mirroir__type_text", params: { text: "hi" } }, owner).requireApproval);
  assert.ok(gate(tap, { ...owner, sessionKey: "s2" }).requireApproval);
});

test("allow once and deny remember nothing", () => {
  const gate = createGate();
  gate(tap, owner).requireApproval.onResolution("allow-once");
  gate(tap, owner).requireApproval.onResolution("deny");
  assert.ok(gate(tap, owner).requireApproval);
});

test("without a session there is nothing to remember, so allow always is not offered", () => {
  const result = createGate()(tap, { requester: { senderIsOwner: true } });
  assert.deepEqual(result.requireApproval.allowedDecisions, ["allow-once", "deny"]);
});

test("a call too long to show whole is refused, never cut", () => {
  const long = { toolName: "mirroir__type_text", params: { text: "x".repeat(DESCRIPTION_LIMIT) } };
  assert.deepEqual(createGate()(long, owner), { block: true, blockReason: TOO_LONG });
});

test("invisible and direction-changing characters are spelled out", () => {
  assert.equal(describeCall("type_text", { text: "a‮b​c" }), 'mirroir type_text {"text":"a\\u{202e}b\\u{200b}c"}');
});

test("the sessions remembered are bounded", () => {
  const gate = createGate();
  for (let index = 0; index <= MAX_REMEMBERED_SESSIONS; index += 1) {
    gate(tap, { ...owner, sessionKey: `s${index}` }).requireApproval.onResolution("allow-always");
  }
  assert.ok(gate(tap, { ...owner, sessionKey: "s0" }).requireApproval, "the oldest session is forgotten");
  assert.equal(gate(tap, { ...owner, sessionKey: `s${MAX_REMEMBERED_SESSIONS}` }), undefined);
});
