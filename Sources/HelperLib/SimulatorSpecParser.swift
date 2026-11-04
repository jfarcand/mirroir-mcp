// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Parses APP.md `## Simulator …` H2 sections into a typed SimulatorSpec.
// ABOUTME: Stays inside APP.md (single source of truth) without introducing a YAML dependency.

import Foundation

/// Parses APP.md sections to produce a `SimulatorSpec`.
///
/// Recognized H2 sections:
///   - `## Simulator`             — declares root screen and overall metadata via bullets
///   - `## Simulator Screen <id>` — one per screen
///   - `## Simulator Obstacle <id>` — one per obstacle
///
/// Bullet syntax inside each section is `- key: value` for properties or
/// `- element <kind>: …` for screen elements. See unit tests for examples.
public enum SimulatorSpecParser {

    /// Build a `SimulatorSpec` from already-extracted markdown sections + frontmatter.
    /// Returns nil when no Simulator-related sections are present (the app is
    /// guidance-only, not yet ported to the simulator).
    public static func parse(
        sections: [String: String],
        frontMatter: [String: String],
        appName: String
    ) -> SimulatorSpec? {
        let screenSections = sections.filter { $0.key.hasPrefix("Simulator Screen ") }
        let obstacleSections = sections.filter { $0.key.hasPrefix("Simulator Obstacle ") }
        let rootBlock = sections["Simulator"]
        guard !screenSections.isEmpty || rootBlock != nil else { return nil }

        let rootProps = rootBlock.map(parseProperties) ?? [:]
        let rootScreenID = rootProps["root"] ?? screenSections.keys
            .map { String($0.dropFirst("Simulator Screen ".count)) }
            .sorted()
            .first ?? "main"

        let spotlightName = frontMatter["spotlight_name"] ?? appName
        let icon = frontMatter["icon"] ?? String(appName.prefix(1))

        var screens: [String: SimulatorScreen] = [:]
        for (header, body) in screenSections {
            let id = String(header.dropFirst("Simulator Screen ".count))
            screens[id] = parseScreen(id: id, body: body)
        }

        var obstacles: [SimulatorObstacle] = []
        for (header, body) in obstacleSections.sorted(by: { $0.key < $1.key }) {
            let id = String(header.dropFirst("Simulator Obstacle ".count))
            if let obs = parseObstacle(id: id, body: body) {
                obstacles.append(obs)
            }
        }

        return SimulatorSpec(
            appName: appName,
            spotlightName: spotlightName,
            icon: icon,
            rootScreenID: rootScreenID,
            tabBarStyle: parseTabBarStyle(rootProps["tab_bar_style"]),
            screens: screens,
            obstacles: obstacles
        )
    }

    // MARK: - Section parsers

    private static func parseScreen(id: String, body: String) -> SimulatorScreen {
        let props = parseProperties(body)
        let title = props["title"] ?? id
        let backTo = props["back"].flatMap { value in
            value.lowercased() == "null" || value.isEmpty ? nil : value
        }
        let hasTabBar = parseBool(props["tab_bar"]) ?? false
        let elements = parseElements(body)
        return SimulatorScreen(
            id: id, title: title, backTo: backTo,
            hasTabBar: hasTabBar, elements: elements
        )
    }

