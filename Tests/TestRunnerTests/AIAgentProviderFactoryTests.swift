// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AIAgentProvider creation, embacle resolution, stub providers, and prompt loading.
// ABOUTME: Covers buildPayload, available agents, policy agent/prompt dirs, and CommandProvider payload substitution.

import Foundation
import Testing

@testable import HelperLib
@testable import mirroir_mcp

extension AIAgentProviderTests {

    // MARK: - Embacle Response Extraction

    @Test("Parses embacle OpenAI-format response via diagnosis pipeline")
    func embacleResponseExtraction() {
        // Embacle-server returns OpenAI-format; the diagnosis JSON is inside choices[0].message.content
        let diagnosisJSON = """
            {"analysis": "Button label changed after iOS update",\
            "suggested_fixes": [{"field": "label", "was": "Settings", "should_be": "Réglages"}],\
            "confidence": "high"}
            """
        let result = parseAIDiagnosisResponse(
            data: Data(diagnosisJSON.utf8), modelUsed: "embacle:copilot")

        #expect(result != nil)
        #expect(result!.analysis == "Button label changed after iOS update")
        #expect(result!.suggestedFixes.count == 1)
        #expect(result!.suggestedFixes[0].field == "label")
        #expect(result!.suggestedFixes[0].was == "Settings")
        #expect(result!.suggestedFixes[0].shouldBe == "Réglages")
        #expect(result!.confidence == "high")
        #expect(result!.modelUsed == "embacle:copilot")
    }

    // MARK: - StubAIProvider

    @Test("StubAIProvider returns configured diagnosis")
    func stubProviderReturnsDiagnosis() {
        let stub = StubAIProvider()
        stub.diagnosisResult = AIDiagnosis(
            analysis: "Test analysis",
            suggestedFixes: [],
            confidence: "high",
            modelUsed: "stub")

        let payload = DiagnosticPayload(
            skillName: "test", skillFilePath: "/tmp/t.yaml", failedSteps: [])

        let result = stub.diagnose(payload: payload)
        #expect(result != nil)
        #expect(result!.analysis == "Test analysis")
        #expect(stub.lastPayload != nil)
        #expect(stub.lastPayload!.skillName == "test")
    }

    @Test("StubAIProvider returns nil when no result configured")
    func stubProviderReturnsNil() {
        let stub = StubAIProvider()
        let payload = DiagnosticPayload(
            skillName: "test", skillFilePath: "/tmp/t.yaml", failedSteps: [])

        let result = stub.diagnose(payload: payload)
        #expect(result == nil)
    }

    // MARK: - Agent buildPayload

    @Test("buildPayload converts recommendations to DiagnosticPayload")
    func buildPayloadFromRecommendations() {
        let recs = [
            AgentDiagnostic.Recommendation(
                stepIndex: 0, stepType: "tap", label: "Wi-Fi",
                diagnosis: "Element moved",
                patches: [
                    AgentDiagnostic.Patch(field: "tapX", was: "50.0", shouldBe: "75.0"),
                ],
                screenshotBase64: nil
            ),
        ]

        let payload = AgentDiagnostic.buildPayload(
            recommendations: recs,
            skillName: "settings-test",
            skillFilePath: "/tmp/settings.yaml")

        #expect(payload.skillName == "settings-test")
        #expect(payload.skillFilePath == "/tmp/settings.yaml")
        #expect(payload.failedSteps.count == 1)
        #expect(payload.failedSteps[0].stepIndex == 0)
        #expect(payload.failedSteps[0].stepType == "tap")
        #expect(payload.failedSteps[0].label == "Wi-Fi")
        #expect(payload.failedSteps[0].deterministicDiagnosis == "Element moved")
        #expect(payload.failedSteps[0].patches.count == 1)
        #expect(payload.failedSteps[0].patches[0].field == "tapX")
    }

    // MARK: - Embacle Resolution

    @Test("Resolves embacle from built-in registry")
    func resolveEmbacle() {
        let config = AIAgentRegistry.resolve(name: "embacle")
        #expect(config != nil)
        #expect(config!.name == "embacle")
        #expect(config!.mode == .api)
        #expect(config!.provider == .embacle)
        #expect(config!.model == defaultAgentModel)
        #expect(config!.apiKeyEnvVar == nil)
        #expect(config!.baseURL == "http://localhost:3000")
    }

    @Test("Resolves embacle:claude from built-in registry")
    func resolveEmbacleClaude() {
        let config = AIAgentRegistry.resolve(name: "embacle:claude")
        #expect(config != nil)
        #expect(config!.name == "embacle:claude")
        #expect(config!.provider == .embacle)
        #expect(config!.model == "claude:sonnet")
        #expect(config!.baseURL == "http://localhost:3000")
    }

