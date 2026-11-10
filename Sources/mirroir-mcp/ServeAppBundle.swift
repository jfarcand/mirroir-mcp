// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Builds the small app bundle the serve LaunchAgent runs, so macOS names it and shows an icon.
// ABOUTME: A copy of the binary, an Info.plist and the robot icon, sealed by one signature over the whole bundle.

import Foundation

/// The app bundle `install-agent` puts the serve agent in.
///
/// Under launchd no app runs `mirroir-mcp`, so macOS asks for Accessibility
/// and Screen Recording in the binary's own name. A bare executable is listed
/// in those panes, and in Background Items, as a generic "exec" icon with
/// "Item from unidentified developer". Inside a bundle it has a name, an icon
/// and a bundle identifier.
enum ServeAppBundle {

    /// The bundle's folder name, and the name the privacy panes show.
    static let displayName = "mirroir serve"

    /// The bundle identifier; the same string as the launchd label.
    static var identifier: String { InstallAgentCommand.label }

    /// The executable's name inside `Contents/MacOS`. Login Items lists a
    /// LaunchAgent by its executable's name, since a bundle signed without a
    /// developer team cannot claim the job, so it carries the display name.
    static var executableName: String { displayName }

    /// The icon's file name inside `Contents/Resources`, without its extension.
    static let iconName = "AppIcon"

    /// The bundle could not be built; the message says which step failed.
    struct BuildError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The executable launchd runs, inside the bundle at `bundlePath`.
    static func executablePath(in bundlePath: String) -> String {
        bundlePath + "/Contents/MacOS/" + executableName
    }

    /// The bundle's Info.plist. `LSUIElement` keeps it out of the Dock and
    /// the app switcher: it is a background agent, not an app to open.
    static func infoPlist(version: String) -> [String: Any] {
        [
            "CFBundleIdentifier": identifier,
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleExecutable": executableName,
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
    static func build(at bundlePath: String, executable: String, version: String,
                      sign: (String) -> String?) throws {
        let files = FileManager.default
        let parent = (bundlePath as NSString).deletingLastPathComponent
        let staging = parent + "/.\(displayName)-\(UUID().uuidString).app"
        defer { try? files.removeItem(atPath: staging) }
        do {
            try files.createDirectory(atPath: staging + "/Contents/MacOS", withIntermediateDirectories: true)
            try files.createDirectory(atPath: staging + "/Contents/Resources", withIntermediateDirectories: true)
            try files.copyItem(atPath: executable, toPath: executablePath(in: staging))
            let info = try PropertyListSerialization.data(
                fromPropertyList: infoPlist(version: version), format: .xml, options: 0)
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
