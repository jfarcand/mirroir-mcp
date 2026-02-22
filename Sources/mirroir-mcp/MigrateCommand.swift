// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: CLI command `mirroir migrate` that converts YAML skills to SKILL.md format.
// ABOUTME: Transforms structured YAML steps into natural-language markdown for AI execution.

import Foundation

/// Converts YAML skill files to SKILL.md format (YAML front matter + markdown body).
///
/// Usage: `mirroir-mcp migrate [options] <file.yaml> [file2.yaml ...]`
///        `mirroir-mcp migrate --dir <path>`
enum MigrateCommand {

    /// Parse arguments and run the migration. Returns exit code (0 = success, 1 = error).
    static func run(arguments: [String]) -> Int32 {
        let config = parseArguments(arguments)

        if config.showHelp {
            printUsage()
            return 0
        }

        // Collect YAML files to migrate
        var yamlFiles: [String] = []

        if let dir = config.directory {
            let found = MirroirMCP.findYAMLFiles(in: dir)
            yamlFiles = found.map { dir + "/" + $0 }
        }

        yamlFiles.append(contentsOf: config.files)

        if yamlFiles.isEmpty {
            fputs("Error: No YAML files specified. Use --dir <path> or provide file paths.\n", stderr)
            printUsage()
            return 1
        }

        fputs("mirroir migrate: \(yamlFiles.count) file(s) to convert\n", stderr)

        var anyFailed = false

        for filePath in yamlFiles {
            let result = migrateFile(
                filePath: filePath,
                outputDir: config.outputDir,
                sourceBaseDir: config.directory,
                dryRun: config.dryRun
            )
            if !result {
                anyFailed = true
            }
        }

        let status = anyFailed ? "completed with errors" : "done"
        fputs("\nmirroir migrate: \(status)\n", stderr)
        return anyFailed ? 1 : 0
    }

