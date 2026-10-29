// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Interactive CLI command that configures iPhone keyboard layout.
// ABOUTME: Saves the choice to ~/.mirroir-mcp/settings.json so text is typed with that layout's keys.

import Foundation
import HelperLib

/// Interactive setup wizard for mirroir-mcp configuration.
///
/// Usage: `mirroir-mcp configure [--help]`
enum ConfigureCommand {

    /// Known keyboard layouts with display names.
    /// The value is the macOS TIS source ID suffix (e.g., "Canadian-CSA"
    /// resolves to "com.apple.keylayout.Canadian-CSA").
    private static let layouts: [(name: String, description: String)] = [
        ("US", "US QWERTY (default)"),
        ("Canadian-CSA", "French (Canada)"),
        ("French-PC", "French (France)"),
        ("German", "German"),
        ("Spanish-ISO", "Spanish"),
        ("British", "British"),
        ("Italian", "Italian"),
        ("Swiss French", "Swiss French"),
        ("Swiss German", "Swiss German"),
        ("Portuguese", "Portuguese"),
    ]

    static func run(arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return 0
        }

        fputs("\niPhone Keyboard Layout\n", stderr)
        fputs("Select the keyboard layout used by your iPhone:\n\n", stderr)

        for (i, layout) in layouts.enumerated() {
            let marker = i == 0 ? " (default)" : ""
            fputs("  \(i + 1)) \(layout.description)\(marker)\n", stderr)
        }
        fputs("  \(layouts.count + 1)) Other (enter layout name)\n", stderr)
        fputs("\nEnter choice [1]: ", stderr)

        let input = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""

        let layoutName: String
        if input.isEmpty {
            layoutName = layouts[0].name
        } else if let choice = Int(input), choice >= 1, choice <= layouts.count {
            layoutName = layouts[choice - 1].name
        } else if let choice = Int(input), choice == layouts.count + 1 {
            fputs("Enter macOS keyboard layout name (e.g., 'Canadian-CSA'): ", stderr)
            guard let custom = readLine()?.trimmingCharacters(in: .whitespaces),
                  !custom.isEmpty else {
                fputs("No layout name entered.\n", stderr)
                return 1
            }
            // Verify the layout exists on this Mac
            let fullID = LayoutMapper.sourceID(forLayout: custom)
            if LayoutMapper.layoutData(forSourceID: fullID) == nil {
                fputs("Warning: layout '\(fullID)' not found on this Mac.\n", stderr)
                fputs("Saving anyway — it may be available on other systems.\n", stderr)
            }
            layoutName = custom
        } else {
            fputs("Invalid choice: '\(input)'\n", stderr)
            return 1
        }

        // Save to ~/.mirroir-mcp/settings.json
        let saved = saveKeyboardLayout(layoutName)
        if saved {
            if layoutName == "US" {
                fputs("\nSaved: US QWERTY\n", stderr)
            } else {
                fputs("\nSaved: \(layoutName) → ~/.mirroir-mcp/settings.json\n", stderr)
            }
            return 0
        } else {
            fputs("Failed to save settings.\n", stderr)
            return 1
        }
    }

    // MARK: - Settings File

    /// Save the keyboard layout to ~/.mirroir-mcp/settings.json.
    /// Merges with existing settings without overwriting other keys.
    private static func saveKeyboardLayout(_ layout: String) -> Bool {
        let configDir = ("~/.mirroir-mcp" as NSString).expandingTildeInPath
        let settingsPath = configDir + "/settings.json"

        // Ensure directory exists
        do {
            try FileManager.default.createDirectory(
                atPath: configDir, withIntermediateDirectories: true)
        } catch {
            fputs("Error creating config directory: \(error.localizedDescription)\n", stderr)
            return false
        }

        // Load existing settings or start fresh
        var settings = [String: Any]()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        // Update keyboard layout (empty string = US QWERTY, the default)
        settings["keyboardLayout"] = layout == "US" ? "" : layout

        // Write back
        do {
            let data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: settingsPath))
            return true
        } catch {
            fputs("Error writing settings: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    private static func printUsage() {
        let usage = """
        Usage: mirroir-mcp configure [options]

        Interactive setup for mirroir-mcp. Configures the iPhone keyboard
        layout for correct character input via iPhone Mirroring.

        The selected layout is saved to ~/.mirroir-mcp/settings.json.

        Options:
          --help, -h    Show this help

        Examples:
          mirroir-mcp configure
        """
        fputs(usage + "\n", stderr)
    }
}
