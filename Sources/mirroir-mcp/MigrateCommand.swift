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

    /// Parse arguments and run the migration. Returns exit code (0 = success,
    /// 1 = error, 2 = refused arguments).
    static func run(arguments: [String]) -> Int32 {
        let config: MigrateConfig
        do {
            config = try parseArguments(arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return CLIDispatch.usageExitCode
        }

        // Collect YAML files to migrate
        var yamlFiles: [String] = []

        if let dir = config.directory {
            let found = MirroirMCP.findYAMLFiles(in: dir)
            yamlFiles = found.map { dir + "/" + $0 }
        }

        yamlFiles.append(contentsOf: config.files)

        if yamlFiles.isEmpty {
            fputs("Error: no YAML file found in \(config.directory ?? "the given paths")\n", stderr)
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
        let steps = MigrateStepParser.extractRawSteps(from: lines)

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
            let convertedSteps = MigrateStepFormatter.convertSteps(steps, startNumber: 1, indent: 0)
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
    }

    /// Parse a `migrate` command line.
    ///
    /// - Throws: `CLIArgumentError` for an option this command does not know,
    ///   a `--dir` or `--output-dir` with no value, or no file and no `--dir`.
    static func parseArguments(_ args: [String]) throws -> MigrateConfig {
        var files: [String] = []
        var directory: String?
        var outputDir: String?
        var dryRun = false

        var i = 0
        func value(for flag: String) throws -> String {
            i += 1
            guard i < args.count, !args[i].hasPrefix("-") else {
                throw CLIArgumentError.missingValue(flag: flag)
            }
            return args[i]
        }

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--dir":
                directory = try value(for: arg)
            case "--output-dir":
                outputDir = try value(for: arg)
            case "--dry-run":
                dryRun = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIArgumentError.unknownOption(arg, command: "migrate")
                }
                files.append(arg)
            }
            i += 1
        }

        if files.isEmpty, directory == nil {
            throw CLIArgumentError.missingArgument("a YAML file or --dir <path>", command: "migrate")
        }
        return MigrateConfig(files: files, directory: directory, outputDir: outputDir, dryRun: dryRun)
    }

    /// The command's usage text.
    static var usage: String {
        """
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
    }
}