    /// Migrate a single YAML file to SKILL.md format.
    /// When `sourceBaseDir` is set (from `--dir`), relative paths under it are preserved
    /// in `outputDir`. Without a base dir, only the filename is placed in `outputDir`.
    /// Returns true on success, false on failure.
    static func migrateFile(
        filePath: String,
        outputDir: String?,
        sourceBaseDir: String? = nil,
        dryRun: Bool
    ) -> Bool {
        let content: String
        do {
            content = try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            fputs("  Error reading \(filePath): \(error.localizedDescription)\n", stderr)
            return false
        }

        let markdown = convertYAMLToSkillMd(content: content, filePath: filePath)

        if dryRun {
            fputs("--- \(filePath) ---\n", stderr)
            print(markdown)
            fputs("---\n\n", stderr)
            return true
        }

        let outputPath = resolveOutputPath(
            yamlPath: filePath, outputDir: outputDir, sourceBaseDir: sourceBaseDir)
        do {
            let dir = (outputPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            try markdown.write(toFile: outputPath, atomically: true, encoding: .utf8)
            fputs("  \(filePath) -> \(outputPath)\n", stderr)
            return true
        } catch {
            fputs("  Error writing \(outputPath): \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    /// Convert YAML skill content to SKILL.md format.
    static func convertYAMLToSkillMd(content: String, filePath: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        let header = extractHeaderFields(from: lines)
        let comments = extractComments(from: lines)
        let steps = extractRawSteps(from: lines)

        var parts: [String] = []

        // Front matter
        parts.append("---")
        parts.append("version: 1")
        parts.append("name: \(header.name)")
        if !header.app.isEmpty {
            parts.append("app: \(header.app)")
        }
        if !header.iosMin.isEmpty {
            parts.append("ios_min: \"\(header.iosMin)\"")
        }
        if !header.locale.isEmpty {
            parts.append("locale: \"\(header.locale)\"")
        }
        if !header.tags.isEmpty {
            let tagList = header.tags.map { "\"\($0)\"" }.joined(separator: ", ")
            parts.append("tags: [\(tagList)]")
        }
        parts.append("---")
        parts.append("")

        // Description as the first paragraph
        if !header.description.isEmpty {
            parts.append(header.description)
            parts.append("")
        }

        // Comments as notes
        if !comments.isEmpty {
            for comment in comments {
                parts.append("> Note: \(comment)")
            }
            parts.append("")
        }

        // Steps section
        if !steps.isEmpty {
            parts.append("## Steps")
            parts.append("")
            let convertedSteps = convertSteps(steps, startNumber: 1, indent: 0)
            parts.append(contentsOf: convertedSteps)
        }

        return parts.joined(separator: "\n") + "\n"
    }

    // MARK: - Header Extraction

    /// Raw header fields from a YAML skill file.
    struct HeaderFields {
        var name: String = ""
        var app: String = ""
        var description: String = ""
        var iosMin: String = ""
        var locale: String = ""
        var tags: [String] = []
    }

    /// Extract all header fields from YAML lines (everything before `steps:`).
    static func extractHeaderFields(from lines: [String]) -> HeaderFields {
        var header = HeaderFields()
        var collectingDescription = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "steps:" || trimmed == "targets:" { break }

            if collectingDescription {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    let continuation = trimmed
                    if !continuation.isEmpty {
                        if header.description.isEmpty {
                            header.description = continuation
                        } else {
                            header.description += " " + continuation
                        }
                    }
                    continue
                } else {
                    collectingDescription = false
                }
            }

            if trimmed.hasPrefix("name:") {
                header.name = MirroirMCP.extractYAMLValue(from: trimmed, key: "name")
            } else if trimmed.hasPrefix("app:") {
                header.app = MirroirMCP.extractYAMLValue(from: trimmed, key: "app")
            } else if trimmed.hasPrefix("description:") {
                let value = MirroirMCP.extractYAMLValue(from: trimmed, key: "description")
                if value == ">" || value == "|" || value == ">-" || value == "|-" {
                    collectingDescription = true
                    header.description = ""
                } else {
                    header.description = value
                }
            } else if trimmed.hasPrefix("ios_min:") {
                header.iosMin = MirroirMCP.extractYAMLValue(from: trimmed, key: "ios_min")
            } else if trimmed.hasPrefix("locale:") {
                header.locale = MirroirMCP.extractYAMLValue(from: trimmed, key: "locale")
            } else if trimmed.hasPrefix("tags:") {
                let value = MirroirMCP.extractYAMLValue(from: trimmed, key: "tags")
                header.tags = parseInlineTags(value)
            }
        }

        return header
    }

    /// Parse a YAML inline array of tags like `["tag1", "tag2"]`.
    private static func parseInlineTags(_ raw: String) -> [String] {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value.components(separatedBy: ",").compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return SkillParser.stripQuotes(trimmed)
        }
    }

    // MARK: - Comment Extraction

    /// Extract standalone comments from YAML lines (lines starting with #).
    static func extractComments(from lines: [String]) -> [String] {
        var comments: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let comment = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !comment.isEmpty {
                    comments.append(comment)
                }
            }
        }
        return comments
    }

    // MARK: - Step Extraction & Conversion

    /// A raw step from the YAML, preserving nesting structure for conditions/repeats.
    enum RawStep {
        case simple(key: String, value: String)
        case condition(ifVisible: String, thenSteps: [RawStep], elseSteps: [RawStep])
        case `repeat`(whileVisible: String, max: Int, steps: [RawStep])
    }

    /// Extract raw steps from YAML lines, preserving condition/repeat structure.
    /// Only recognizes the top-level `steps:` keyword (at indent 0 or the file's header level).
    /// Nested `steps:` inside repeat blocks are collected as-is for sub-parsing.
    static func extractRawSteps(from lines: [String]) -> [RawStep] {
        var inSteps = false
        var stepLines: [String] = []
        var stepsIndent = -1

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count

            // Only match the top-level `steps:` (non-indented or at the header level)
            if trimmed == "steps:" && !inSteps {
                inSteps = true
                stepsIndent = indent
                continue
            }

            // Skip nested `steps:` that are deeper than the top-level one
            if inSteps && trimmed == "steps:" && indent > stepsIndent {
                stepLines.append(line)
                continue
            }

            if inSteps {
                // A non-indented, non-empty line after steps: means we left the steps block
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty
                    && !trimmed.hasPrefix("#") {
                    break
                }
                stepLines.append(line)
            }
        }

        return parseRawStepsBlock(stepLines, baseIndent: detectBaseIndent(stepLines))
    }

    /// Detect the indentation level of the first list item in a block.
    private static func detectBaseIndent(_ lines: [String]) -> Int {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                let leadingSpaces = line.prefix(while: { $0 == " " }).count
                return leadingSpaces
            }
        }
        return 2
    }

    /// Parse a block of step lines into RawStep values.
    private static func parseRawStepsBlock(_ lines: [String], baseIndent: Int) -> [RawStep] {
        var steps: [RawStep] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            guard trimmed.hasPrefix("- ") else {
                i += 1
                continue
            }

            let stepContent = String(trimmed.dropFirst(2))

            // Check for condition
            if stepContent.trimmingCharacters(in: .whitespaces) == "condition:" {
                let (condition, consumed) = parseConditionBlock(lines: lines, startIndex: i + 1, baseIndent: baseIndent)
                steps.append(condition)
                i += 1 + consumed
                continue
            }

            // Check for repeat
            if stepContent.trimmingCharacters(in: .whitespaces) == "repeat:" {
                let (repeatStep, consumed) = parseRepeatBlock(lines: lines, startIndex: i + 1, baseIndent: baseIndent)
                steps.append(repeatStep)
                i += 1 + consumed
                continue
            }

            // Simple step: "key: value" or bare keyword
            let parsed = parseSimpleStep(stepContent)
            steps.append(parsed)
            i += 1
        }

        return steps
    }

    /// Parse a simple step string like `launch: "Mail"` or `home`.
    private static func parseSimpleStep(_ raw: String) -> RawStep {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // Bare keywords
        if trimmed == "home" || trimmed == "press_home" {
            return .simple(key: "home", value: "")
        }
        if trimmed == "shake" {
            return .simple(key: "shake", value: "")
        }

        // "key: value" format
        guard let colonIndex = trimmed.firstIndex(of: ":") else {
            return .simple(key: trimmed, value: "")
        }

        let key = String(trimmed[trimmed.startIndex..<colonIndex])
            .trimmingCharacters(in: .whitespaces)
        let rawValue = String(trimmed[trimmed.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespaces)
        let value = SkillParser.stripQuotes(rawValue)

        // Handle press_home: true as a bare home step
        if key == "press_home" {
            return .simple(key: "home", value: "")
        }

        return .simple(key: key, value: value)
    }

    /// Parse a condition block starting after `- condition:`.
    /// Returns the parsed condition and how many lines were consumed.
    /// Only recognizes `if_visible:`, `then:`, `else:` at the condition's own keyword
    /// indentation level, so nested conditions don't confuse the outer parser.
    private static func parseConditionBlock(
        lines: [String], startIndex: Int, baseIndent: Int
    ) -> (RawStep, Int) {
        var ifVisible = ""
        var thenLines: [String] = []
        var elseLines: [String] = []
        var inThen = false
        var inElse = false
        var consumed = 0
        // The keyword indent level is detected from the first keyword (if_visible:)
        var keywordIndent: Int?

        for j in startIndex..<lines.count {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count

            // Stop if we hit a line at or below the base indent that's a new list item
            if indent <= baseIndent && trimmed.hasPrefix("- ") {
                break
            }

            consumed += 1

            // Detect keyword indent from the first meaningful line
            if keywordIndent == nil && !trimmed.isEmpty {
                keywordIndent = indent
            }

            // Only recognize condition keywords at the expected indent level
            let isAtKeywordLevel = (keywordIndent != nil && indent == keywordIndent)

            if isAtKeywordLevel && trimmed.hasPrefix("if_visible:") {
                ifVisible = SkillParser.stripQuotes(
                    MirroirMCP.extractYAMLValue(from: trimmed, key: "if_visible"))
            } else if isAtKeywordLevel && trimmed == "then:" {
                inThen = true
                inElse = false
            } else if isAtKeywordLevel && trimmed == "else:" {
                inThen = false
                inElse = true
            } else if inThen {
                thenLines.append(line)
            } else if inElse {
                elseLines.append(line)
            }
        }

        let thenSteps = parseRawStepsBlock(thenLines, baseIndent: detectBaseIndent(thenLines))
        let elseSteps = parseRawStepsBlock(elseLines, baseIndent: detectBaseIndent(elseLines))

        return (.condition(ifVisible: ifVisible, thenSteps: thenSteps, elseSteps: elseSteps), consumed)
    }

    /// Parse a repeat block starting after `- repeat:`.
    /// Returns the parsed repeat and how many lines were consumed.
    /// Only recognizes `while_visible:`, `max:`, `steps:` at the repeat's own keyword
    /// indentation level.
    private static func parseRepeatBlock(
        lines: [String], startIndex: Int, baseIndent: Int
    ) -> (RawStep, Int) {
        var whileVisible = ""
        var maxCount = 10
        var stepLines: [String] = []
        var inSteps = false
        var consumed = 0
        var keywordIndent: Int?

        for j in startIndex..<lines.count {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count

            if indent <= baseIndent && trimmed.hasPrefix("- ") {
                break
            }

            consumed += 1

            if keywordIndent == nil && !trimmed.isEmpty {
                keywordIndent = indent
            }

            let isAtKeywordLevel = (keywordIndent != nil && indent == keywordIndent)

            if isAtKeywordLevel && trimmed.hasPrefix("while_visible:") {
                whileVisible = SkillParser.stripQuotes(
                    MirroirMCP.extractYAMLValue(from: trimmed, key: "while_visible"))
            } else if isAtKeywordLevel && trimmed.hasPrefix("max:") {
                let maxStr = MirroirMCP.extractYAMLValue(from: trimmed, key: "max")
                maxCount = Int(maxStr) ?? 10
            } else if isAtKeywordLevel && trimmed == "steps:" {
                inSteps = true
            } else if inSteps {
                stepLines.append(line)
            }
        }

        let innerSteps = parseRawStepsBlock(stepLines, baseIndent: detectBaseIndent(stepLines))
        return (.repeat(whileVisible: whileVisible, max: maxCount, steps: innerSteps), consumed)
    }

    /// Convert a list of RawSteps to numbered markdown lines.
    static func convertSteps(_ steps: [RawStep], startNumber: Int, indent: Int) -> [String] {
        var lines: [String] = []
        var number = startNumber
        let prefix = String(repeating: " ", count: indent)

        for step in steps {
            switch step {
            case .simple(let key, let value):
                let text = formatSimpleStep(key: key, value: value)
                lines.append("\(prefix)\(number). \(text)")
                number += 1

            case .condition(let ifVisible, let thenSteps, let elseSteps):
                lines.append("\(prefix)\(number). If \"\(ifVisible)\" is visible:")
                let thenLines = convertSteps(thenSteps, startNumber: 1, indent: indent + 3)
                lines.append(contentsOf: thenLines)
                if !elseSteps.isEmpty {
                    lines.append("\(prefix)   Otherwise:")
                    let elseLines = convertSteps(elseSteps, startNumber: 1, indent: indent + 3)
                    lines.append(contentsOf: elseLines)
                }
                number += 1

            case .repeat(let whileVisible, let maxCount, let innerSteps):
                lines.append("\(prefix)\(number). Repeat while \"\(whileVisible)\" is visible (max \(maxCount)):")
                let innerLines = convertSteps(innerSteps, startNumber: 1, indent: indent + 3)
                lines.append(contentsOf: innerLines)
                number += 1
            }
        }

        return lines
    }

    /// Format a simple step into natural-language markdown.
    static func formatSimpleStep(key: String, value: String) -> String {
        switch key {
        case "launch":
            return "Launch **\(value)**"
        case "tap":
            return "Tap \"\(value)\""
        case "type":
            return "Type \"\(value)\""
        case "wait_for":
            return "Wait for \"\(value)\" to appear"
        case "assert_visible":
            return "Verify \"\(value)\" is visible"
        case "assert_not_visible":
            return "Verify \"\(value)\" is NOT visible"
        case "screenshot":
            return "Screenshot: \"\(value)\""
        case "press_key":
            return formatPressKey(value)
        case "home":
            return "Press Home"
        case "open_url":
            return "Open URL: \(value)"
        case "shake":
            return "Shake the device"
        case "scroll_to":
            return "Scroll until \"\(value)\" is visible"
        case "reset_app":
            return "Force-quit **\(value)**"
        case "set_network":
            return formatNetworkMode(value)
        case "target":
            return "Switch to target \"\(value)\""
        case "remember":
            return "Remember: \(value)"
        case "measure":
            return formatMeasure(value)
        default:
            // Unknown step — preserve as-is
            if value.isEmpty {
                return key
            }
            return "\(key): \"\(value)\""
        }
    }

    /// Format a press_key step value into natural language.
    /// Input: "return", "l+command", "escape"
    private static func formatPressKey(_ value: String) -> String {
        if value.contains("+") {
            let parts = value.split(separator: "+").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            let keyName = parts[0]
            let modifiers = Array(parts.dropFirst())
            let modStr = modifiers.map { formatModifier($0) }.joined(separator: "+")
            return "Press **\(modStr)+\(keyName.capitalized)**"
        }
        return "Press **\(value.capitalized)**"
    }

    /// Format a modifier name to its display form.
    private static func formatModifier(_ mod: String) -> String {
        switch mod.lowercased() {
        case "command": return "Cmd"
        case "shift": return "Shift"
        case "option": return "Option"
        case "control": return "Ctrl"
        default: return mod.capitalized
        }
    }

    /// Format a set_network mode to natural language.
    private static func formatNetworkMode(_ mode: String) -> String {
        switch mode {
        case "airplane_on": return "Turn on Airplane Mode"
        case "airplane_off": return "Turn off Airplane Mode"
        case "wifi_on": return "Turn on Wi-Fi"
        case "wifi_off": return "Turn off Wi-Fi"
        case "cellular_on": return "Turn on Cellular"
        case "cellular_off": return "Turn off Cellular"
        default: return "Set network: \(mode)"
        }
    }

    /// Format a measure step value into natural language.
    /// Input might be `{ tap: "Login", until: "Dashboard", max: 5, name: "login_time" }`
    private static func formatMeasure(_ value: String) -> String {
        var inner = value
        if inner.hasPrefix("{") && inner.hasSuffix("}") {
            inner = String(inner.dropFirst().dropLast())
        }

        let parts = inner.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        var action = ""
        var until = ""
        var maxSeconds = ""
        var name = ""

        for part in parts {
            guard let colonIdx = part.firstIndex(of: ":") else { continue }
            let key = String(part[part.startIndex..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            let val = SkillParser.stripQuotes(
                String(part[part.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces))

            switch key {
            case "until": until = val
            case "max": maxSeconds = val
            case "name": name = val
            default: action = "\(key) \"\(val)\""
            }
        }

        var result = "Measure"
        if !name.isEmpty { result += " (\(name))" }
        result += ": \(action)"
        if !until.isEmpty { result += " and wait for \"\(until)\"" }
        if !maxSeconds.isEmpty { result += " (max \(maxSeconds)s)" }
        return result
    }

    // MARK: - Output Path

    /// Resolve the output path for a migrated file.
    /// Same directory and stem name, but with `.md` extension.
    /// When `sourceBaseDir` is provided, preserves subdirectory structure relative to it
    /// inside `outputDir`. Without a base dir, places only the filename in `outputDir`.
    static func resolveOutputPath(
        yamlPath: String,
        outputDir: String?,
        sourceBaseDir: String? = nil
    ) -> String {
        if let outputDir = outputDir {
            // Compute relative path from the source base directory
            if let baseDir = sourceBaseDir {
                let prefix = baseDir.hasSuffix("/") ? baseDir : baseDir + "/"
                if yamlPath.hasPrefix(prefix) {
                    let relPath = String(yamlPath.dropFirst(prefix.count))
                    let relStem = (relPath as NSString).deletingPathExtension
                    return outputDir + "/" + relStem + ".md"
                }
            }
            // No base dir or path doesn't start with base — use filename only
            let stem = ((yamlPath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            return outputDir + "/" + stem + ".md"
        }

        // No output dir — place .md next to the source .yaml
        let dir = (yamlPath as NSString).deletingLastPathComponent
        let stem = ((yamlPath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        return dir + "/" + stem + ".md"
    }

    // MARK: - Argument Parsing

    struct MigrateConfig {
        let files: [String]
        let directory: String?
        let outputDir: String?
        let dryRun: Bool
        let showHelp: Bool
    }

    private static func parseArguments(_ args: [String]) -> MigrateConfig {
        var files: [String] = []
        var directory: String?
        var outputDir: String?
        var dryRun = false
        var showHelp = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--help", "-h":
                showHelp = true
            case "--dir":
                i += 1
                if i < args.count { directory = args[i] }
            case "--output-dir":
                i += 1
                if i < args.count { outputDir = args[i] }
            case "--dry-run":
                dryRun = true
            default:
                if !arg.hasPrefix("-") {
                    files.append(arg)
                }
            }
            i += 1
        }

        return MigrateConfig(
            files: files,
            directory: directory,
            outputDir: outputDir,
            dryRun: dryRun,
            showHelp: showHelp
        )
    }

    private static func printUsage() {
        let usage = """
        Usage: mirroir-mcp migrate [options] <file.yaml> [file2.yaml ...]

        Convert YAML skill files to SKILL.md format (YAML front matter + markdown).

        Arguments:
          <file.yaml>             One or more YAML files to convert

        Options:
          --dir <path>            Migrate all YAML files in a directory recursively
          --output-dir <path>     Write output files to this directory instead of next to source
          --dry-run               Print converted output without writing files
          --help, -h              Show this help

        Examples:
          mirroir-mcp migrate apps/settings/check-about.yaml
          mirroir-mcp migrate --dir ../iphone-mirroir-skills
          mirroir-mcp migrate --dry-run apps/mail/email-triage.yaml
        """
        fputs(usage + "\n", stderr)
    }
}
