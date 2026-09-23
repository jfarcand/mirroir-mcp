// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the .mirroir/ iOS-leg emitter — scenario YAML shape, baseline, plan upsert, idempotency.
// ABOUTME: Shapes are asserted here only; the iOS walk declares a surface mirroir-run refuses by design.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class MirroirAppTreeEmitterTests: XCTestCase {

    private func tap(_ text: String) -> TapPoint {
        TapPoint(text: text, tapX: 100, tapY: 200, confidence: 0.95)
    }

    private func screen(
        index: Int, action: String?, via: String?, elements: [String]
    ) -> ExploredScreen {
        ExploredScreen(
            index: index,
            elements: elements.map(tap),
            hints: [],
            actionType: action,
            arrivedVia: via,
            screenshotBase64: ""
        )
    }

    private func sampleScreens() -> [ExploredScreen] {
        [
            screen(index: 0, action: nil, via: nil, elements: ["General", "Wi-Fi", "Bluetooth"]),
            screen(index: 1, action: "tap", via: "General", elements: ["About", "Software Update"]),
            screen(index: 2, action: "tap", via: "About", elements: ["Software Version 17.5.1", "Model Name"]),
        ]
    }

    private func tmpRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-emit-\(UUID().uuidString)/.mirroir")
    }

    func testEmitWritesScenarioBaselineAppMdAndPlan() throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let result = try MirroirAppTreeEmitter.emit(
            appName: "Settings", flow: "check software version", screens: sampleScreens(), root: root)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: result.scenarioPath.path))
        XCTAssertTrue(fm.fileExists(atPath: result.baselinePath.path))
        XCTAssertTrue(fm.fileExists(atPath: result.appDir.appendingPathComponent("APP.md").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("mirroir.yaml").path))

        // The parity gate belongs to the web leg's own scenario, whose `capture:`
        // scrapes the live page. A gate emitted here would name a `.web.txt` with
        // no web block to produce it, so the emitter writes no scenario but the
        // captured walk.
        let scenarios = try fm.contentsOfDirectory(
            atPath: result.scenarioPath.deletingLastPathComponent().path)
        XCTAssertEqual(scenarios, ["check-software-version.ios.yaml"])

        // Scenario carries the iOS target, launch, the taps, and is well-formed.
        let scenario = try String(contentsOf: result.scenarioPath, encoding: .utf8)
        XCTAssertTrue(scenario.hasPrefix("version: 1\nname: \"check-software-version\"\n"))
        XCTAssertTrue(scenario.contains("- target: { kind: ios, app: \"Settings\" }"))
        XCTAssertTrue(scenario.contains("- launch: \"Settings\""))
        XCTAssertTrue(scenario.contains("- tap: \"General\""))
        XCTAssertTrue(scenario.contains("- tap: \"About\""))
        // Destination landmark = the longest label on the final screen.
        XCTAssertTrue(scenario.contains("- assert_visible: \"Software Version 17.5.1\""))

        // Baseline is the destination screen's OCR tokens.
        let baseline = try String(contentsOf: result.baselinePath, encoding: .utf8)
        XCTAssertTrue(baseline.contains("Software Version 17.5.1"))
        XCTAssertTrue(baseline.contains("Model Name"))

        // Plan entry created, skip:true under nice_to_pass.
        let plan = try String(contentsOf: root.appendingPathComponent("mirroir.yaml"), encoding: .utf8)
        XCTAssertTrue(plan.contains("name: settings"))
        XCTAssertTrue(plan.contains("local: apps/settings"))
        XCTAssertTrue(plan.contains("skip: true"))
    }

    func testReEmitIsIdempotentForPlan() throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        _ = try MirroirAppTreeEmitter.emit(
            appName: "Settings", flow: "v", screens: sampleScreens(), root: root)
        let second = try MirroirAppTreeEmitter.emit(
            appName: "Settings", flow: "v", screens: sampleScreens(), root: root)
        XCTAssertTrue(second.planNote.contains("already present"),
            "second emit should not duplicate the plan entry: \(second.planNote)")
    }

    func testSlugify() {
        XCTAssertEqual(MirroirAppTreeEmitter.slugify("Wi-Fi & Bluetooth"), "wi-fi-bluetooth")
        XCTAssertEqual(MirroirAppTreeEmitter.slugify("  Settings  "), "settings")
        XCTAssertEqual(MirroirAppTreeEmitter.slugify("!!!"), "app")
    }

    func testScenarioYAMLEmitsValidatedVerbShapes() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "verb-coverage", appName: "TestApp", screens: [
                screen(index: 0, action: nil, via: nil, elements: ["Start"]),
                screen(index: 1, action: "type", via: "Email", elements: ["Field"]),
                screen(index: 2, action: "scroll_to", via: "Bottom", elements: ["Welcome Home Page"]),
            ])
        XCTAssertTrue(yaml.contains("- target: { kind: ios, app: \"TestApp\" }"))
        XCTAssertTrue(yaml.contains("- type: \"Email\""))
        XCTAssertTrue(yaml.contains("- scroll_to: \"Bottom\""))
    }

    /// Assertions keep their verb. The formatter used to rewrite any action
    /// type it had no case for — `assert_visible` included — into `- tap:`,
    /// recording a walk that tapped where the capture only looked.
    func testAssertionsKeepTheirVerb() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "asserts", appName: "TestApp", screens: [
                screen(index: 0, action: nil, via: nil, elements: ["Start"]),
                screen(index: 1, action: "assert_visible", via: "inbox", elements: ["Inbox"]),
                screen(index: 2, action: "assert_not_visible", via: "Error", elements: ["Inbox"]),
            ])
        XCTAssertTrue(yaml.contains("- assert_visible: \"Inbox\""))
        XCTAssertTrue(yaml.contains("- assert_not_visible: \"Error\""))
        XCTAssertFalse(yaml.contains("- tap:"))
    }

    /// Typed text, a swipe direction, or a URL is the action's own value, not
    /// an on-screen label. Fuzzy-matching it against the screen used to swap
    /// `type: "hello"` for a visible "hello world" and `swipe: "up"` for a
    /// visible "Update".
    func testLiteralValuesAreNotMatchedAgainstTheScreen() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "literals", appName: "TestApp", screens: [
                screen(index: 0, action: nil, via: nil, elements: ["Start"]),
                screen(index: 1, action: "type", via: "hello", elements: ["hello world"]),
                screen(index: 2, action: "swipe", via: "up", elements: ["Software Update"]),
                screen(index: 3, action: "open_url", via: "https://example.com", elements: ["example"]),
            ])
        XCTAssertTrue(yaml.contains("- type: \"hello\""))
        XCTAssertTrue(yaml.contains("- swipe: \"up\""))
        XCTAssertTrue(yaml.contains("- open_url: \"https://example.com\""))
    }

    /// Element-targeting actions still resolve to the element's exact casing.
    func testElementActionsResolveToTheOnScreenLabel() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "elements", appName: "TestApp", screens: [
                screen(index: 0, action: nil, via: nil, elements: ["Start"]),
                screen(index: 1, action: "tap", via: "general", elements: ["General"]),
                screen(index: 2, action: "long_press", via: "photo", elements: ["Photo"]),
            ])
        XCTAssertTrue(yaml.contains("- tap: \"General\""))
        XCTAssertTrue(yaml.contains("- long_press: \"Photo\""))
    }

    /// An action the scenario grammar cannot express is refused, not recorded
    /// as a tap — and the refusal reaches the emitter's caller.
    func testUnsupportedActionIsRefused() throws {
        let screens = [
            screen(index: 0, action: nil, via: nil, elements: ["Start"]),
            screen(index: 1, action: "pinch", via: "Map", elements: ["Map"]),
        ]
        XCTAssertThrowsError(try ScenarioStepFormatter.scenarioYAML(
            name: "pinch", appName: "Maps", screens: screens)) { error in
            XCTAssertEqual(error as? ScenarioStepFormatter.FormatError, .unsupportedAction("pinch"))
        }

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(
            appName: "Maps", flow: "zoom", screens: screens, root: root))
    }

    func testEmitRoutesToOutputDir() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let result = try MirroirAppTreeEmitter.emit(
            appName: "Demo", flow: "f", screens: sampleScreens(), outputDir: base.path)
        XCTAssertTrue(result.scenarioPath.path.hasPrefix(base.appendingPathComponent(".mirroir").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.scenarioPath.path))
    }

    func testRootLocatorRefusesHomeAndHonorsExplicitDir() {
        // ~/.mirroir is the runner's pack home — never emit there.
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertNil(MirroirRootLocator.resolve(start: home))
        // An explicit dir maps to <dir>/.mirroir.
        let explicit = "/tmp/mirroir-loc-\(UUID().uuidString)"
        let resolved = MirroirRootLocator.resolve(explicitDir: explicit)
        XCTAssertEqual(resolved?.lastPathComponent, ".mirroir")
        XCTAssertTrue(resolved?.path.hasPrefix(explicit) ?? false)
        // A non-home dir with no .mirroir resolves to <dir>/.mirroir.
        let nonHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-nh-\(UUID().uuidString)")
        XCTAssertEqual(MirroirRootLocator.resolve(start: nonHome)?.lastPathComponent, ".mirroir")
    }

    func testWalkUpTerminatesForDirectoryFormURLWithoutMirroir() {
        // Regression: homeDirectoryForCurrentUser is a directory-form (trailing-slash)
        // URL whose deletingLastPathComponent never settles at "/". Walking up from
        // such a URL with no .mirroir up-tree must terminate, not spin — this hung CI
        // (15-min timeout) where ~/.mirroir is absent. Run on a background queue with a
        // hard timeout so a regression FAILS fast instead of hanging the suite.
        let dirForm = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mirroir-walkup-\(UUID().uuidString)", isDirectory: true)
        let done = expectation(description: "resolve terminates")
        // Synchronized by the expectation: the write happens-before fulfill(), which
        // happens-before wait(for:) returns, which happens-before the read below.
        nonisolated(unsafe) var resolved: URL?
        DispatchQueue.global().async {
            resolved = MirroirRootLocator.resolve(start: dirForm)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(resolved?.lastPathComponent, ".mirroir")
    }
}
