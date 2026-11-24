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
// ABOUTME: The approval gate in front of mirroir's MCP tools in OpenClaw: every call that can change the iPhone asks the owner.
// ABOUTME: Reading the screen passes; a sender OpenClaw knows is not the owner is refused; "allow always" lasts one session.

import readOnlyTools from "./read-only-tools.json" with { type: "json" };

/** The MCP server name the manifest declares; OpenClaw names its tools `mirroir__<tool>`. */
export const SERVER = "mirroir";
const PREFIX = `${SERVER}__`;

/** OpenClaw's caps on a plugin approval's title and description. */
export const TITLE_LIMIT = 80;
export const DESCRIPTION_LIMIT = 512;

/** How long a prompt waits for the owner; past it the call is not sent. */
export const APPROVAL_TIMEOUT_MS = 300_000;

/** Sessions whose "allow always" answers are kept; the oldest is forgotten past it. */
export const MAX_REMEMBERED_SESSIONS = 100;

export const OWNER_ONLY = "Only the owner of this OpenClaw can drive the iPhone. Nothing was sent.";
export const TOO_LONG =
  "This mirroir call is too long to show whole in an approval prompt, so it was not sent. "
  + "Split it into shorter calls.";

const READ_ONLY = new Set(readOnlyTools);

/** The mirroir tool `toolName` calls, or null when it is not a mirroir tool. */
export function mirroirTool(toolName) {
  return typeof toolName === "string" && toolName.startsWith(PREFIX) ? toolName.slice(PREFIX.length) : null;
}

/** Whether `tool` only reads: it changes nothing on the phone. */
export function readsOnly(tool) {
  return READ_ONLY.has(tool);
}

/**
 * The call as the approver reads it: the tool and its arguments as JSON, with
 * invisible and direction-changing characters spelled out, so nothing that is
 * sent is hidden from the prompt.
 */
export function describeCall(tool, params) {
  const args = JSON.stringify(params ?? {});
  const shown = args.replace(/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/gu,
    (char) => `\\u{${char.codePointAt(0).toString(16)}}`);
  return `mirroir ${tool} ${shown}`;
}

/**
 * The `before_tool_call` handler. Returns nothing for a call it does not gate,
 * a block for a call it refuses, and an approval request otherwise.
 */
export function createGate() {
  /** sessionKey -> tools the owner allowed for the rest of that session, oldest session first. */
  const allowed = new Map();

  function remember(sessionKey, tool) {
    const tools = allowed.get(sessionKey) ?? new Set();
    allowed.delete(sessionKey);
    tools.add(tool);
    allowed.set(sessionKey, tools);
    while (allowed.size > MAX_REMEMBERED_SESSIONS) {
      allowed.delete(allowed.keys().next().value);
    }
  }

  return function gate(event, ctx) {
    const tool = mirroirTool(event?.toolName);
    if (tool === null || readsOnly(tool)) return undefined;
    // A requester OpenClaw knows is someone else must not drive the owner's phone,
    // even when the chat could answer its own approval.
    if (ctx?.requester?.senderIsOwner === false) {
      return { block: true, blockReason: OWNER_ONLY };
    }
    const sessionKey = ctx?.sessionKey ?? ctx?.sessionId;
    if (sessionKey && allowed.get(sessionKey)?.has(tool)) return undefined;
    const description = describeCall(tool, event?.params);
    if (description.length > DESCRIPTION_LIMIT) {
      return { block: true, blockReason: TOO_LONG };
    }
    return {
      requireApproval: {
        title: `mirroir: ${tool}`.slice(0, TITLE_LIMIT),
        description,
        severity: "warning",
        timeoutMs: APPROVAL_TIMEOUT_MS,
        allowedDecisions: sessionKey ? ["allow-once", "allow-always", "deny"] : ["allow-once", "deny"],
        onResolution: (decision) => {
          if (decision === "allow-always" && sessionKey) remember(sessionKey, tool);
        },
      },
    };
  };
}
