// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the .mirroir/ iOS-leg emitter — scenario YAML shape, SAMPLE.md, plan upsert, idempotency.
// ABOUTME: The emitted tree must be runnable as it lands: readable by mirroir-mcp and declared for mirroir-run.

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

    /// The emitted tree runs as it lands: the scenario, the SAMPLE.md that
    /// declares it, and a `must_pass` plan entry — no committed baseline for an
    /// orphan guard to refuse, and no `skip: true` stub for a run to pass over.
    func testEmitWritesARunnableTree() throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let result = try MirroirAppTreeEmitter.emit(
            appName: "Settings", flows: [.init(name: "check software version", screens: sampleScreens())], root: root)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: result.scenarioPaths.first?.path ?? ""))
        XCTAssertTrue(fm.fileExists(atPath: result.appDir.appendingPathComponent("APP.md").path))
        XCTAssertFalse(fm.fileExists(atPath: result.appDir.appendingPathComponent("baselines").path),
                       "the iOS block's live capture replaces a committed baseline")
        XCTAssertEqual(result.scenarioPaths.count, 1)
        let scenarioPath = try XCTUnwrap(result.scenarioPaths.first)
        let scenarios = try fm.contentsOfDirectory(
            atPath: scenarioPath.deletingLastPathComponent().path)
        XCTAssertEqual(scenarios, ["check-software-version.ios.yaml"])

        // Scenario carries the ownership header, the iOS target, launch, the
        // taps with a wait for each arrival, and is well-formed.
        let scenario = try String(contentsOf: scenarioPath, encoding: .utf8)
        XCTAssertTrue(scenario.hasPrefix(
            ScenarioStepFormatter.generatedHeader + "\nversion: 1\nname: \"check-software-version\"\n"))
        // The flow starts from the app's root: a reset of the app right before
        // its launch, the one reset_app the destructive-step gate exempts.
        XCTAssertTrue(scenario.contains(
            "  - target: { kind: ios, app: \"Settings\" }\n" +
            "  - reset_app: \"Settings\"\n  - launch: \"Settings\"\n"), scenario)

        XCTAssertTrue(scenario.contains("- tap: \"General\""))
        XCTAssertTrue(scenario.contains("- tap: \"About\""))
        // Each tap waits for the longest label its arrival screen added; the
        // destination assertion would repeat the last wait, so it is not written.
        XCTAssertTrue(scenario.contains("- tap: \"General\"\n  - wait_for: \"Software Update\""))
        XCTAssertTrue(scenario.contains("- tap: \"About\"\n  - wait_for: \"Software Version 17.5.1\""))
        XCTAssertFalse(scenario.contains("- assert_visible:"))

        // SAMPLE.md declares the scenario under must_pass.
        let sample = try String(
            contentsOf: result.appDir.appendingPathComponent("SAMPLE.md"), encoding: .utf8)
        XCTAssertTrue(sample.contains("    must_pass:\n      - scenarios/check-software-version.ios.yaml"))
        XCTAssertTrue(sample.contains("command: \"true\""))

        // Plan entry under must_pass, never skipped.
        let plan = try String(contentsOf: root.appendingPathComponent("mirroir.yaml"), encoding: .utf8)
        XCTAssertTrue(plan.contains("  must_pass:\n    - name: settings"))
        XCTAssertTrue(plan.contains("local: apps/settings"))
        XCTAssertFalse(plan.contains("skip:"))
        XCTAssertFalse(plan.contains("nice_to_pass"))

        // The parsed file is a runnable skill for mirroir-mcp too: its target
        // is the iPhone, and no step is unreadable.
        let skill = SkillParser.parse(content: scenario, filePath: scenarioPath.path)
        XCTAssertNil(InvalidStepGate.refuse(skills: [skill]))
        XCTAssertNil(DestructiveStepGate.refuse(skills: [skill], dryRun: false, confirmed: false),
                     "an emitted flow's own-app reset runs without --confirm-destructive")
        guard case .switchTarget(let selector) = skill.steps.first else {
            return XCTFail("the scenario must open with its target: \(skill.steps)")
        }
        XCTAssertEqual(selector, .ios(app: "Settings"))
    }

    /// A second flow of the same app joins the SAMPLE.md the first emit
    /// created and owns: both stay declared, the first one first.
    func testASecondFlowJoinsTheSampleTheEmitterOwns() throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        _ = try MirroirAppTreeEmitter.emit(
            appName: "Settings", flows: [.init(name: "first", screens: sampleScreens())], root: root)
        let second = try MirroirAppTreeEmitter.emit(
            appName: "Settings", flows: [.init(name: "second", screens: sampleScreens())], root: root)
        let sample = try String(
            contentsOf: second.appDir.appendingPathComponent("SAMPLE.md"), encoding: .utf8)
        XCTAssertTrue(sample.contains(
            "    must_pass:\n      - scenarios/first.ios.yaml\n      - scenarios/second.ios.yaml\n"),
            sample)
    }

    func testReEmitIsIdempotentForPlan() throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        _ = try MirroirAppTreeEmitter.emit(
            appName: "Settings", flows: [.init(name: "v", screens: sampleScreens())], root: root)
        let second = try MirroirAppTreeEmitter.emit(
            appName: "Settings", flows: [.init(name: "v", screens: sampleScreens())], root: root)
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
                screen(index: 2, action: "scroll_to", via: "Bottom", elements: ["Bottom", "Welcome Home Page"]),
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
                screen(index: 0, action: nil, via: nil, elements: ["Start", "Inbox"]),
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

    /// Element-targeting actions resolve to the element's exact casing on the
    /// screen they acted on — the screen before the one they reached.
    func testElementActionsResolveToTheOnScreenLabel() throws {
        let yaml = try ScenarioStepFormatter.scenarioYAML(
            name: "elements", appName: "TestApp", screens: [
                screen(index: 0, action: nil, via: nil, elements: ["General"]),
                screen(index: 1, action: "tap", via: "general", elements: ["Photo"]),
                screen(index: 2, action: "long_press", via: "photo", elements: ["Done"]),
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
            XCTAssertEqual(error as? ScenarioStepFormatter.FormatError, .unsupportedAction(index: 1, action: "pinch"))
        }

        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertThrowsError(try MirroirAppTreeEmitter.emit(
            appName: "Maps", flows: [.init(name: "zoom", screens: screens)], root: root))
    }

    func testEmitRoutesToOutputDir() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mirroir-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let result = try MirroirAppTreeEmitter.emit(
            appName: "Demo", flows: [.init(name: "f", screens: sampleScreens())], outputDir: base.path)
        let scenarioPath = try XCTUnwrap(result.scenarioPaths.first)
        XCTAssertTrue(scenarioPath.path.hasPrefix(base.appendingPathComponent(".mirroir").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scenarioPath.path))
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
