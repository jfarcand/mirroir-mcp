// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for AIAgentRegistry, agent resolution, YAML profile loading, and response parsing.
// ABOUTME: Covers built-in agents, ollama prefix, custom profiles, payload serialization, and AI response parsing.

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

    @Test("Resolves gpt-5.3 from built-in registry")
    func resolveGPT52() {
        let config = AIAgentRegistry.resolve(name: "gpt-5.3")
        #expect(config != nil)
        #expect(config!.provider == .openai)
        #expect(config!.model == "gpt-5.3")
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
            model: gpt-5.3
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

}