    @Test("Default agent model is a concrete model id, not an embacle provider alias")
    func defaultAgentModelIsNotProviderAlias() {
        // embacle maps these aliases to its own catalog default (an Opus model)
        // instead of the model mirroir means to run.
        #expect(!["copilot", "copilot_headless", "claude"].contains(defaultAgentModel))
        #expect(defaultAgentModel == "claude-sonnet-5.5")
    }

    @Test("Embedded model follows the built-in embacle agent when the runner is on")
    func embeddedAgentModelForBuiltInEmbacle() {
        let config = AIAgentRegistry.builtInAgents["embacle"]
        #expect(AIAgentRegistry.embeddedAgentModel(
            config: config, embeddedRunnerEnabled: true) == defaultAgentModel)
        #expect(AIAgentRegistry.embeddedAgentModel(
            config: config, embeddedRunnerEnabled: false) == nil)
    }

    @Test("No embedded model for agents the embedded runner does not serve")
    func embeddedAgentModelNilForHTTPAgents() {
        for name in ["embacle:claude", "claude-opus-5-5", "gpt-5.3", "ollama:llama3"] {
            let config = AIAgentRegistry.resolve(name: name)
            #expect(config != nil, "\(name) should resolve")
            #expect(AIAgentRegistry.embeddedAgentModel(
                config: config, embeddedRunnerEnabled: true) == nil, "\(name)")
        }
        #expect(AIAgentRegistry.embeddedAgentModel(config: nil, embeddedRunnerEnabled: true) == nil)
    }

    // MARK: - Available Agents

    @Test("availableAgents includes built-in models and ollama placeholder")
    func availableAgentsIncludesBuiltIns() {
        let agents = AIAgentRegistry.availableAgents()
        #expect(agents.contains("claude-opus-5-5"))
        #expect(agents.contains("claude-sonnet-5-5"))
        #expect(agents.contains("claude-haiku-5-5"))
        #expect(agents.contains("gpt-5.3"))
        #expect(agents.contains("embacle"))
        #expect(agents.contains("embacle:claude"))
        #expect(agents.contains("ollama:<model>"))
    }

    // MARK: - Provider Creation

    @Test("createProvider returns AnthropicProvider for anthropic config")
    func createAnthropicProvider() {
        let config = AIAgentRegistry.builtInAgents["claude-opus-5-5"]!
        let provider = AIAgentRegistry.createProvider(config: config)
        #expect(provider != nil)
        #expect(provider is AnthropicProvider)
    }

    @Test("createProvider returns OpenAIProvider for openai config")
    func createOpenAIProvider() {
        let config = AIAgentRegistry.builtInAgents["gpt-5.3"]!
        let provider = AIAgentRegistry.createProvider(config: config)
        #expect(provider != nil)
        #expect(provider is OpenAIProvider)
    }

    @Test("createProvider returns OllamaProvider for ollama config")
    func createOllamaProvider() {
        let config = AIAgentRegistry.resolve(name: "ollama:llama3")!
        let provider = AIAgentRegistry.createProvider(config: config)
        #expect(provider != nil)
        #expect(provider is OllamaProvider)
    }

    @Test("createProvider returns EmbacleProvider for embacle config")
    func createEmbacleProvider() {
        let config = AIAgentRegistry.builtInAgents["embacle"]!
        let provider = AIAgentRegistry.createProvider(config: config)
        #expect(provider != nil)
        #expect(provider is EmbacleProvider)
    }

    @Test("createProvider returns CommandProvider for command config")
    func createCommandProvider() throws {
        let tmpDir = NSTemporaryDirectory() + "agent-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let yaml = """
            name: test-cmd
            mode: command
            command: echo
            args: ["hello"]
            """
        let path = tmpDir + "/test-cmd.yaml"
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)

        let config = AIAgentRegistry.loadYAMLProfile(path: path)!
        let provider = AIAgentRegistry.createProvider(config: config)
        #expect(provider != nil)
        #expect(provider is CommandProvider)
    }

    // MARK: - PermissionPolicy agentDirs and promptDirs

    @Test("agentDirs returns local and global directories")
    func agentDirsReturnsDirectories() {
        let dirs = PermissionPolicy.agentDirs
        #expect(dirs.count == 2)
        #expect(dirs[0].contains(".mirroir-mcp/agents"))
        #expect(dirs[1].contains(".mirroir-mcp/agents"))
    }

    @Test("promptDirs returns local and global directories")
    func promptDirsReturnsDirectories() {
        let dirs = PermissionPolicy.promptDirs
        #expect(dirs.count == 2)
        #expect(dirs[0].contains(".mirroir-mcp/prompts"))
        #expect(dirs[1].contains(".mirroir-mcp/prompts"))
    }

    // MARK: - Prompt Loading

    @Test("loadSystemPrompt returns the built-in when no override file exists")
    func loadDefaultPrompt() {
        let prompt = loadSystemPrompt(searchDirs: [makeTempPromptDir()])
        #expect(prompt == aiDiagnosisDefaultPrompt)
    }

    @Test("built-in diagnosis prompt describes every DiagnosticPayload field and the response keys")
    func diagnosisPromptMatchesPayload() {
        let prompt = aiDiagnosisDefaultPrompt
        #expect(!prompt.isEmpty)
        for field in ["skillName", "skillFilePath", "failedSteps", "stepIndex", "stepType",
                      "label", "deterministicDiagnosis", "patches", "shouldBe",
                      "analysis", "suggested_fixes", "should_be", "confidence"] {
            #expect(prompt.contains(field), "diagnosis prompt is missing \(field)")
        }
    }

    @Test("built-in vision prompt names the label/x/y/type keys VisionResponseParser reads")
    func visionPromptNamesParserKeys() {
        let prompt = VisionScreenDescriber.defaultSystemPrompt
        #expect(!prompt.isEmpty)
        for key in ["\"label\"", "\"x\"", "\"y\"", "\"type\""] {
            #expect(prompt.contains(key), "vision prompt is missing \(key)")
        }
    }

    @Test("loadSystemPrompt prefers an override file over the built-in")
    func loadPromptFromFile() throws {
        let localDir = makeTempPromptDir()
        let globalDir = makeTempPromptDir()
        defer {
            try? FileManager.default.removeItem(atPath: localDir)
            try? FileManager.default.removeItem(atPath: globalDir)
        }
        try FileManager.default.createDirectory(atPath: globalDir, withIntermediateDirectories: true)
        try "# Global Prompt".write(
            toFile: globalDir + "/" + SystemPromptFile.diagnosis.rawValue, atomically: true, encoding: .utf8)

        let globalOnly = loadSystemPrompt(searchDirs: [localDir, globalDir])
        #expect(globalOnly == "# Global Prompt")

        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        try "# Local Prompt".write(
            toFile: localDir + "/" + SystemPromptFile.diagnosis.rawValue, atomically: true, encoding: .utf8)

        let both = loadSystemPrompt(searchDirs: [localDir, globalDir])
        #expect(both == "# Local Prompt")
    }

    @Test("loadSystemPrompt ignores a whitespace-only override file")
    func loadPromptIgnoresEmptyFile() throws {
        let dir = makeTempPromptDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let filename = SystemPromptFile.screenDescribe.rawValue
        try "  \n".write(toFile: dir + "/" + filename, atomically: true, encoding: .utf8)

        let prompt = loadSystemPrompt(.screenDescribe, searchDirs: [dir])
        #expect(prompt == VisionScreenDescriber.defaultSystemPrompt)
    }

    @Test("Each overridable prompt file names a distinct .md file with a non-empty built-in")
    func systemPromptRegistryIsConsistent() {
        let names = SystemPromptFile.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        for file in SystemPromptFile.allCases {
            #expect(file.rawValue.hasSuffix(".md"))
            #expect(!file.builtIn.isEmpty)
        }
        #expect(SystemPromptFile.diagnosis.builtIn == aiDiagnosisDefaultPrompt)
        #expect(SystemPromptFile.screenDescribe.builtIn == VisionScreenDescriber.defaultSystemPrompt)
    }

    /// A unique, not-yet-created prompt directory under the system temp dir.
    private func makeTempPromptDir() -> String {
        NSTemporaryDirectory() + "prompt-test-\(UUID().uuidString)"
    }

    // MARK: - CommandProvider ${PAYLOAD} substitution

    @Test("YAML profile with ${PAYLOAD} in args is detected")
    func payloadPlaceholderInArgs() throws {
        let tmpDir = NSTemporaryDirectory() + "agent-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let yaml = """
            name: test-cmd
            mode: command
            command: echo
            args: ["-p", "Analyze: ${PAYLOAD}"]
            """
        let path = tmpDir + "/test-cmd.yaml"
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)

        let config = AIAgentRegistry.loadYAMLProfile(path: path)!
        #expect(config.args != nil)
        #expect(config.args!.contains { $0.contains("${PAYLOAD}") })
    }
}
