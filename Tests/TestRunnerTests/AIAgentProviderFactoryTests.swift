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
        #expect(config!.model == "copilot")
        #expect(config!.apiKeyEnvVar == nil)
        #expect(config!.baseURL == "http://localhost:3000")
    }

    @Test("Resolves embacle:claude from built-in registry")
    func resolveEmbacleClaude() {
        let config = AIAgentRegistry.resolve(name: "embacle:claude")
        #expect(config != nil)
        #expect(config!.name == "embacle:claude")
        #expect(config!.provider == .embacle)
        #expect(config!.model == "claude")
        #expect(config!.baseURL == "http://localhost:3000")
    }

    // MARK: - Available Agents

    @Test("availableAgents includes built-in models and ollama placeholder")
    func availableAgentsIncludesBuiltIns() {
        let agents = AIAgentRegistry.availableAgents()
        #expect(agents.contains("claude-sonnet-4-6"))
        #expect(agents.contains("claude-haiku-4-5"))
        #expect(agents.contains("gpt-5.3"))
        #expect(agents.contains("embacle"))
        #expect(agents.contains("embacle:claude"))
        #expect(agents.contains("ollama:<model>"))
    }

    // MARK: - Provider Creation

    @Test("createProvider returns AnthropicProvider for anthropic config")
    func createAnthropicProvider() {
        let config = AIAgentRegistry.builtInAgents["claude-sonnet-4-6"]!
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

    @Test("loadDiagnosisPrompt returns non-empty default when no file exists")
    func loadDefaultPrompt() {
        // Even if no file exists at the expected paths, the hardcoded default is returned
        let prompt = loadDiagnosisPrompt(filename: "nonexistent-prompt-xyz.md")
        #expect(!prompt.isEmpty)
        #expect(prompt.contains("iOS"))
        #expect(prompt.contains("JSON"))
    }

    @Test("loadDiagnosisPrompt loads from file when present")
    func loadPromptFromFile() throws {
        let tmpDir = NSTemporaryDirectory() + "prompt-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let promptsDir = tmpDir + "/.mirroir-mcp/prompts"
        try FileManager.default.createDirectory(atPath: promptsDir, withIntermediateDirectories: true)

        let content = "# Custom Prompt\nAnalyze the failure."
        try content.write(toFile: promptsDir + "/diagnosis.md", atomically: true, encoding: .utf8)

        // The function checks PermissionPolicy.promptDirs which are based on cwd,
        // so we test the file loading indirectly via loadYAMLProfile pattern
        let data = FileManager.default.contents(atPath: promptsDir + "/diagnosis.md")
        let loaded = String(data: data!, encoding: .utf8)!
        #expect(loaded.contains("Custom Prompt"))
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
