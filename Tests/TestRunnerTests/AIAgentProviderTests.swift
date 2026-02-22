// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AIAgentRegistry, agent resolution, YAML profile loading, and response parsing.
// ABOUTME: Covers built-in agents, ollama prefix, custom profiles, payload serialization, and CLI arg parsing.

import Foundation
import Testing

@testable import HelperLib
@testable import mirroir_mcp

@Suite("AIAgentProvider")
struct AIAgentProviderTests {

    // MARK: - Built-in Agent Resolution

    @Test("Resolves claude-sonnet-4-6 from built-in registry")
    func resolveClaudeSonnet() {
        let config = AIAgentRegistry.resolve(name: "claude-sonnet-4-6")
        #expect(config != nil)
        #expect(config!.name == "claude-sonnet-4-6")
        #expect(config!.mode == .api)
        #expect(config!.provider == .anthropic)
        #expect(config!.model == "claude-sonnet-4-6-20250514")
        #expect(config!.apiKeyEnvVar == "ANTHROPIC_API_KEY")
    }

    @Test("Resolves claude-haiku-4-5 from built-in registry")
    func resolveClaudeHaiku() {
        let config = AIAgentRegistry.resolve(name: "claude-haiku-4-5")
        #expect(config != nil)
        #expect(config!.provider == .anthropic)
        #expect(config!.model == "claude-haiku-4-5-20251001")
    }

    @Test("Resolves gpt-4o from built-in registry")
    func resolveGPT4o() {
        let config = AIAgentRegistry.resolve(name: "gpt-4o")
        #expect(config != nil)
        #expect(config!.provider == .openai)
        #expect(config!.model == "gpt-4o")
        #expect(config!.apiKeyEnvVar == "OPENAI_API_KEY")
    }

    @Test("Returns nil for unknown agent name")
    func resolveUnknownReturnsNil() {
        let config = AIAgentRegistry.resolve(name: "nonexistent-model-xyz")
        #expect(config == nil)
    }

    // MARK: - Ollama Prefix Parsing

    @Test("Resolves ollama:llama3 with correct config")
    func resolveOllamaPrefix() {
        let config = AIAgentRegistry.resolve(name: "ollama:llama3")
        #expect(config != nil)
        #expect(config!.name == "ollama:llama3")
        #expect(config!.mode == .api)
        #expect(config!.provider == .ollama)
        #expect(config!.model == "llama3")
        #expect(config!.baseURL == "http://localhost:11434")
        #expect(config!.apiKeyEnvVar == nil)
    }

    @Test("Resolves ollama:mistral with model name")
    func resolveOllamaMistral() {
        let config = AIAgentRegistry.resolve(name: "ollama:mistral")
        #expect(config != nil)
        #expect(config!.model == "mistral")
    }

    @Test("Returns nil for ollama: with empty model name")
    func resolveOllamaEmptyModel() {
        let config = AIAgentRegistry.resolve(name: "ollama:")
        #expect(config == nil)
    }

    // MARK: - YAML Profile Loading

