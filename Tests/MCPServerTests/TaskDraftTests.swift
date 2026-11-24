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
// ABOUTME: Tests for the task label of run_steps: passing runs of one task add up into one SKILL.md draft.
// ABOUTME: Covers the reply through the MCP server, the bounds on tasks and steps, and the draft's text.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class TaskDraftTests: XCTestCase {

    private var input: StubInput!
    private var describer: StubDescriber!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        input = StubInput()
        describer = StubDescriber()
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Search", tapX: 200, tapY: 840, confidence: 0.99)],
            screenshotBase64: "")
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        server = MCPServer(policy: policy, transport: .stdio)
        let registry = makeTestRegistry(bridge: StubBridge(), input: input, describer: describer)
        MirroirMCP.registerRunStepsTools(server: server, registry: registry, policy: policy)
    }

    private func runSteps(_ steps: [String], task: String?) -> (text: String, isError: Bool) {
        var args: [String: JSONValue] = ["steps": .array(steps.map { .string($0) })]
        if let task { args["task"] = .string(task) }
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string("run_steps"), "arguments": .object(args)]))
        guard let response = server.handleRequest(request),
              case .object(let result) = response.result,
              case .array(let content) = result["content"],
              case .object(let first) = content.first,
              case .string(let text) = first["text"] else { return ("", false) }
        if case .bool(let isError) = result["isError"] { return (text, isError) }
        return (text, false)
    }

    // MARK: - Through run_steps

    func testPassingRunsOfOneTaskAddUpInOneDraft() {
        _ = runSteps(["tap: Search", "type: coffee"], task: "order a coffee")
        let second = runSteps(["press_key: return"], task: "order a coffee")
        XCTAssertFalse(second.isError, second.text)
        XCTAssertTrue(second.text.contains("(2 run(s), 3 step(s))"), second.text)
        XCTAssertTrue(second.text.contains("name: \"order a coffee\""), second.text)
        XCTAssertTrue(second.text.contains("1. Tap \"Search\"\n2. Type \"coffee\"\n3. Press **Return**"),
                      second.text)
    }

    func testAFailedRunIsNotAddedToTheDraft() {
        _ = runSteps(["tap: Search"], task: "search")
        let failed = runSteps(["tap: Nowhere"], task: "search")
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.text.contains("This run was not added to the task \"search\""), failed.text)
        let next = runSteps(["type: tea"], task: "search")
        XCTAssertTrue(next.text.contains("(2 run(s), 2 step(s))"), next.text)
        XCTAssertFalse(next.text.contains("Nowhere"), next.text)
    }

    func testARunWithoutATaskAddsNothing() {
        let reply = runSteps(["tap: Search"], task: nil)
        XCTAssertFalse(reply.text.contains("SKILL.md draft"), reply.text)
    }

    func testABadTaskLabelIsRefusedBeforeAnythingRuns() {
        for task in ["", "line one\nline two", "say \"hi\"",
                     String(repeating: "a", count: TaskDraft.maxTaskLength + 1)] {
            let reply = runSteps(["tap: Search"], task: task)
            XCTAssertTrue(reply.isError, "task \(task.debugDescription) must be refused")
            XCTAssertTrue(reply.text.hasSuffix("Nothing was run."), reply.text)
        }
        XCTAssertTrue(input.tapCalls.isEmpty)
    }

    // MARK: - Bounds

    func testATaskHoldsABoundedNumberOfSteps() {
        let drafts = TaskDraft()
        let full = Array(repeating: SkillStep.home, count: TaskDraft.maxStepsPerTask)
        guard case .added = drafts.record(task: "t", steps: full) else { return XCTFail("first run must fit") }
        guard case .full(let steps, let runs) = drafts.record(task: "t", steps: [.shake]) else {
            return XCTFail("a run past the bound must not be added")
        }
        XCTAssertEqual(steps.count, TaskDraft.maxStepsPerTask)
        XCTAssertEqual(runs, 1)
    }

    func testTheLeastRecentlyUsedTaskIsDroppedPastTheBound() {
        let drafts = TaskDraft()
        for index in 0 ... TaskDraft.maxTasks {
            _ = drafts.record(task: "task \(index)", steps: [.home])
        }
        XCTAssertTrue(drafts.steps(of: "task 0").isEmpty, "the oldest task is dropped")
        XCTAssertEqual(drafts.steps(of: "task \(TaskDraft.maxTasks)").count, 1)
    }

    // MARK: - The draft

    func testTheDraftNamesTheAppsItLaunchesAndWritesControlFlowAsSentences() {
        let steps: [SkillStep] = [
            .launch(appName: "Starbucks"),
            .condition(check: ScreenCheck(label: "Allow", visible: true), then: .tap(label: "Allow")),
            .repeatUntil(check: ScreenCheck(label: "Loading", visible: false), maxIterations: 3,
                         body: .waitFor(label: "Menu", timeoutSeconds: nil)),
        ]
        let draft = TaskDraft.markdown(task: "order a coffee", steps: steps)
        XCTAssertTrue(draft.hasPrefix("---\nversion: 1\nname: \"order a coffee\"\napp: Starbucks\n---\n"), draft)
        XCTAssertTrue(draft.contains("2. If \"Allow\" is visible: Tap \"Allow\""), draft)
        XCTAssertTrue(draft.contains("3. Repeat until \"Loading\" is not visible (max 3): Wait for \"Menu\" to appear"),
                      draft)
        XCTAssertEqual(SkillMdParser.parseHeader(content: draft, fallbackName: "draft").name, "order a coffee")
    }
}
