// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Entry point for the mirroir-mcp server.
// ABOUTME: Initializes subsystems and starts the JSON-RPC server loop over stdio.

import Darwin
import Foundation
import HelperLib

/// iPhone Mirroring capabilities for building the default target context.
private let iphoneMirroringCapabilities: Set<TargetCapability> = [
    .menuActions, .spotlight, .home, .appSwitcher,
]

@main
struct MirroirMCP {
    static func main() {
        // Ignore SIGPIPE so the server doesn't crash when the MCP client
        // disconnects or its stdio pipe closes unexpectedly.
        signal(SIGPIPE, SIG_IGN)

        // Parse CLI flags
        let args = CommandLine.arguments

        // Handle subcommands before MCP server initialization
        if args.count >= 2 && args[1] == "test" {
            let exitCode = TestRunner.run(arguments: Array(args.dropFirst(2)))
            Darwin.exit(exitCode)
        }
        if args.count >= 2 && args[1] == "record" {
            let exitCode = RecordCommand.run(arguments: Array(args.dropFirst(2)))
            Darwin.exit(exitCode)
        }
        if args.count >= 2 && args[1] == "compile" {
            let exitCode = CompileCommand.run(arguments: Array(args.dropFirst(2)))
            Darwin.exit(exitCode)
        }
        if args.count >= 2 && args[1] == "migrate" {
            let exitCode = MigrateCommand.run(arguments: Array(args.dropFirst(2)))
            Darwin.exit(exitCode)
        }
        if args.count >= 2 && args[1] == "doctor" {
            let exitCode = DoctorCommand.run(arguments: Array(args.dropFirst(2)))
            Darwin.exit(exitCode)
        }
        if args.count >= 2 && args[1] == "configure" {
            let exitCode = ConfigureCommand.run(arguments: Array(args.dropFirst(2)))
            Darwin.exit(exitCode)
        }
        let skipPermissions = PermissionPolicy.parseSkipPermissions(from: args)
        DebugLog.enabled = args.contains("--debug")
        DebugLog.reset()
        DebugLog.persist("startup", "version: \(GitVersion.commitHash)")
        if DebugLog.enabled {
            DebugLog.persist("startup", "Debug logging enabled (--debug)")
        }
        let config = PermissionPolicy.loadConfig()
        let policy = PermissionPolicy(skipPermissions: skipPermissions, config: config)

        // Log startup info to stderr and the log file (always persisted)
        if skipPermissions {
            DebugLog.persist("startup", "Permission mode: all tools enabled (--dangerously-skip-permissions)")
        } else if let cfg = config {
            DebugLog.persist("startup", "Permission mode: config-based (\(PermissionPolicy.configPath))")
            DebugLog.persist("startup", "  allow: \(cfg.allow ?? [])")
            DebugLog.persist("startup", "  deny: \(cfg.deny ?? [])")
            DebugLog.persist("startup", "  blockedApps: \(cfg.blockedApps ?? [])")
        } else {
            DebugLog.persist("startup", "Permission mode: fail-closed (readonly tools only)")
        }

        // Log denied and hidden tools so silent exclusions are visible
        let deniedTools = PermissionPolicy.mutatingTools.filter { tool in
            if case .denied = policy.checkTool(tool) { return true }
            return false
        }.sorted()
        let hiddenTools = PermissionPolicy.mutatingTools.filter { tool in
            !policy.isToolVisible(tool)
        }.sorted()

        if !deniedTools.isEmpty {
            DebugLog.persist("startup", "WARNING: denied tools: \(deniedTools)")
        }
        if !hiddenTools.isEmpty {
            DebugLog.persist("startup", "WARNING: hidden from tools/list: \(hiddenTools)")
        }

        // Log full effective configuration
        DebugLog.persist("config", "Effective configuration:\n\(EnvConfig.formattedConfigDump())")

        // Auto-initialize embedded embacle when the Rust FFI is linked.
        // Set agentTransport to "http" in settings.json to force HTTP even when linked.
        if EmbacleFFI.isAvailable && EnvConfig.agentTransport != "http" {
            guard EmbacleFFI.initialize() else {
                fputs("Error: Failed to initialize embedded embacle runtime\n", stderr)
                Darwin.exit(1)
            }
            DebugLog.persist("startup", "Agent transport: embedded (Rust FFI)")
        } else if EmbacleFFI.isAvailable {
            DebugLog.persist("startup", "Agent transport: HTTP (embedded available but overridden)")
        } else {
            DebugLog.persist("startup", "Agent transport: HTTP")
        }

        let registry = buildTargetRegistry()
        let server = MCPServer(policy: policy)

        // Log active targets
        let targetNames = registry.allTargetNames
        DebugLog.persist("startup", "Targets: \(targetNames) (active: \(registry.activeTargetName))")

        registerTools(server: server, registry: registry, policy: policy)

        // A touch, key, button or gesture left held would break input for the
        // whole Mac, so every way out of the server releases it.
        HeldInputReleaseOnExit.install()

        // Start the MCP server loop
        server.run()

        // stdin closed: the client is gone and nothing can end a held input.
        HeldInputReleaseOnExit.releaseAll(reason: "client disconnected", session: .shared,
                                          interruption: .shared)

        // Shutdown embedded embacle runtime if it was initialized
        if EmbacleFFI.isAvailable && EnvConfig.agentTransport != "http" {
            EmbacleFFI.shutdown()
        }
    }