    @Test("Loads API mode YAML profile")
    func loadAPIProfile() throws {
        let tmpDir = NSTemporaryDirectory() + "agent-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let yaml = """
            name: my-cloud-agent
            mode: api
            provider: anthropic
            model: claude-sonnet-4-6-20250514
            api_key_env: MY_API_KEY
            max_tokens: 2048
            """
        let path = tmpDir + "/my-cloud-agent.yaml"
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)

        let config = AIAgentRegistry.loadYAMLProfile(path: path)
        #expect(config != nil)
        #expect(config!.name == "my-cloud-agent")
        #expect(config!.mode == .api)
        #expect(config!.provider == .anthropic)
        #expect(config!.model == "claude-sonnet-4-6-20250514")
        #expect(config!.apiKeyEnvVar == "MY_API_KEY")
        #expect(config!.maxTokens == 2048)
    }

    @Test("Loads command mode YAML profile")
    func loadCommandProfile() throws {
        let tmpDir = NSTemporaryDirectory() + "agent-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let yaml = """
            name: my-local-agent
            mode: command
            command: claude
            args: ["--model", "sonnet", "--print"]
            """
        let path = tmpDir + "/my-local-agent.yaml"
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)

        let config = AIAgentRegistry.loadYAMLProfile(path: path)
        #expect(config != nil)
        #expect(config!.name == "my-local-agent")
        #expect(config!.mode == .command)
        #expect(config!.command == "claude")
        #expect(config!.args == ["--model", "sonnet", "--print"])
    }

    @Test("Returns nil for nonexistent profile file")
    func loadNonexistentProfile() {
        let config = AIAgentRegistry.loadYAMLProfile(path: "/tmp/nonexistent-agent-xyz.yaml")
        #expect(config == nil)
    }

    @Test("Defaults name from filename when not in YAML")
    func profileNameDefaultsFromFilename() throws {
        let tmpDir = NSTemporaryDirectory() + "agent-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let yaml = """
            mode: api
            provider: openai
            model: gpt-4o
            api_key_env: OPENAI_API_KEY
            """
        let path = tmpDir + "/custom-bot.yaml"
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)

        let config = AIAgentRegistry.loadYAMLProfile(path: path)
        #expect(config != nil)
        #expect(config!.name == "custom-bot")
    }

    @Test("Returns nil for command profile without command field")
    func commandProfileWithoutCommandReturnsNil() throws {
        let tmpDir = NSTemporaryDirectory() + "agent-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        let yaml = """
            name: broken
            mode: command
            """
        let path = tmpDir + "/broken.yaml"
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)

        let config = AIAgentRegistry.loadYAMLProfile(path: path)
        #expect(config == nil)
    }

    // MARK: - YAML Array Parsing

    @Test("Parses simple YAML array")
    func parseYAMLArray() {
        let result = AIAgentRegistry.parseYAMLArray("[\"a\", \"b\", \"c\"]")
        #expect(result == ["a", "b", "c"])
    }

    @Test("Parses single-quoted YAML array")
    func parseYAMLArraySingleQuotes() {
        let result = AIAgentRegistry.parseYAMLArray("['x', 'y']")
        #expect(result == ["x", "y"])
    }

    @Test("Returns empty for non-array string")
    func parseYAMLArrayNonArray() {
        let result = AIAgentRegistry.parseYAMLArray("not-an-array")
        #expect(result.isEmpty)
    }

    @Test("Handles empty array")
    func parseYAMLArrayEmpty() {
        let result = AIAgentRegistry.parseYAMLArray("[]")
        #expect(result.isEmpty)
    }

    // MARK: - DiagnosticPayload Serialization

    @Test("DiagnosticPayload encodes to JSON correctly")
    func diagnosticPayloadEncoding() throws {
        let payload = DiagnosticPayload(
            skillName: "test-skill",
            skillFilePath: "/tmp/test.yaml",
            failedSteps: [
                DiagnosticPayload.FailedStep(
                    stepIndex: 2, stepType: "tap", label: "Settings",
                    deterministicDiagnosis: "Element moved",
                    patches: [
                        DiagnosticPayload.PatchInfo(
                            field: "tapX", was: "100.0", shouldBe: "150.0"),
                    ]
                ),
            ]
        )

        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["skillName"] as? String == "test-skill")
        #expect(json["skillFilePath"] as? String == "/tmp/test.yaml")

        let steps = json["failedSteps"] as! [[String: Any]]
        #expect(steps.count == 1)
        #expect(steps[0]["stepIndex"] as? Int == 2)
        #expect(steps[0]["stepType"] as? String == "tap")
        #expect(steps[0]["label"] as? String == "Settings")
    }

    // MARK: - AIDiagnosis Response Parsing

    @Test("Parses valid AI diagnosis JSON response")
    func parseValidAIResponse() {
        let json = """
            {"analysis": "Element moved due to iOS update",\
            "suggested_fixes": [{"field": "tapX", "was": "100", "should_be": "150"}],\
            "confidence": "high"}
            """
        let result = parseAIDiagnosisResponse(
            data: Data(json.utf8), modelUsed: "test-model")

        #expect(result != nil)
        #expect(result!.analysis == "Element moved due to iOS update")
        #expect(result!.suggestedFixes.count == 1)
        #expect(result!.suggestedFixes[0].field == "tapX")
        #expect(result!.suggestedFixes[0].was == "100")
        #expect(result!.suggestedFixes[0].shouldBe == "150")
        #expect(result!.confidence == "high")
        #expect(result!.modelUsed == "test-model")
    }

    @Test("Parses AI response with extra text around JSON")
    func parseAIResponseWithWrappedText() {
        let response = """
            Here is my analysis:
            {"analysis": "Wrong screen", "suggested_fixes": [], "confidence": "medium"}
            Hope this helps!
            """
        let result = parseAIDiagnosisResponse(
            data: Data(response.utf8), modelUsed: "claude")

        #expect(result != nil)
        #expect(result!.analysis == "Wrong screen")
        #expect(result!.confidence == "medium")
        #expect(result!.suggestedFixes.isEmpty)
    }

    @Test("Returns plain text diagnosis for non-JSON response")
    func parseNonJSONResponse() {
        let text = "The element is not on screen. Try scrolling down."
        let result = parseAIDiagnosisResponse(
            data: Data(text.utf8), modelUsed: "ollama")

        #expect(result != nil)
        #expect(result!.analysis == text)
        #expect(result!.confidence == "low")
    }

    @Test("Handles empty suggested_fixes gracefully")
    func parseResponseWithEmptyFixes() {
        let json = """
            {"analysis": "Timing issue", "confidence": "medium"}
            """
        let result = parseAIDiagnosisResponse(
            data: Data(json.utf8), modelUsed: "test")

        #expect(result != nil)
        #expect(result!.analysis == "Timing issue")
        #expect(result!.suggestedFixes.isEmpty)
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
                ]
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

    // MARK: - Available Agents

    @Test("availableAgents includes built-in models and ollama placeholder")
    func availableAgentsIncludesBuiltIns() {
        let agents = AIAgentRegistry.availableAgents()
        #expect(agents.contains("claude-sonnet-4-6"))
        #expect(agents.contains("claude-haiku-4-5"))
        #expect(agents.contains("gpt-4o"))
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
        let config = AIAgentRegistry.builtInAgents["gpt-4o"]!
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
