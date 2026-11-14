// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Speech-to-text on the Mac with SpeechAnalyzer (macOS 26): SpeechTranscriber where macOS offers it, else dictation.
// ABOUTME: Downloads a language's model the first time it is asked for; earlier macOS versions get a clear refusal.

import AVFoundation
import Foundation
import Speech

/// Production `SpeechTranscribing`.
///
/// Two on-device engines share the SpeechAnalyzer framework. `SpeechTranscriber`
/// is the newer, more accurate one, but macOS does not offer it everywhere:
/// measured on GitHub's macOS 26 runner, a virtual machine, `isAvailable` is
/// false while `DictationTranscriber` is installed. `.automatic` takes the first
/// where macOS has it and the second otherwise; the reply names the engine.
///
/// Measured on macOS 26.5: 15 s of spoken Québec French transcribed in 0.5 s
/// once the model was installed; installing the French model took about 9 s.
/// No Speech Recognition prompt appears: the analyzer runs on the Mac.
struct OnDeviceTranscriber: Sendable {

    /// Which on-device engine transcribes.
    enum Engine: String, Sendable {
        /// `SpeechTranscriber` when macOS offers it, dictation otherwise.
        case automatic
        /// `SpeechTranscriber` only.
        case speech
        /// `DictationTranscriber` only.
        case dictation
    }

    /// How long a transcription, model download included, may take.
    static let timeout: TimeInterval = 180

    /// Why there is no transcriber on this Mac or in this build.
    static let unavailableReason = "listening needs macOS 26 or later, whose on-device speech recognizer "
        + "transcribes without sending the audio anywhere, and a mirroir-mcp built with the macOS 26 SDK"

    let engine: Engine

    /// Whether this Mac and this build offer `SpeechTranscriber`, the engine
    /// `.automatic` prefers; false before macOS 26, in a build made with an
    /// older SDK, and where macOS withholds it (virtual machines).
    static var speechEngineAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        #endif
        return false
    }

    init(engine: Engine = .automatic) {
        self.engine = engine
    }

    func transcribe(file: URL, language: String) -> TranscriptionReply {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *) else { return .unavailable(Self.unavailableReason) }
        let done = DispatchSemaphore(value: 0)
        let box = TranscriptionBox()
        let engine = self.engine
        Task.detached {
            box.set(await Self.run(file: file, language: language, engine: engine))
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.timeout) == .success else {
            return .failed("transcription did not finish within \(Int(Self.timeout)) s")
        }
        return box.value ?? .failed("the transcriber gave no answer")
        #else
        // Built with an SDK older than macOS 26, which has no SpeechAnalyzer.
        return .unavailable(Self.unavailableReason)
        #endif
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func run(file: URL, language: String, engine: Engine) async -> TranscriptionReply {
        let useSpeech: Bool
        switch engine {
        case .speech:
            guard SpeechTranscriber.isAvailable else {
                return .unavailable("this Mac does not offer SpeechTranscriber")
            }
            useSpeech = true
        case .dictation: useSpeech = false
        case .automatic: useSpeech = speechEngineAvailable
        }
        let wanted = Locale(identifier: language)
        do {
            if useSpeech {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
                    return .unsupportedLanguage(language)
                }
                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                    reportingOptions: [], attributeOptions: [])
                let text = try await analyze(file: file, locale: locale, module: transcriber,
                                             results: transcriber.results.map { String($0.text.characters) })
                return .text(text, language: locale.identifier(.bcp47), engine: "speech")
            }
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) else {
                return .unsupportedLanguage(language)
            }
            let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
            let text = try await analyze(file: file, locale: locale, module: transcriber,
                                         results: transcriber.results.map { String($0.text.characters) })
            return .text(text, language: locale.identifier(.bcp47), engine: "dictation")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Install the module's model when it is not installed yet, run the file
    /// through it, and join what `results` yields.
    @available(macOS 26.0, *)
    private static func analyze<Results: AsyncSequence & Sendable>(
        file: URL, locale: Locale, module: any SpeechModule, results: Results
    ) async throws -> String where Results.Element == String {
        try await installIfNeeded(module, locale: locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        let audio = try AVAudioFile(forReading: file)
        let collect = Task { () throws -> [String] in
            var parts: [String] = []
            for try await part in results { parts.append(part) }
            return parts
        }
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        return try await collect.value.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reserve and install `module`'s model for `locale`, unless it is already
    /// installed: then nothing is reserved or requested. Measured 2026-11-12
    /// from the XR's listen calls: asked without this check, every call logged
    /// an install for fr-CA.
    @available(macOS 26.0, *)
    private static func installIfNeeded(_ module: any SpeechModule, locale: Locale) async throws {
        let tag = locale.identifier(.bcp47)
        guard await AssetInventory.status(forModules: [module]) != .installed else { return }
        try await reserve(locale)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            DebugLog.log("listen", "installing the on-device speech model for \(tag)")
            try await install.downloadAndInstall()
        }
    }

    /// Reserve `locale`'s speech model for this app. macOS downloads a model
    /// only for a reserved locale, and an app holds at most
    /// `AssetInventory.maximumReservedLocales`; past that the oldest
    /// reservation is released, so its model may need downloading again later.
    @available(macOS 26.0, *)
    private static func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        let tag = locale.identifier(.bcp47)
        guard !reserved.contains(where: { $0.identifier(.bcp47) == tag }) else { return }
        if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            DebugLog.log("listen", "releasing the speech model reservation for \(oldest.identifier(.bcp47))")
            await AssetInventory.release(reservedLocale: oldest)
        }
        try await AssetInventory.reserve(locale: locale)
    }
    #endif
}

/// The reply handed from the transcription task to the waiting thread.
private final class TranscriptionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TranscriptionReply?

    var value: TranscriptionReply? { lock.withLock { stored } }

    func set(_ reply: TranscriptionReply) { lock.withLock { stored = reply } }
}
