// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Downloads, compiles, and caches YOLO CoreML models for element detection.
// ABOUTME: Resolves model URL from local path override, cache directory, or remote download.

import CoreML
import Foundation
import HelperLib

/// Resolves a compiled CoreML model (.mlmodelc) URL for the YOLO element detector.
///
/// Resolution order:
/// 1. `EnvConfig.yoloModelPath` — explicit local path (if set and exists)
/// 2. Cached model in `~/.mirroir-mcp/models/` — previously downloaded and compiled
/// 3. `EnvConfig.yoloModelURL` — download, compile if needed, and cache
///
/// All errors are logged via `DebugLog` and result in `nil` (graceful fallback).
enum ModelDownloadManager {

    /// Directory for cached compiled models.
    static var modelsDirectory: String {
        PermissionPolicy.globalConfigDir + "/models"
    }

    /// Resolve the YOLO model URL, downloading and compiling if necessary.
    ///
    /// - Returns: URL to a compiled `.mlmodelc` directory, or `nil` if unavailable.
    static func resolveModelURL() -> URL? {
        // 1. Explicit local path override
        let explicitPath = EnvConfig.yoloModelPath
        if !explicitPath.isEmpty {
            let url = URL(fileURLWithPath: (explicitPath as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                DebugLog.log("YOLO", "Using explicit model path: \(url.path)")
                return url
            }
            DebugLog.persist("YOLO", "Explicit model path does not exist: \(explicitPath)")
            return nil
        }

        // 2. Check cache directory for an existing compiled model
        let modelsDir = modelsDirectory
        if let cachedURL = findCachedModel(in: modelsDir) {
            DebugLog.log("YOLO", "Using cached model: \(cachedURL.lastPathComponent)")
            return cachedURL
        }

        // 3. Download from URL
        let remoteURL = EnvConfig.yoloModelURL
        guard !remoteURL.isEmpty, let sourceURL = URL(string: remoteURL) else {
            return nil
        }

        DebugLog.persist("YOLO", "Downloading model from \(remoteURL)...")
        ensureModelsDirectory()

        let fileName = sourceURL.lastPathComponent
        let downloadDest = URL(fileURLWithPath: modelsDir).appendingPathComponent(fileName)

        guard downloadModel(from: sourceURL, to: downloadDest) else {
            return nil
        }

        // If downloaded file is already a .mlmodelc directory, use it directly
        if downloadDest.pathExtension == "mlmodelc" {
            DebugLog.persist("YOLO", "Model ready: \(downloadDest.lastPathComponent)")
            return downloadDest
        }

        // Otherwise compile the .mlmodel to .mlmodelc
        return compileModel(at: downloadDest)
    }

    // MARK: - Internal Helpers

    /// Find an existing `.mlmodelc` directory in the models cache.
    static func findCachedModel(in directory: String) -> URL? {
        let dirURL = URL(fileURLWithPath: directory)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        return contents.first { $0.pathExtension == "mlmodelc" }
    }

    /// Download a file synchronously from a remote URL.
    ///
    /// - Returns: `true` if download succeeded and file was saved.
    static func downloadModel(from source: URL, to destination: URL) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        // Safe: semaphore.wait() below guarantees the closure completes before we read.
        nonisolated(unsafe) var success = false

        let task = URLSession.shared.downloadTask(with: source) { tempURL, response, error in
            defer { semaphore.signal() }

            if let error = error {
                DebugLog.persist("YOLO", "Download failed: \(error.localizedDescription)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                DebugLog.persist("YOLO", "Download failed with HTTP \(code)")
                return
            }

            guard let tempURL = tempURL else {
                DebugLog.persist("YOLO", "Download returned no file")
                return
            }

            do {
                // Remove existing file if present to avoid copy errors
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                success = true
            } catch {
                DebugLog.persist("YOLO", "Failed to save downloaded model: \(error.localizedDescription)")
            }
        }
        task.resume()
        semaphore.wait()

        return success
    }

    /// Compile a `.mlmodel` file into a `.mlmodelc` directory and save it to the models cache.
    ///
    /// - Returns: URL to the compiled `.mlmodelc`, or `nil` on failure.
    static func compileModel(at sourceURL: URL) -> URL? {
        do {
            let compiledURL = try MLModel.compileModel(at: sourceURL)
            let destURL = URL(fileURLWithPath: modelsDirectory)
                .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + ".mlmodelc")

            // Move compiled model from temp location to cache
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: compiledURL, to: destURL)

            // Clean up the temporary compiled model
            try? FileManager.default.removeItem(at: compiledURL)

            // Clean up the source .mlmodel since we have the compiled version
            try? FileManager.default.removeItem(at: sourceURL)

            DebugLog.persist("YOLO", "Model compiled: \(destURL.lastPathComponent)")
            return destURL
        } catch {
            DebugLog.persist("YOLO", "Model compilation failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Create the models cache directory if it doesn't exist.
    static func ensureModelsDirectory() {
        try? FileManager.default.createDirectory(
            atPath: modelsDirectory,
            withIntermediateDirectories: true
        )
    }
}
