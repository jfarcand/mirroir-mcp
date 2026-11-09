// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The bearer token `mirroir-mcp serve` requires on every request: created once, read from a private file.
// ABOUTME: The file must be a regular file owned by the user and readable by nobody else, or the server refuses to start.

import Darwin
import Foundation
import HelperLib

/// The shared secret between `mirroir-mcp serve` and its client. Whoever holds
/// it controls the phone within what `permissions.json` allows, so it lives in
/// a file only its owner can read and is never printed or logged.
enum ServeToken {

    /// Shortest token accepted, in characters.
    static let minimumLength = 32

    /// Random bytes in a generated token; written as twice as many hex digits.
    static let generatedByteCount = 32

    /// Permission bits that give anyone but the owner access.
    static let groupAndOtherBits: mode_t = 0o077

    /// Permission bits that let anyone but the owner write.
    static let groupAndOtherWriteBits: mode_t = 0o022

    /// The permission bits of a file mode, without its type.
    static let permissionBits: mode_t = 0o777

    /// The mode a token file is created with.
    static let fileMode: mode_t = 0o600

    /// Why a token file was refused. Each description names the fix.
    enum LoadError: LocalizedError, Equatable {
        case missing(String)
        case notRegularFile(String)
        case wrongOwner(String)
        case permissionsTooOpen(String, mode: UInt16)
        case directoryTooOpen(String, mode: UInt16)
        case tooShort(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .missing(let path):
                return "No token file at \(path). Run `mirroir-mcp install-agent`, which creates it."
            case .notRegularFile(let path):
                return "\(path) is not a regular file."
            case .wrongOwner(let path):
                return "\(path) is not owned by you."
            case .permissionsTooOpen(let path, let mode):
                return "\(path) is readable by other users (mode \(String(mode, radix: 8))). "
                    + "Run: chmod 600 \(path)"
            case .directoryTooOpen(let directory, let mode):
                return "\(directory) can be changed by other users (mode \(String(mode, radix: 8))), so the "
                    + "token in it cannot be trusted. Run: chmod 700 \(directory)"
            case .tooShort(let path):
                return "\(path) holds fewer than \(ServeToken.minimumLength) characters."
            case .unreadable(let path):
                return "\(path) could not be read."
            }
        }
    }

    /// `~/.mirroir-mcp/serve-token`.
    static var defaultPath: String {
        PermissionPolicy.globalConfigDir + "/serve-token"
    }

    /// Read the token at `path`, refusing a file anyone else could have read or
    /// replaced: it must be a regular file (not a symlink), owned by this user,
    /// with no group or other permission bits, in a directory only this user
    /// can change. The file is opened once and both checked and read through
    /// that descriptor, so it cannot be swapped between the check and the read.
    ///
    /// - Throws: `LoadError` naming what is wrong with the file.
    static func load(path: String) throws -> String {
        let directory = (path as NSString).deletingLastPathComponent
        var directoryInfo = stat()
        if stat(directory, &directoryInfo) == 0 {
            let mode = directoryInfo.st_mode & permissionBits
            guard directoryInfo.st_uid == getuid(), mode & groupAndOtherWriteBits == 0 else {
                throw LoadError.directoryTooOpen(directory, mode: UInt16(mode))
            }
        }

        // O_NOFOLLOW refuses a symlink; O_NONBLOCK keeps a FIFO from hanging the open.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: throw LoadError.missing(path)
            case ELOOP: throw LoadError.notRegularFile(path)
            default: throw LoadError.unreadable(path)
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw LoadError.unreadable(path) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw LoadError.notRegularFile(path) }
        guard info.st_uid == getuid() else { throw LoadError.wrongOwner(path) }
        let permissions = info.st_mode & permissionBits
        guard permissions & groupAndOtherBits == 0 else {
            throw LoadError.permissionsTooOpen(path, mode: UInt16(permissions))
        }
        guard let contents = try? handle.readToEnd(),
              let text = String(data: contents, encoding: .utf8) else {
            throw LoadError.unreadable(path)
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= minimumLength else { throw LoadError.tooShort(path) }
        return token
    }

    /// Create a token file at `path` with a fresh random token, readable by its
    /// owner alone. An existing file is left untouched.
    ///
    /// - Returns: false when a file already exists there.
    /// - Throws: `CocoaError` when the directory or the file cannot be written.
    static func create(path: String) throws -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, fileMode)
        guard descriptor >= 0 else {
            if errno == EEXIST { return false }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data((generate() + "\n").utf8))
        return true
    }

    /// A fresh token: `generatedByteCount` random bytes as lower-case hex.
    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<generatedByteCount)
            .map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            .map { String($0, radix: 16).leftPadded(to: 2) }
            .joined()
    }

    /// Whether `presented` is the expected token. Every byte is compared
    /// whatever the outcome, so the time taken says nothing about where a
    /// wrong token first differs.
    static func matches(presented: String, expected: String) -> Bool {
        let given = Array(presented.utf8)
        let wanted = Array(expected.utf8)
        var difference = UInt8(given.count == wanted.count ? 0 : 1)
        for index in wanted.indices {
            difference |= wanted[index] ^ (index < given.count ? given[index] : 0)
        }
        return difference == 0
    }
}

private extension String {
    /// The string with leading zeros up to `width` characters.
    func leftPadded(to width: Int) -> String {
        String(repeating: "0", count: max(0, width - count)) + self
    }
}
