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
// ABOUTME: Tests that the long tools stop at their next check once their call is cancelled, and report progress while they run.
// ABOUTME: Covers run_steps, scroll_to's seek and explore, over stub hardware.

import XCTest
import HelperLib
import os
@testable import mirroir_mcp

/// An explorer that counts its steps and never finishes on its own.
private final class CountingExplorer: Exploring, @unchecked Sendable {
    let graph: any NavigationGraphing = NavigationGraph()
    let steps = OSAllocatedUnfairLock(initialState: 0)
    var completed: Bool { steps.withLock { $0 } >= 3 }

    func step<S: ExplorationStrategy>(
        describer: ScreenDescribing, input: InputProviding, strategy: S.Type
    ) -> ExploreStepResult {
        let count = steps.withLock { $0 += 1; return $0 }
        return count >= 3 ? .finished(bundle: generateBundle()) : .continue(description: "step \(count)")
    }

    func markStarted() {}
    var stats: (nodeCount: Int, edgeCount: Int, actionCount: Int, elapsedSeconds: Int) {
        (1, 0, steps.withLock { $0 }, 0)
    }
    func generateBundle() -> SkillBundle { SkillBundle(appName: "Counting", skills: [], manifest: nil) }
    func generateReport() -> String { "report" }
}

final class ToolCallCancellationTests: XCTestCase {

    /// Collects the progress values a call emits.
    private final class ProgressSink: @unchecked Sendable {
        let values = OSAllocatedUnfairLock(initialState: [Double]())
        lazy var emit: MCPCallControl.Emit = { [values] params in
            if case .number(let value)? = params.member("progress") { values.withLock { $0.append(value) } }
        }
    }

    private func cancelled() -> MCPCallControl {
        let call = MCPCallControl()
        call.cancel(reason: "test")
        return call
    }

    // MARK: - run_steps

    private func runSteps(_ raw: [String], input: StubInput, call: MCPCallControl) -> (text: String, isError: Bool) {
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        let server = MCPServer(policy: policy, transport: .stdio)
        let describer = StubDescriber()
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Search", tapX: 200, tapY: 840, confidence: 0.99)], screenshotBase64: "")
        let registry = makeTestRegistry(bridge: StubBridge(), input: input, describer: describer)
        MirroirMCP.registerRunStepsTools(server: server, registry: registry, policy: policy)
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string("run_steps"),
                             "arguments": .object(["steps": .array(raw.map { .string($0) })])]))
        guard case .object(let result)? = server.handleRequest(request, call: call)?.result,
              case .array(let content)? = result["content"],
              let text = content.first?.member("text")?.asString() else { return ("", false) }
        return (text, result["isError"] == .bool(true))
    }

    func testCancelledRunStepsSendsNoInput() {
        let input = StubInput()
        let result = runSteps(["tap: Search", "type: calculator"], input: input, call: cancelled())
        XCTAssertTrue(input.tapCalls.isEmpty, "a cancelled run touches nothing")
        XCTAssertTrue(input.typeCalls.isEmpty)
        XCTAssertTrue(result.text.contains(StepExecutor.cancelledMessage), result.text)
    }

    func testRunStepsReportsProgressPerStep() {
        let sink = ProgressSink()
        let call = MCPCallControl(progressToken: .string("p"), emit: sink.emit)
        let input = StubInput()
        let result = runSteps(["tap: Search", "type: calculator"], input: input, call: call)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(sink.values.withLock { $0 }, [1, 2])
    }

    // MARK: - scroll_to

    func testCancelledSeekStopsBeforeAnySwipe() {
        let bridge = StubBridge()
        let input = StubInput()
        let describer = StubDescriber()
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Other", tapX: 100, tapY: 400, confidence: 0.95)], screenshotBase64: "")
        let outcome = ScrollSeeker.seek(
            label: "Target", toward: .down, maxScrolls: 5, anchor: nil, band: 0.1 ... 0.9,
            bridge: bridge, input: input, describer: describer, settleUs: 1, call: cancelled())
        XCTAssertEqual(outcome, .stopped(.cancelled, scrolls: 0))
        XCTAssertTrue(input.swipeCalls.isEmpty)
        XCTAssertTrue(outcome.toolReply(label: "Target").isError)
    }

    // MARK: - explore

    func testCancelledExplorePausesAndTakesNoStep() throws {
        let explorer = CountingExplorer()
        let appName = "mirroir-cancelled-\(UUID().uuidString)"
        defer { GraphPersistence.delete(bundleID: appName) }
        let ctx = try XCTUnwrap(makeTestRegistry(bridge: StubBridge(), input: StubInput()).resolve())
        let result = ExplorationLoopRunner.run(
            explorer: explorer, strategyChoice: .mobile, ctx: ctx, appName: appName,
            emit: false, outputDir: nil, call: cancelled(), initialLines: [])
        XCTAssertEqual(explorer.steps.withLock { $0 }, 0)
        let text = result.content.compactMap { content -> String? in
            if case .text(let text) = content { return text }
            return nil
        }.joined()
        XCTAssertTrue(text.contains("Paused: \(StepExecutor.cancelledMessage)"), text)
    }

    func testExploreReportsProgressPerAction() throws {
        let sink = ProgressSink()
        let call = MCPCallControl(progressToken: .number(4), emit: sink.emit)
        let appName = "mirroir-progress-\(UUID().uuidString)"
        defer { GraphPersistence.delete(bundleID: appName) }
        let ctx = try XCTUnwrap(makeTestRegistry(bridge: StubBridge(), input: StubInput()).resolve())
        _ = ExplorationLoopRunner.run(
            explorer: CountingExplorer(), strategyChoice: .mobile, ctx: ctx, appName: appName,
            emit: false, outputDir: nil, call: call, initialLines: [])
        XCTAssertEqual(sink.values.withLock { $0 }, [1, 2])
    }
}
