// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Builds the small app bundles mirroir-mcp runs in (the serve LaunchAgent, the Claude extension) so macOS names them.
// ABOUTME: A copy of the binary, an Info.plist and the robot icon, sealed by one signature over the whole bundle.

import Foundation

/// The app bundles mirroir-mcp runs in when it answers for itself.
///
/// Under launchd, or started by Claude through its disclaiming helper, no
/// app is responsible for `mirroir-mcp`, so macOS asks for Accessibility and
/// Screen Recording in the binary's own name. A bare executable is listed in
/// those panes, and in Background Items, as a generic "exec" icon with "Item
/// from unidentified developer". Inside a bundle it has a name, an icon and a
/// bundle identifier.
enum ServeAppBundle {

    /// The names one bundle carries.
    struct Spec: Equatable {
        /// The bundle's folder name, and the name the privacy panes show.
        let displayName: String
        /// The bundle identifier, which macOS keys the grants to.
        let identifier: String
        /// The executable's name inside `Contents/MacOS`.
        let executableName: String

        /// The serve LaunchAgent's bundle. Its identifier is the launchd
        /// label. Login Items lists a LaunchAgent by its executable's name,
        /// since a bundle signed without a developer team cannot claim the
        /// job, so the executable carries the display name.
        static var serve: Spec {
            Spec(displayName: "mirroir serve", identifier: InstallAgentCommand.label,
                 executableName: "mirroir serve")
        }

        /// The bundle the Claude extension (.mcpb) ships the server in. Claude
        /// starts it as its own responsible process, so the panes list it under
        /// this name; the identifier differs from the serve agent's so the two
        /// signatures never claim one TCC identity.
        static let extensionServer = Spec(displayName: "mirroir-mcp", identifier: "dev.mirroir.mcp",
                                          executableName: "mirroir-mcp")
    }

    /// The serve agent's display name, which the privacy panes show.
    static var displayName: String { Spec.serve.displayName }

    /// The serve agent's bundle identifier.
    static var identifier: String { Spec.serve.identifier }

    /// The icon's file name inside `Contents/Resources`, without its extension.
    static let iconName = "AppIcon"

    /// The bundle could not be built; the message says which step failed.
    struct BuildError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The executable inside the bundle at `bundlePath`.
    static func executablePath(in bundlePath: String, spec: Spec = .serve) -> String {
        bundlePath + "/Contents/MacOS/" + spec.executableName
    }

    /// The bundle's Info.plist. `LSUIElement` keeps it out of the Dock and
    /// the app switcher: it is a background server, not an app to open.
    static func infoPlist(version: String, spec: Spec = .serve) -> [String: Any] {
        [
            "CFBundleIdentifier": spec.identifier,
            "CFBundleName": spec.displayName,
            "CFBundleDisplayName": spec.displayName,
            "CFBundleExecutable": spec.executableName,
            "CFBundleIconFile": iconName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSUIElement": true,
        ]
    }

    /// Build the bundle at `bundlePath` around a copy of `executable`,
    /// replacing one already there, and sign it with `sign`.
    ///
    /// The bundle is assembled next to its final place and moved in only once
    /// it is signed, so a failed build leaves the previous bundle as it was.
    ///
    /// - Parameter sign: signs the bundle at the path it is given; returns
    ///   nil on success or the signer's message.
    /// - Throws: `BuildError` naming the step that failed.
    static func build(at bundlePath: String, executable: String, version: String, spec: Spec = .serve,
                      sign: (String) -> String?) throws {
        let files = FileManager.default
        let parent = (bundlePath as NSString).deletingLastPathComponent
        let staging = parent + "/.\(spec.displayName)-\(UUID().uuidString).app"
        defer { try? files.removeItem(atPath: staging) }
        do {
            try files.createDirectory(atPath: staging + "/Contents/MacOS", withIntermediateDirectories: true)
            try files.createDirectory(atPath: staging + "/Contents/Resources", withIntermediateDirectories: true)
            try files.copyItem(atPath: executable, toPath: executablePath(in: staging, spec: spec))
            let info = try PropertyListSerialization.data(
                fromPropertyList: infoPlist(version: version, spec: spec), format: .xml, options: 0)
            try info.write(to: URL(fileURLWithPath: staging + "/Contents/Info.plist"))
            try ServeAppIcon.writeICNS(to: staging + "/Contents/Resources/\(iconName).icns")
        } catch {
            throw BuildError(message: "the app bundle could not be built: \(error.localizedDescription)")
        }
        if let failure = sign(staging) {
            throw BuildError(message: "the app bundle could not be signed: \(failure)")
        }
        do {
            if files.fileExists(atPath: bundlePath) {
                _ = try files.replaceItemAt(URL(fileURLWithPath: bundlePath),
                                            withItemAt: URL(fileURLWithPath: staging))
            } else {
                try files.moveItem(atPath: staging, toPath: bundlePath)
            }
        } catch {
            throw BuildError(message: "the app bundle could not be moved into \(bundlePath): "
                             + error.localizedDescription)
        }
    }
}
