// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Unit tests for the component classifiers: heuristic, agent, and composite strategies.
// ABOUTME: Verifies HeuristicClassifier, CompositeClassifier, and detection mode configuration.

import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ComponentClassifiersTests: XCTestCase {

    // MARK: - Helpers

    private let screenHeight: Double = 890
    private let definitions = ComponentCatalog.definitions

    private func classifiedNav(
        _ text: String, x: Double = 200, y: Double = 400, hasChevron: Bool = false
    ) -> ClassifiedElement {
        ClassifiedElement(
            point: TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95),
            role: .navigation,
            hasChevronContext: hasChevron
        )
    }

    private func classifiedDeco(
        _ text: String, x: Double = 200, y: Double = 400
    ) -> ClassifiedElement {
        ClassifiedElement(
            point: TapPoint(text: text, tapX: x, tapY: y, confidence: 0.95),
            role: .decoration
        )
    }

    // MARK: - HeuristicClassifier

    func testHeuristicClassifierReturnsComponents() {
        let classifier = HeuristicClassifier()
        let classified = [
            classifiedNav("General", x: 100, y: 400, hasChevron: true),
            classifiedDeco(">", x: 370, y: 400),
        ]

        let components = classifier.classify(
            classified: classified,
            definitions: definitions,
            screenHeight: screenHeight
        )

        XCTAssertNotNil(components)
        XCTAssertFalse(components?.isEmpty ?? true,
            "HeuristicClassifier should return non-empty components")
    }

    func testHeuristicClassifierWithEmptyInput() {
        let classifier = HeuristicClassifier()
        let components = classifier.classify(
            classified: [],
            definitions: definitions,
            screenHeight: screenHeight
        )

        XCTAssertNotNil(components)
        XCTAssertTrue(components?.isEmpty ?? false,
            "Empty input should produce empty components")
    }

    // MARK: - CompositeClassifier

    func testCompositeUsesFirstScreenPrimary() {
        let primary = CountingClassifier()
        let fallback = CountingClassifier()
        let composite = CompositeClassifier(
            primary: primary,
            fallback: fallback,
            primaryOnlyForFirstScreen: true
        )

        let classified = [classifiedNav("Test", y: 400)]

        // First call should use primary
        _ = composite.classify(
            classified: classified, definitions: definitions, screenHeight: screenHeight
        )
        XCTAssertEqual(primary.callCount, 1, "First screen should use primary")
        XCTAssertEqual(fallback.callCount, 0, "First screen should not use fallback")

        // Second call should use fallback
        _ = composite.classify(
            classified: classified, definitions: definitions, screenHeight: screenHeight
        )
        XCTAssertEqual(primary.callCount, 1, "Second screen should not use primary")
        XCTAssertEqual(fallback.callCount, 1, "Second screen should use fallback")
    }

    func testCompositeEveryScreenMode() {
        let primary = CountingClassifier()
        let fallback = CountingClassifier()
        let composite = CompositeClassifier(
            primary: primary,
            fallback: fallback,
            primaryOnlyForFirstScreen: false
        )

        let classified = [classifiedNav("Test", y: 400)]

        // Both calls should use primary
        _ = composite.classify(
            classified: classified, definitions: definitions, screenHeight: screenHeight
        )
        _ = composite.classify(
            classified: classified, definitions: definitions, screenHeight: screenHeight
        )
        XCTAssertEqual(primary.callCount, 2, "Every screen should use primary")
        XCTAssertEqual(fallback.callCount, 0, "Fallback not needed when primary succeeds")
    }

    func testCompositeFallsBackWhenPrimaryReturnsNil() {
        let primary = NilClassifier()
        let fallback = CountingClassifier()
        let composite = CompositeClassifier(
            primary: primary,
            fallback: fallback,
            primaryOnlyForFirstScreen: false
        )

        let classified = [classifiedNav("Test", y: 400)]
        let result = composite.classify(
            classified: classified, definitions: definitions, screenHeight: screenHeight
        )

        XCTAssertNotNil(result, "Should fall back to fallback when primary returns nil")
        XCTAssertEqual(fallback.callCount, 1, "Fallback should be used")
    }

    // MARK: - ComponentDetectionMode

    func testDetectionModeFromValidStrings() {
        XCTAssertEqual(
            ComponentDetectionMode(rawValue: "heuristic"), .heuristic)
        XCTAssertEqual(
            ComponentDetectionMode(rawValue: "llm_first_screen"), .llmFirstScreen)
        XCTAssertEqual(
            ComponentDetectionMode(rawValue: "llm_every_screen"), .llmEveryScreen)
        XCTAssertEqual(
            ComponentDetectionMode(rawValue: "llm_fallback"), .llmFallback)
    }

    func testDetectionModeFromInvalidString() {
        XCTAssertNil(ComponentDetectionMode(rawValue: "invalid"))
    }

    // MARK: - Classifier construction

    /// A client that can sample is asked directly — nothing needs configuring
    /// on this machine for that path to work.
    func testSamplingPreferredWhenClientDeclaresIt() {
        let server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil), transport: .stdio)
        _ = server.handleRequest(JSONRPCRequest(
            id: .number(1), method: "initialize",
            params: .object(["capabilities": .object(["sampling": .object([:])])])
        ))
        XCTAssertTrue(server.clientSupportsSampling(), "precondition: client declared sampling")

        let classifier = ComponentDetectionMode.llmEveryScreen.buildClassifier(
            server: server, agentConfig: AIAgentRegistry.resolve(name: "embacle"))
        guard let composite = classifier as? CompositeClassifier else {
            return XCTFail("expected a composite classifier")
        }
        XCTAssertTrue(composite.primary is SamplingClassifier,
            "a sampling-capable client is asked before the locally configured agent")
    }

    /// A client that cannot sample still gets LLM classification, through the
    /// agent configured here.
    func testAgentUsedWhenClientCannotSample() {
        let server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil), transport: .stdio)
        _ = server.handleRequest(JSONRPCRequest(
            id: .number(1), method: "initialize",
            params: .object(["capabilities": .object(["roots": .object([:])])])
        ))
        XCTAssertFalse(server.clientSupportsSampling(), "precondition: no sampling declared")

        let classifier = ComponentDetectionMode.llmEveryScreen.buildClassifier(
            server: server, agentConfig: AIAgentRegistry.resolve(name: "embacle"))
        guard let composite = classifier as? CompositeClassifier else {
            return XCTFail("expected a composite classifier")
        }
        XCTAssertTrue(composite.primary is AgentClassifier,
            "without sampling the locally configured agent answers")
    }

    /// With no model reachable by either transport, every mode classifies
    /// heuristically rather than building a classifier that cannot work.
    func testNoModelReachableFallsBackToHeuristicForEveryMode() {
        for mode in [
            ComponentDetectionMode.heuristic, .llmFirstScreen, .llmEveryScreen, .llmFallback,
        ] {
            XCTAssertTrue(
                mode.buildClassifier(server: nil, agentConfig: nil) is HeuristicClassifier,
                "\(mode.rawValue) with no model must classify heuristically")
        }
    }

    func testHeuristicModeNeverConsultsAModel() {
        XCTAssertTrue(
            ComponentDetectionMode.heuristic.buildClassifier(
                server: nil, agentConfig: AIAgentRegistry.resolve(name: "embacle")
            ) is HeuristicClassifier,
            "the heuristic mode never consults a model")
    }

}

// MARK: - Test Doubles

/// Classifier that counts calls and returns heuristic results.
private final class CountingClassifier: ComponentClassifying, @unchecked Sendable {
    var callCount = 0

    func classify(
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition],
        screenHeight: Double
    ) -> [ScreenComponent]? {
        callCount += 1
        return ComponentDetector.detect(
            classified: classified, definitions: definitions, screenHeight: screenHeight
        )
    }
}

/// Classifier that always returns nil (simulates failed LLM classification).
private final class NilClassifier: ComponentClassifying, @unchecked Sendable {
    func classify(
        classified: [ClassifiedElement],
        definitions: [ComponentDefinition],
        screenHeight: Double
    ) -> [ScreenComponent]? {
        return nil
    }
}
