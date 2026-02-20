// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: AI agent provider that launches a local CLI process for diagnosis.
// ABOUTME: Supports both stdin piping and ${PAYLOAD} arg substitution for CLI tools like claude/copilot.

import Foundation
import HelperLib

/// Local command-based AI agent provider.
/// Two modes depending on whether args contain `${PAYLOAD}`:
/// - **Arg substitution**: Replaces `${PAYLOAD}` in args with the JSON payload (for `claude -p`, `copilot -p`)
/// - **Stdin piping**: Pipes DiagnosticPayload JSON to stdin (for custom scripts)
struct CommandProvider: AIAgentProviding {
    let command: String
    let args: [String]
    let systemPrompt: String?

    private static var timeoutSeconds: Int { EnvConfig.commandTimeoutSeconds }
    private static let payloadPlaceholder = "${PAYLOAD}"

    func diagnose(payload: DiagnosticPayload) -> AIDiagnosis? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let payloadData = try? encoder.encode(payload),
              let payloadStr = String(data: payloadData, encoding: .utf8) else {
            return nil
        }

        // Determine if args use placeholder substitution or stdin piping
        let usesPlaceholder = args.contains { $0.contains(Self.payloadPlaceholder) }

        let resolvedArgs: [String]
        if usesPlaceholder {
            // Replace ${PAYLOAD} in each arg with the actual JSON payload
            resolvedArgs = args.map { arg in
                arg.replacingOccurrences(of: Self.payloadPlaceholder, with: payloadStr)
            }
        } else {
            resolvedArgs = args
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Resolve command path — absolute paths are used directly, otherwise use /usr/bin/env
        if command.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = resolvedArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + resolvedArgs
        }

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            fputs("Warning: AI agent command '\(command)' failed to launch: \(error.localizedDescription)\n", stderr)
            return nil
        }

        // Write payload to stdin only if not using arg substitution
        if !usesPlaceholder {
            stdinPipe.fileHandleForWriting.write(Data(payloadStr.utf8))
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // Wait for completion with timeout
        let deadline = DispatchTime.now() + .seconds(Self.timeoutSeconds)
        let waitGroup = DispatchGroup()
        waitGroup.enter()

        DispatchQueue.global().async {
            process.waitUntilExit()
            waitGroup.leave()
        }

        let waitResult = waitGroup.wait(timeout: deadline)
        if waitResult == .timedOut {
            process.terminate()
            fputs("Warning: AI agent command '\(command)' timed out after \(Self.timeoutSeconds)s\n", stderr)
            return nil
        }

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            fputs("Warning: AI agent command '\(command)' exited with status \(process.terminationStatus): \(stderrStr.prefix(200))\n", stderr)
            return nil
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard !outputData.isEmpty else {
            fputs("Warning: AI agent command '\(command)' produced no output\n", stderr)
            return nil
        }

        return parseAIDiagnosisResponse(data: outputData, modelUsed: command)
    }
}
