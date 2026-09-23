// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for TargetSelector — the shared-grammar `target:` map, its refusals, and registry resolution.
// ABOUTME: Also pins InvalidStepGate, which refuses a run holding a step the parser could not read.

import XCTest
@testable import mirroir_mcp

final class TargetSelectorTests: XCTestCase {

    // MARK: - Parse

    func testIosMapWithApp() {
        XCTAssertEqual(try TargetSelector.parse("{ kind: ios, app: \"Clock\" }").get(),
                       .ios(app: "Clock"))
    }

    func testIosMapWithoutApp() {
        XCTAssertEqual(try TargetSelector.parse("{kind: ios}").get(), .ios(app: nil))
    }

    func testMacosMapNeedsName() {
        XCTAssertEqual(try TargetSelector.parse("{ kind: macos, name: \"Xcode\" }").get(),
                       .macos(name: "Xcode"))
        XCTAssertEqual(parseError("{ kind: macos }"), .macosWithoutName)
    }

    /// A quoted value may hold a comma; it must not split the entry.
    func testQuotedCommaStaysInsideTheValue() {
        XCTAssertEqual(try TargetSelector.parse("{ kind: ios, app: \"Clock, World\" }").get(),
                       .ios(app: "Clock, World"))
    }

    func testBareNameIsRefused() {
        XCTAssertEqual(parseError("\"android\""), .notAMap(raw: "\"android\""))
    }

    func testMissingKindIsRefused() {
        XCTAssertEqual(parseError("{ app: \"Clock\" }"), .missingKind)
    }

    func testMalformedEntryIsRefused() {
        XCTAssertEqual(parseError("{ kind: ios, Clock }"), .malformedEntry(entry: "Clock"))
    }

    /// Surfaces mirroir-run drives are refused by name here.
    func testWebKindIsNotDrivenByMirroirMcp() {
        XCTAssertEqual(parseError("{ kind: web, url: \"http://x\" }"),
                       .kindNotDrivenHere(kind: "web"))
    }

    // MARK: - Resolve

    func testIosResolvesToTheIPhoneTargetWhateverItsName() throws {
        let registry = makeRegistry(["phone": "iphone-mirroring", "xcode": "macos-app"],
                                    defaultName: "xcode")
        XCTAssertEqual(try TargetSelector.ios(app: "Clock").resolve(in: registry).get().name,
                       "phone")
    }

    func testIosWithNoIPhoneConfiguredFails() {
        let registry = makeRegistry(["xcode": "macos-app"], defaultName: "xcode")
        XCTAssertEqual(resolveError(.ios(app: nil), registry),
                       .noIPhoneTarget(configured: ["xcode"]))
    }

    func testMacosResolvesByName() throws {
        let registry = makeRegistry(["phone": "iphone-mirroring", "xcode": "macos-app"],
                                    defaultName: "phone")
        XCTAssertEqual(try TargetSelector.macos(name: "xcode").resolve(in: registry).get().name,
                       "xcode")
    }

    func testMacosNamingTheIPhoneIsRefused() {
        let registry = makeRegistry(["phone": "iphone-mirroring"], defaultName: "phone")
        XCTAssertEqual(resolveError(.macos(name: "phone"), registry),
                       .nameIsTheIPhone(name: "phone"))
    }

    func testMacosUnknownNameFails() {
        let registry = makeRegistry(["phone": "iphone-mirroring"], defaultName: "phone")
        XCTAssertEqual(resolveError(.macos(name: "nope"), registry),
                       .unknownTarget(name: "nope", configured: ["phone"]))
    }

    // MARK: - InvalidStepGate

    func testGateFindsEveryInvalidStepInOrder() {
        let skill = SkillParser.parse(content: """
            name: gate
            steps:
              - launch: "Clock"
              - double_tap: "A"
              - target: "android"
            """, filePath: "gate.yaml")
        let findings = InvalidStepGate.scan(skills: [skill])
        XCTAssertEqual(findings.map(\.stepIndex), [1, 2])
        XCTAssertEqual(findings.map(\.stepType), ["double_tap", "target"])
        XCTAssertEqual(InvalidStepGate.refuse(skills: [skill]), 1)
    }

    func testGateLetsAReadableSkillThrough() {
        let skill = SkillParser.parse(content: """
            name: fine
            steps:
              - target: { kind: ios, app: "Clock" }
              - launch: "Clock"
              - remember: "an AI-only note stays skipped, not invalid"
            """, filePath: "fine.yaml")
        XCTAssertNil(InvalidStepGate.refuse(skills: [skill]))
    }

    // MARK: - Helpers

    private func parseError(_ raw: String) -> TargetSelectorError? {
        if case .failure(let error) = TargetSelector.parse(raw) { return error }
        return nil
    }

    private func resolveError(_ selector: TargetSelector,
                              _ registry: TargetRegistry) -> TargetSelectorError? {
        if case .failure(let error) = selector.resolve(in: registry) { return error }
        return nil
    }

    private func makeRegistry(_ types: [String: String], defaultName: String) -> TargetRegistry {
        var targets: [String: TargetContext] = [:]
        for (name, type) in types {
            let bridge = StubBridge()
            targets[name] = TargetContext(
                name: name, targetType: type, bundleID: nil,
                bridge: bridge, input: StubInput(),
                capture: StubCapture(), describer: StubDescriber(), recorder: StubRecorder(),
                capabilities: [])
        }
        return TargetRegistry(targets: targets, defaultName: defaultName)
    }
}
