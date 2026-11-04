// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Runs a scene's external move picker: the scenario's command, argv split on whitespace, no shell.
// ABOUTME: One JSON object on stdin, one action on stdout; stopped when it outlasts the time it was given.

import Foundation

/// The move picker a scenario names with `decider:` (or `MIRROIR_SCENE_DECIDER`).
/// The command comes from the scenario the user wrote, never from a skill, so a
/// downloaded skill cannot make mirroir run a program.
struct CommandSceneDecider: SceneDeciding {
    let command: String
    private let argv: [String]

    /// A picker for `command`, or nil when it names no program.
    init?(command: String) {
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !words.isEmpty else { return nil }
        self.command = command
        self.argv = words
    }

    /// The program the command runs: an absolute path, or a name looked up on `PATH`.
    var program: String { argv[0] }

    /// Whether the program can be run: an executable file at an absolute path,
    /// or a name found executable on `PATH`.
    func isRunnable(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> Bool {
        let fileManager = FileManager.default
        if program.contains("/") { return fileManager.isExecutableFile(atPath: program) }
        return path.split(separator: ":").contains {
            fileManager.isExecutableFile(atPath: "\($0)/\(program)")
        }
    }

    func decide(input: Data, timeoutSeconds: Int) -> SceneDecisionOutcome {
        let process = Process()
        if program.contains("/") {
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = Array(argv.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Set before launch: a program that exits at once must still signal.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failed("cannot start \(program): \(error.localizedDescription)")
        }

        // Drain both pipes while the program runs, so a chatty one cannot block on a full pipe.
        let output = PipeCollector(stdoutPipe.fileHandleForReading)
        let errors = PipeCollector(stderrPipe.fileHandleForReading)
        // A picker that exits without reading stdin closes the pipe: the write
        // then fails (SIGPIPE is ignored process-wide), and its exit status decides.
        try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
        try? stdinPipe.fileHandleForWriting.close()

        if exited.wait(timeout: .now() + .seconds(max(1, timeoutSeconds))) == .timedOut {
            process.terminate()
            return .timedOut
        }
        let stdout = String(decoding: output.finish(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errors.finish(), as: UTF8.self)
            return .failed("\(program) exited \(process.terminationStatus): \(stderr.prefix(200))")
        }
        return .answered(stdout)
    }
}

/// Reads a pipe to its end on a background queue.
private final class PipeCollector: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global().async { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }

    /// The pipe's whole content, once its writer has closed it.
    func finish() -> Data {
        done.wait()
        return data
    }
}