    /// Build a TargetRegistry from targets.json or fall back to a single iPhone target.
    static func buildTargetRegistry() -> TargetRegistry {
        if let file = TargetConfigLoader.load(), !file.targets.isEmpty {
            return buildMultiTargetRegistry(configs: file.targets,
                                            defaultName: file.defaultTarget)
        }

        // Single-target fallback: no config file → default iPhone-Mirroring target.
        let ctx = IPhoneMirroringTarget.build(config: nil)
        return TargetRegistry(targets: ["iphone": ctx], defaultName: "iphone")
    }

    /// Build a TargetRegistry from multiple target configurations. Dispatches
    /// each entry to its self-contained target module via `TargetKind`.
    private static func buildMultiTargetRegistry(
        configs: [String: TargetConfig],
        defaultName: String?
    ) -> TargetRegistry {
        var targets = [String: TargetContext]()

        for (name, config) in configs {
            guard let ctx = TargetKind.build(config: config, name: name) else {
                DebugLog.log("TargetRegistry",
                    "Unknown target type '\(config.type)' for '\(name)' — skipped")
                continue
            }
            targets[name] = ctx
        }

        // Resolve default: use specified default if it exists, otherwise first alphabetical.
        let sortedNames = targets.keys.sorted()
        let resolvedDefault: String
        if let specified = defaultName, targets[specified] != nil {
            resolvedDefault = specified
        } else {
            if let specified = defaultName {
                DebugLog.log("TargetRegistry",
                    "Configured default '\(specified)' not found in targets \(sortedNames), "
                    + "falling back to '\(sortedNames.first ?? "")'")
            }
            resolvedDefault = sortedNames.first!  // Safe: configs was checked !isEmpty above
        }
        return TargetRegistry(targets: targets, defaultName: resolvedDefault)
    }

    /// Build the appropriate TextRecognizing backend based on configuration.
    ///
    /// - `"auto"` (default): Use both backends if a YOLO model is installed, vision only otherwise
    /// - `"vision"`: Apple Vision OCR only
    /// - `"yolo"`: YOLO CoreML element detection only (falls back to Vision if model unavailable)
    /// - `"both"`: Merge results from both backends
    static func buildTextRecognizer() -> any TextRecognizing {
        let backend = EnvConfig.ocrBackend

        switch backend {
        case "auto":
            if let modelURL = ModelDownloadManager.resolveModelURL() {
                DebugLog.persist("startup",
                    "OCR: auto-detected YOLO model, using Vision + YOLO")
                return CompositeTextRecognizer(backends: [
                    AppleVisionTextRecognizer(),
                    CoreMLElementDetector(
                        modelURL: modelURL,
                        confidenceThreshold: EnvConfig.yoloConfidenceThreshold
                    ),
                ])
            }
            DebugLog.persist("startup",
                "OCR: no YOLO model found, using Vision OCR only. "
                + "Install a .mlmodelc in \(ModelDownloadManager.modelsDirectory) "
                + "or set yoloModelPath to enable element detection.")
            return AppleVisionTextRecognizer()

        case "yolo":
            guard let modelURL = ModelDownloadManager.resolveModelURL() else {
                DebugLog.persist("startup", "YOLO model unavailable, falling back to Vision OCR")
                return AppleVisionTextRecognizer()
            }
            return CoreMLElementDetector(
                modelURL: modelURL,
                confidenceThreshold: EnvConfig.yoloConfidenceThreshold
            )

        case "both":
            var backends: [any TextRecognizing] = [AppleVisionTextRecognizer()]
            if let modelURL = ModelDownloadManager.resolveModelURL() {
                backends.append(CoreMLElementDetector(
                    modelURL: modelURL,
                    confidenceThreshold: EnvConfig.yoloConfidenceThreshold
                ))
            } else {
                DebugLog.persist("startup", "YOLO model unavailable, using Vision OCR only")
            }
            if backends.count == 1 {
                return backends[0]
            }
            return CompositeTextRecognizer(backends: backends)

        default:
            return AppleVisionTextRecognizer()
        }
    }

    /// Build the appropriate ScreenDescribing implementation based on configuration.
    /// "auto" (default) resolves to "ocr" for reliable coordinate accuracy.
    /// "vision" uses VisionScreenDescriber (AI vision model via configured agent).
    /// "ocr" forces local Vision OCR + YOLO regardless of embacle availability.
    static func buildDescriber(
        bridge: any WindowBridging,
        capture: any ScreenCapturing,
        isMobile: Bool
    ) -> any ScreenDescribing {
        let mode = EnvConfig.screenDescriberMode
        let useVision: Bool
        switch mode {
        case "vision":
            useVision = true
        case "auto":
            // Default to OCR — the vision path has known Y-coordinate bias
            // where bottom-of-screen elements are placed too high. Users who
            // want vision can set screenDescriberMode to "vision" explicitly.
            useVision = false
        default:
            useVision = false
        }

        if useVision {
            let agentName = EnvConfig.agent.isEmpty ? "embacle" : EnvConfig.agent
            if let agentConfig = AIAgentRegistry.resolve(name: agentName) {
                let resolvedFrom = "vision"
                DebugLog.persist("startup",
                    "Screen describer: \(resolvedFrom) (agent=\(agentName))")
                return VisionScreenDescriber(
                    bridge: bridge, capture: capture, agentConfig: agentConfig
                )
            }
            DebugLog.persist("startup",
                "Screen describer: vision requested but agent '\(EnvConfig.agent.isEmpty ? "embacle" : EnvConfig.agent)' not found, falling back to OCR")
        }
        let textRecognizer = buildTextRecognizer()
        return ScreenDescriber(
            bridge: bridge, capture: capture,
            textRecognizer: textRecognizer, isMobile: isMobile
        )
    }
}

