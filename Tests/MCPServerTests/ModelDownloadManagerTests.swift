/*
 * Copyright 2026 Async-IO.org
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
// ABOUTME: Tests for ModelDownloadManager path resolution and error handling.
// ABOUTME: No network calls — validates local path logic, cache lookup, and failure modes.

import Foundation
import HelperLib
import Testing
@testable import mirroir_mcp

@Suite("ModelDownloadManager")
struct ModelDownloadManagerTests {

    @Test("Models directory is under global config")
    func testModelsDirectoryPath() {
        let modelsDir = ModelDownloadManager.modelsDirectory
        #expect(modelsDir.contains(".mirroir-mcp/models"))
    }

    @Test("Resolve with non-existent explicit path returns nil")
    func testResolveWithInvalidPathReturnsNil() {
        // When yoloModelPath points to a non-existent file, resolveModelURL
        // cannot return it. We test the findCachedModel helper directly since
        // resolveModelURL reads from EnvConfig (singleton).
        let result = ModelDownloadManager.findCachedModel(in: "/tmp/nonexistent-models-dir")
        #expect(result == nil)
    }

    @Test("Find cached model returns nil for empty directory")
    func testFindCachedModelEmptyDir() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirroir-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = ModelDownloadManager.findCachedModel(in: tempDir.path)
        #expect(result == nil)
    }

    @Test("Find cached model returns mlmodelc directory")
    func testFindCachedModelReturnsMlmodelc() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirroir-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a fake .mlmodelc directory
        let fakeModelDir = tempDir.appendingPathComponent("model.mlmodelc")
        try FileManager.default.createDirectory(at: fakeModelDir, withIntermediateDirectories: true)

        let result = ModelDownloadManager.findCachedModel(in: tempDir.path)
        #expect(result != nil)
        #expect(result?.pathExtension == "mlmodelc")
    }

    @Test("Find cached model ignores non-mlmodelc files")
    func testFindCachedModelIgnoresOtherFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirroir-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create non-model files
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("readme.txt").path,
            contents: Data("test".utf8)
        )
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("model.mlmodel").path,
            contents: Data("test".utf8)
        )

        let result = ModelDownloadManager.findCachedModel(in: tempDir.path)
        #expect(result == nil)
    }

    @Test("Ensure models directory creates the directory")
    func testEnsureModelsDirectory() {
        // Just verify it doesn't crash. The directory may already exist.
        ModelDownloadManager.ensureModelsDirectory()
        let exists = FileManager.default.fileExists(atPath: ModelDownloadManager.modelsDirectory)
        #expect(exists)
    }

    @Test("Compile model fails gracefully for invalid input")
    func testCompileModelFailsGracefully() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirroir-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a fake .mlmodel file (not a valid model)
        let fakeModel = tempDir.appendingPathComponent("fake.mlmodel")
        FileManager.default.createFile(
            atPath: fakeModel.path,
            contents: Data("not a real model".utf8)
        )

        let result = ModelDownloadManager.compileModel(at: fakeModel)
        #expect(result == nil, "Should return nil for invalid model file")
    }
}
