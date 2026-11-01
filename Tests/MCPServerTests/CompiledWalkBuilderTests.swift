// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the save_compiled walk builder: opening steps, the launched app, screens per step,
// ABOUTME: and how each recorded step type and value becomes the action the scenario formatter renders.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class CompiledWalkBuilderTests: XCTestCase {

    private func points(_ labels: [String]) -> [TapPoint] {
        labels.enumerated().map { index, text in
            TapPoint(text: text, tapX: 200, tapY: 120 + Double(index) * 60, confidence: 0.95)
        }
    }

    private func step(_ index: Int, _ type: String, _ label: String? = nil) -> CompiledStep {
        CompiledStep(index: index, type: type, label: label, hints: .passthrough())
    }

    /// Screens read after every step, each named by its index.
    private func screens(_ count: Int) -> [Int: [TapPoint]] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, points(["Screen \($0)"])) })
    }

    private func walkError(
        _ steps: [CompiledStep], _ after: [Int: [TapPoint]]
    ) -> CompiledWalkBuilder.WalkError? {
        do {
            _ = try CompiledWalkBuilder.flow(flowName: "f", steps: steps, elementsAfter: after)
            return nil
        } catch {
            return error as? CompiledWalkBuilder.WalkError
        }
    }

    // MARK: - Opening

    func testTheOpeningIsConsumedAndTheWalkStartsAfterIt() throws {
        let walk = try CompiledWalkBuilder.flow(flowName: "add-alarm", steps: [
            step(0, "target", "{ kind: ios, app: \"Clock\" }"),
            step(1, "reset_app", "Clock"),
            step(2, "launch", "Clock"),
            step(3, "tap", "Add Alarm"),
        ], elementsAfter: screens(4))

        XCTAssertEqual(walk.appName, "Clock")
        XCTAssertEqual(walk.flow.name, "add-alarm")
        XCTAssertEqual(walk.flow.screens.count, 2)
        XCTAssertEqual(walk.flow.screens[0].elements.map(\.text), ["Screen 2"])
        XCTAssertNil(walk.flow.screens[0].actionType)
        XCTAssertEqual(walk.flow.screens[1].elements.map(\.text), ["Screen 3"])
        XCTAssertEqual(walk.flow.screens[1].actionType, "tap")
        XCTAssertEqual(walk.flow.screens[1].arrivedVia, "Add Alarm")
    }

    func testAWalkWithoutAnOpeningLaunchIsRefused() {
        XCTAssertEqual(walkError([step(0, "tap", "Add Alarm")], screens(1)), .noLaunchPrologue)
        XCTAssertEqual(walkError([step(0, "reset_app", "Clock"), step(1, "tap", "Edit")], screens(2)),
                       .noLaunchPrologue)
    }

    func testAnOpeningStepDrivingAnotherAppIsRefused() {
        XCTAssertEqual(walkError([
            step(0, "reset_app", "Settings"), step(1, "launch", "Clock"), step(2, "tap", "Edit"),
        ], screens(3)), .foreignPrologueApp(step: 0, app: "Settings", launchedApp: "Clock"))
        XCTAssertEqual(walkError([
            step(0, "target", "{ kind: ios, app: \"Notes\" }"), step(1, "launch", "Clock"),
        ], screens(2)), .foreignPrologueApp(step: 0, app: "Notes", launchedApp: "Clock"))
    }

    func testALaterLaunchIsAStepTheFormatterRefusesNotPartOfTheOpening() throws {
        let walk = try CompiledWalkBuilder.flow(flowName: "f", steps: [
            step(0, "launch", "Clock"), step(1, "tap", "Edit"), step(2, "launch", "Notes"),
        ], elementsAfter: screens(3))
        XCTAssertEqual(walk.flow.screens.last?.actionType, "launch")
    }

    // MARK: - Screens

    func testAStepWhoseScreenWasNotReadIsRefused() {
        var after = screens(3)
        after[1] = nil
        XCTAssertEqual(walkError([
            step(0, "launch", "Clock"), step(1, "tap", "Edit"), step(2, "tap", "Done"),
        ], after), .screenNotRead(step: 1))

        XCTAssertEqual(walkError([step(0, "launch", "Clock"), step(1, "tap", "Edit")], [1: points(["x"])]),
                       .screenNotRead(step: 0), "the start screen is the one read after the opening")
    }

    // MARK: - Step values

    private func actions(_ walkSteps: [CompiledStep]) throws -> [(String?, String?)] {
        let steps = [step(0, "launch", "Clock")] + walkSteps
        let walk = try CompiledWalkBuilder.flow(
            flowName: "f", steps: steps, elementsAfter: screens(steps.count))
        return walk.flow.screens.dropFirst().map { ($0.actionType, $0.arrivedVia) }
    }

    func testHomeBecomesPressHome() throws {
        let mapped = try actions([step(1, "home")])
        XCTAssertEqual(mapped.first?.0, "press_home")
        XCTAssertNil(mapped.first?.1)
    }

    func testALongPressKeepsOnlyItsLabel() throws {
        let mapped = try actions([step(1, "long_press", "\"Gym\" duration: 1500")])
        XCTAssertEqual(mapped.first?.0, "long_press")
        XCTAssertEqual(mapped.first?.1, "Gym")
    }

    func testAKeyPressWritesItsModifiersInline() throws {
        let mapped = try actions([step(1, "press_key", "l+command")])
        XCTAssertEqual(mapped.first?.0, "press_key")
        XCTAssertEqual(mapped.first?.1, "l+command")
    }

    func testAWaitForWithoutATimeoutIsAnElementStep() throws {
        let mapped = try actions([step(1, "wait_for", "Add Alarm")])
        XCTAssertEqual(mapped.first?.0, "wait_for")
        XCTAssertEqual(mapped.first?.1, "Add Alarm")
    }

    func testAWaitForWithATimeoutIsRefused() {
        let refusal = walkError([step(0, "launch", "Clock"), step(1, "wait_for", "\"Add Alarm\" timeout: 10")],
                                screens(2))
        guard case .unsupportedValue(let index, let type, _) = refusal else {
            return XCTFail("expected unsupportedValue, got \(String(describing: refusal))")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(type, "wait_for")
    }

    func testAnAIOnlyStepKeepsItsTypeForTheFormatterToRefuse() throws {
        let mapped = try actions([step(1, "remember", "the order number")])
        XCTAssertEqual(mapped.first?.0, "remember")
    }

    // MARK: - Emitted scenario

    func testTheBuiltWalkRendersTheScenarioTheSkillDescribes() throws {
        let walk = try CompiledWalkBuilder.flow(flowName: "add-alarm", steps: [
            step(0, "launch", "Clock"), step(1, "tap", "add alarm"), step(2, "wait_for", "Repeat"),
        ], elementsAfter: [
            0: points(["Alarms", "Edit", "Add Alarm"]),
            1: points(["Cancel", "Save", "Repeat"]),
            2: points(["Cancel", "Save", "Repeat"]),
        ])
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: walk.flow.name, appName: walk.appName, screens: walk.flow.screens)
        XCTAssertEqual(yaml, ScenarioStepFormatter.generatedHeader + "\n" + """
            version: 1
            name: "add-alarm"
            steps:
              - target: { kind: ios, app: "Clock" }
              - reset_app: "Clock"
              - launch: "Clock"
              - tap: "Add Alarm"
              - wait_for: "Cancel"
              - wait_for: "Repeat"
              - assert_visible: "Cancel"

            """)
    }
}