    private static func parseObstacle(id: String, body: String) -> SimulatorObstacle? {
        let props = parseProperties(body)
        guard let title = props["title"], !title.isEmpty else { return nil }
        let bodyText = props["body"]
        let buttons = (props["buttons"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let trigger = parseTrigger(props["trigger"] ?? "on_first_describe")
        return SimulatorObstacle(
            id: id, title: title, body: bodyText,
            buttons: buttons, trigger: trigger
        )
    }

    // MARK: - Bullet parsing

    /// Parse `- key: value` bullets into a dictionary, ignoring `- element …` lines
    /// and free prose. Quoted values have their surrounding quotes stripped.
    private static func parseProperties(_ body: String) -> [String: String] {
        var props: [String: String] = [:]
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- "), !line.lowercased().hasPrefix("- element") else {
                continue
            }
            let body = String(line.dropFirst(2))
            guard let colonIdx = body.firstIndex(of: ":") else { continue }
            let key = String(body[..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(body[body.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}"))
            props[key] = value
        }
        return props
    }

    /// Parse `- element <kind>: <text> [→ <screen_id>]` bullets into elements.
    ///
    /// Supported kinds:
    ///   - `row` / `button` / `text` / `tab`     — basic navigation/display
    ///   - `textfield: "placeholder" #fieldID`   — keyboard input
    ///   - `slider: "label" #fieldID = 0.5`      — drag slider, value 0.0-1.0
    ///   - `placeholder: 370x175`                — gray media block
    ///   - `grid: 3x3`                           — a board of COLSxROWS cells (one per screen)
    ///   - `cell: a1 → screen_id`                — a board cell's transition
    ///
    /// Arrow may be `→` or `->`. A grid size outside 1...26 columns or
    /// 1...99 rows drops the grid; a cell line the grid does not have (or
    /// with no grid, or no destination) is dropped. Cell lines may sit
    /// anywhere in the screen section.
    private static func parseElements(_ body: String) -> [SimulatorElement] {
        var elements: [SimulatorElement] = []
        var cellLines: [String] = []
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("- element") else { continue }

            // Strip "- element"; everything after is "<kind>: <body>"
            let afterElement = String(line.dropFirst("- element".count))
                .trimmingCharacters(in: .whitespaces)
            guard let colonIdx = afterElement.firstIndex(of: ":") else { continue }
            let kind = String(afterElement[..<colonIdx])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let valueRaw = String(afterElement[afterElement.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)

            switch kind {
            case "row":
                let (text, leadsTo) = splitTextAndDestination(valueRaw)
                elements.append(.row(text: text, leadsTo: leadsTo))
            case "button":
                let (text, leadsTo) = splitTextAndDestination(valueRaw)
                elements.append(.button(text: text, leadsTo: leadsTo))
            case "text":
                let (text, _) = splitTextAndDestination(valueRaw)
                elements.append(.text(text))
            case "tab":
                let (text, leadsTo) = splitTextAndDestination(valueRaw)
                if let leadsTo {
                    elements.append(.tab(text: text, leadsTo: leadsTo))
                }
            case "textfield":
                if let parsed = parseTextField(valueRaw) {
                    elements.append(parsed)
                }
            case "slider":
                if let parsed = parseSlider(valueRaw) {
                    elements.append(parsed)
                }
            case "placeholder":
                if let parsed = parsePlaceholder(valueRaw) {
                    elements.append(parsed)
                }
            case "grid":
                let hasGrid = elements.contains { if case .grid = $0 { return true } else { return false } }
                if !hasGrid, let grid = SimulatorGrid(size: valueRaw) {
                    elements.append(.grid(grid))
                }
            case "cell":
                cellLines.append(valueRaw)
            default: continue
            }
        }
        return applyCells(cellLines, to: elements)
    }

    /// Fold `cell: <name> → <screen>` lines into the screen's grid element.
    /// A line naming no destination, or a cell the grid does not have, is dropped.
    private static func applyCells(
        _ lines: [String], to elements: [SimulatorElement]
    ) -> [SimulatorElement] {
        guard let index = elements.firstIndex(where: {
            if case .grid = $0 { return true } else { return false }
        }), case .grid(var grid) = elements[index] else { return elements }
        for line in lines {
            let (name, leadsTo) = splitTextAndDestination(line)
            guard let leadsTo, let updated = grid.adding(cell: name, leadsTo: leadsTo) else {
                continue
            }
            grid = updated
        }
        var result = elements
        result[index] = .grid(grid)
        return result
    }

    /// Parse `"placeholder" #fieldID` → `.textField(...)`.
    private static func parseTextField(_ raw: String) -> SimulatorElement? {
        guard let hashIdx = raw.firstIndex(of: "#") else { return nil }
        let placeholderRaw = String(raw[..<hashIdx])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}"))
        let fieldID = String(raw[raw.index(after: hashIdx)...])
            .trimmingCharacters(in: .whitespaces)
        guard !placeholderRaw.isEmpty, !fieldID.isEmpty else { return nil }
        return .textField(placeholder: placeholderRaw, fieldID: fieldID)
    }

    /// Parse `"label" #fieldID = 0.5` → `.slider(...)`.
    private static func parseSlider(_ raw: String) -> SimulatorElement? {
        guard let hashIdx = raw.firstIndex(of: "#") else { return nil }
        let labelRaw = String(raw[..<hashIdx])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}"))
        let after = String(raw[raw.index(after: hashIdx)...])
        guard let eqIdx = after.firstIndex(of: "=") else { return nil }
        let fieldID = String(after[..<eqIdx]).trimmingCharacters(in: .whitespaces)
        let fractionRaw = String(after[after.index(after: eqIdx)...])
            .trimmingCharacters(in: .whitespaces)
        guard let fraction = Double(fractionRaw),
              !labelRaw.isEmpty, !fieldID.isEmpty else { return nil }
        return .slider(
            label: labelRaw, fraction: max(0.0, min(1.0, fraction)), fieldID: fieldID)
    }

    /// Parse `370x175` → `.placeholder(width:170, height:175)`.
    private static func parsePlaceholder(_ raw: String) -> SimulatorElement? {
        let parts = raw.split(separator: "x", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let w = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return .placeholder(width: w, height: h)
    }

    /// Split "Foo → bar" or "Foo -> bar" into ("Foo", "bar"). When no arrow,
    /// returns (raw, nil). Quote characters around the text portion are stripped.
    private static func splitTextAndDestination(_ raw: String) -> (String, String?) {
        let separators = ["→", "->"]
        for sep in separators {
            if let range = raw.range(of: sep) {
                let text = String(raw[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}"))
                let dest = String(raw[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                return (text, dest.isEmpty ? nil : dest)
            }
        }
        let cleaned = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}"))
        return (cleaned, nil)
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    /// Parse the `## Simulator` block's `tab_bar_style` value. Unrecognized or
    /// absent values fall back to `.labels` (the historical rendering).
    private static func parseTabBarStyle(_ value: String?) -> SimulatorTabBarStyle {
        guard let value else { return .labels }
        return SimulatorTabBarStyle(rawValue: value.lowercased()) ?? .labels
    }

    private static func parseTrigger(_ raw: String) -> SimulatorObstacleTrigger {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "never" { return .never }
        if value.hasPrefix("after_n_taps:") {
            let count = Int(value.dropFirst("after_n_taps:".count)
                .trimmingCharacters(in: .whitespaces)) ?? 0
            return .afterTaps(count: max(0, count))
        }
        return .onFirstDescribe
    }
}
