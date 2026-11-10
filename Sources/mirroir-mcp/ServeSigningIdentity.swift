// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The self-signed code-signing identity install-agent signs the serve bundle with, kept in the login keychain.
// ABOUTME: macOS ties the bundle's privacy grants to this certificate, so they survive every reinstall of a new build.

import Foundation

/// The certificate the serve agent's bundle is signed with.
///
/// macOS keys an Accessibility or Screen Recording grant to the code
/// requirement of the app it was given to. For an ad-hoc signature that
/// requirement is the build's hash, so every upgrade loses both grants. For a
/// certificate it is `identifier "dev.mirroir.serve" and certificate leaf =
/// H"<sha1>"`, which every build signed with the same certificate meets.
/// Measured on macOS 26.5: grants given once held across a rebuild.
///
/// The certificate is self-signed and never trusted system-wide; codesign
/// signs with it anyway, and the privacy grants need nothing more.
enum ServeSigningIdentity {

    /// The certificate's common name, which finds it again on the next install.
    static let commonName = "mirroir serve local signing"

    /// Years the certificate is valid. After that codesign still signs, but a
    /// fresh certificate would cost the grants once, so it is made long.
    static let validityDays = 3650

    /// The keychain the identity lives in.
    static var loginKeychain: String { NSHomeDirectory() + "/Library/Keychains/login.keychain-db" }

    /// The identity could not be found, made or used; the message says which step failed.
    struct SigningError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The SHA-1 of the identity named `commonName` in a
    /// `security find-identity -p codesigning` listing, or nil when absent.
    ///
    /// Untrusted identities are listed too, flagged `CSSMERR_TP_NOT_TRUSTED`;
    /// a self-signed one always is.
    static func fingerprint(inListing listing: String) -> String? {
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, fields[0].hasSuffix(")"),
                  line.contains("\"\(commonName)\"") else { continue }
            let hash = String(fields[1])
            if hash.count == 40, hash.allSatisfy(\.isHexDigit) { return hash }
        }
        return nil
    }

    /// Whether `codesign -dv` output describes an ad-hoc signature.
    static func isAdHoc(codesignDetails details: String) -> Bool {
        details.split(separator: "\n").contains { $0 == "Signature=adhoc" }
    }

    /// Whether the bundle at `bundlePath` is signed ad hoc. False when it is
    /// absent or not signed at all.
    static func isAdHocSigned(_ bundlePath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: bundlePath),
              let result = try? run("/usr/bin/codesign", ["-dv", bundlePath]),
              result.status == 0 else { return false }
        return isAdHoc(codesignDetails: result.errors)
    }

    /// The identity in `keychain`, made and imported first when there is none.
    ///
    /// The import lets `/usr/bin/codesign` use the key. macOS still asks once,
    /// the first time codesign signs with it; "Always Allow" ends the prompts.
    ///
    /// - Returns: the identity's SHA-1, which `codesign --sign` takes.
    /// - Throws: `SigningError` naming the step that failed.
    static func ensure(keychain: String = loginKeychain) throws -> String {
        if let existing = try find(in: keychain) { return existing }
        try create(in: keychain)
        guard let made = try find(in: keychain) else {
            throw SigningError(message: "the signing certificate was imported but codesign does not list it")
        }
        return made
    }

    /// Sign the bundle at `bundlePath` with the identity `fingerprint`, which
    /// seals the Info.plist and the icon together with the executable.
    ///
    /// - Returns: nil on success, or codesign's message.
    static func sign(_ bundlePath: String, fingerprint: String) -> String? {
        do {
            let result = try run("/usr/bin/codesign", ["--force", "--sign", fingerprint, bundlePath])
            return result.status == 0 ? nil : result.errors
        } catch {
            return error.localizedDescription
        }
    }

    /// Sign the bundle at `bundlePath` with the login keychain's identity,
    /// making it first when there is none: the signer `install-agent` uses.
    ///
    /// - Returns: nil on success, or the message of the step that failed.
    static func signWithLocalIdentity(_ bundlePath: String) -> String? {
        do {
            return sign(bundlePath, fingerprint: try ensure())
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Steps

    private static func find(in keychain: String) throws -> String? {
        let result = try run("/usr/bin/security", ["find-identity", "-p", "codesigning", keychain])
        guard result.status == 0 else {
            throw SigningError(message: "the keychain \(keychain) could not be read: \(result.errors)")
        }
        return fingerprint(inListing: result.output)
    }

    /// The OpenSSL extensions that make the certificate a code-signing one.
    static let certificateConfig = """
        [req]
        distinguished_name = dn
        prompt = no
        x509_extensions = ext
        [dn]
        CN = \(commonName)
        [ext]
        basicConstraints = critical,CA:false
        keyUsage = critical,digitalSignature
        extendedKeyUsage = critical,codeSigning
        """

    /// Make the key and certificate in a private temporary folder, bundle them
    /// as PKCS#12 and import that. The folder, private key included, is
    /// deleted whatever happens; only the keychain keeps the key.
    private static func create(in keychain: String) throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("mirroir-signing-\(UUID().uuidString)").path
        try files.createDirectory(atPath: folder, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(atPath: folder) }

        let transfer = UUID().uuidString
        let identity = try makePKCS12(in: folder, password: transfer)
        try step("the signing certificate could not be added to \(keychain)", "/usr/bin/security", [
            "import", identity, "-k", keychain, "-P", transfer, "-T", "/usr/bin/codesign"])
    }

    /// Make a key and a self-signed code-signing certificate in `folder`
    /// and bundle them, protected by `password`, as PKCS#12.
    ///
    /// - Returns: the PKCS#12 file's path, inside `folder`.
    static func makePKCS12(in folder: String, password: String) throws -> String {
        try certificateConfig.write(toFile: folder + "/cert.cnf", atomically: true, encoding: .utf8)
        // macOS's own LibreSSL writes PKCS#12 that `security import` reads;
        // newer OpenSSL defaults to ciphers it refuses.
        let openssl = "/usr/bin/openssl"
        try step("the signing certificate could not be made", openssl, [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", folder + "/key.pem", "-out", folder + "/cert.pem",
            "-days", String(validityDays), "-config", folder + "/cert.cnf"])
        let identity = folder + "/identity.p12"
        try step("the signing certificate could not be packaged", openssl, [
            "pkcs12", "-export", "-inkey", folder + "/key.pem", "-in", folder + "/cert.pem",
            "-out", identity, "-passout", "pass:" + password])
        return identity
    }

    private static func step(_ failure: String, _ tool: String, _ arguments: [String]) throws {
        let result = try run(tool, arguments)
        guard result.status == 0 else { throw SigningError(message: "\(failure): \(result.errors)") }
    }

    private struct RunResult {
        let status: Int32
        let output: String
        let errors: String
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // Errors go to a file, so the tool never stalls on a second full pipe
        // while the output one is drained.
        let errorPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirroir-signing-\(UUID().uuidString).err").path
        guard FileManager.default.createFile(atPath: errorPath, contents: nil),
              let errors = FileHandle(forWritingAtPath: errorPath) else {
            throw SigningError(message: "\(tool) could not be started: no file for its errors")
        }
        defer {
            try? errors.close()
            try? FileManager.default.removeItem(atPath: errorPath)
        }
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw SigningError(message: "\(tool) could not be started: \(error.localizedDescription)")
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorData = FileManager.default.contents(atPath: errorPath) ?? Data()
        return RunResult(status: process.terminationStatus,
                         output: String(decoding: outputData, as: UTF8.self),
                         errors: String(decoding: errorData, as: UTF8.self)
                             .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
