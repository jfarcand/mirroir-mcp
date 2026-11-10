// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for the serve bundle's signing identity: finding it in a codesign listing, spotting ad-hoc bundles,
// ABOUTME: and the certificate the real /usr/bin/openssl makes. No keychain is read or written.

import XCTest
@testable import mirroir_mcp

final class ServeSigningIdentityTests: XCTestCase {

    private var directory = ""

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "serve-signing-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
    }

    /// The listing as `security find-identity -p codesigning` printed it on macOS 26.5.
    func testTheIdentityIsFoundByNameEvenWhenUntrusted() {
        let listing = """

            Policy: Code Signing
              Matching identities
              1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: someone (TEAM)"
              2) 91FD01A720597F438EF2BF529764A3B6CCF1CFD8 "mirroir serve local signing" (CSSMERR_TP_NOT_TRUSTED)
                 2 identities found

              Valid identities only
              1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: someone (TEAM)"
                 1 valid identities found
            """
        XCTAssertEqual(ServeSigningIdentity.fingerprint(inListing: listing),
                       "91FD01A720597F438EF2BF529764A3B6CCF1CFD8")
    }

    func testAnotherIdentityOrNoneIsNotTaken() {
        XCTAssertNil(ServeSigningIdentity.fingerprint(inListing: """
              1) 0123456789ABCDEF0123456789ABCDEF01234567 "mirroir serve local signing copy"
                 1 identities found
            """))
        XCTAssertNil(ServeSigningIdentity.fingerprint(inListing: "     0 identities found\n"))
    }

    func testAdHocIsReadFromTheSignatureLine() {
        XCTAssertTrue(ServeSigningIdentity.isAdHoc(codesignDetails: "Identifier=dev.mirroir.serve\nSignature=adhoc\n"))
        XCTAssertFalse(ServeSigningIdentity.isAdHoc(
            codesignDetails: "Identifier=dev.mirroir.serve\nAuthority=mirroir serve local signing\nSignature size=1234\n"))
    }

    func testAnAbsentOrUnsignedBundleIsNotAdHoc() throws {
        XCTAssertFalse(ServeSigningIdentity.isAdHocSigned(directory + "/absent.app"))
        let unsigned = directory + "/plain"
        try Data("not code".utf8).write(to: URL(fileURLWithPath: unsigned))
        XCTAssertFalse(ServeSigningIdentity.isAdHocSigned(unsigned))
    }

    /// The real openssl makes a code-signing certificate under the expected name,
    /// packaged so the password given opens it.
    func testTheCertificateIsACodeSigningOneUnderItsName() throws {
        let identity = try ServeSigningIdentity.makePKCS12(in: directory, password: "transfer")
        let certificate = Process()
        certificate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        certificate.arguments = ["x509", "-in", directory + "/cert.pem", "-noout", "-text"]
        let output = Pipe()
        certificate.standardOutput = output
        try certificate.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        certificate.waitUntilExit()
        XCTAssertEqual(certificate.terminationStatus, 0)
        XCTAssertTrue(text.contains(ServeSigningIdentity.commonName), text)
        XCTAssertTrue(text.contains("Code Signing"), text)

        let opened = Process()
        opened.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        opened.arguments = ["pkcs12", "-in", identity, "-passin", "pass:transfer", "-noout"]
        try opened.run()
        opened.waitUntilExit()
        XCTAssertEqual(opened.terminationStatus, 0)
    }
}
