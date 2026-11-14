// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: `mirroir-mcp bundle-app`: packages this binary as mirroir-mcp.app, signed ad hoc, plus the robot icon as a PNG.
// ABOUTME: mcpb/build-mcpb.sh runs it so the Claude extension ships the server inside a named bundle with an icon.

import Foundation

/// A parsed `bundle-app` command line.
struct BundleAppConfig: Equatable {
    /// Where the `.app` goes.
    let appPath: String
    /// Where the PNG icon goes, when one is asked for.
    let iconPath: String?
}

/// Builds the app bundle the Claude extension (.mcpb) ships the server in.
///
/// Claude starts an extension's server through a helper that disclaims
/// responsibility, so macOS lists the server itself in Privacy & Security. In
/// a bundle it is listed as "mirroir-mcp" with the robot icon instead of a bare
/// "exec". The bundle is built by the binary it wraps, from the same
/// `ServeAppBundle` and `ServeAppIcon` the serve agent uses.
///
/// Usage: `mirroir-mcp bundle-app --app <path.app> [--icon <path.png>]`
enum BundleAppCommand {

    /// The word after `mirroir-mcp`.
    static let commandName = "bundle-app"

    /// The PNG icon's size: the largest one the bundle's .icns carries.
    static var iconPixels: Int { ServeAppIcon.pixelSizes.max() ?? Int(ServeAppIcon.viewBox) }

    /// Signs ad hoc: a release built on CI has no developer identity, and the
    /// login-keychain certificate `install-agent` uses belongs to one Mac.
    static let adHocIdentity = "-"

    static var usage: String {
        """
        Usage: mirroir-mcp \(commandName) --app <path.app> [--icon <path.png>]

        Copies this binary into an app bundle named "\(ServeAppBundle.Spec.extensionServer.displayName)"
        (identifier \(ServeAppBundle.Spec.extensionServer.identifier)), with the robot icon, and signs
        it ad hoc. mcpb/build-mcpb.sh runs it to build the Claude extension, so
        System Settings lists the server by name and icon when it asks for
        Accessibility and Screen Recording.

        Options:
          --app <path>   Where to write the .app (replaced when present)
          --icon <path>  Also write the icon as a \(iconPixels)x\(iconPixels) PNG
          --help, -h     Show this help
        """
    }

    /// Parse a `bundle-app` command line.
    ///
    /// - Throws: `CLIArgumentError` for an unknown option, a missing value, a
    ///   missing `--app`, or an `--app` path that does not end in `.app`.
    static func parseArguments(_ args: [String]) throws -> BundleAppConfig {
        var appPath: String?
        var iconPath: String?
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--app", "--icon":
                i += 1
                guard i < args.count, !args[i].hasPrefix("-") else {
                    throw CLIArgumentError.missingValue(flag: arg)
                }
                if arg == "--app" { appPath = args[i] } else { iconPath = args[i] }
            default:
                throw CLIArguments.unrecognized(arg, command: commandName)
            }
            i += 1
        }
        guard let appPath else {
            throw CLIArgumentError.missingArgument("--app <path.app>", command: commandName)
        }
        guard appPath.hasSuffix(".app") else {
            throw CLIArgumentError.invalidValue(flag: "--app", value: appPath, expected: "a path ending in .app")
        }
        return BundleAppConfig(appPath: appPath, iconPath: iconPath)
    }

    static func run(arguments: [String]) -> Int32 {
        let config: BundleAppConfig
        do {
            config = try parseArguments(arguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return CLIDispatch.usageExitCode
        }
        do {
            try build(config: config, executable: InstallAgentCommand.invokedExecutablePath(),
                      version: MirroirVersion.current) {
                ServeSigningIdentity.sign($0, fingerprint: adHocIdentity)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return 1
        }
        print(config.appPath)
        return 0
    }

    /// Build the extension's bundle around `executable` and write the icon.
    ///
    /// - Parameter sign: signs the bundle at the path it is given; nil on success.
    /// - Throws: `ServeAppBundle.BuildError` or `ServeAppIcon.WriteError`.
    static func build(config: BundleAppConfig, executable: String, version: String,
                      sign: (String) -> String?) throws {
        let resolved = (executable as NSString).resolvingSymlinksInPath
        try ServeAppBundle.build(at: config.appPath, executable: resolved, version: version,
                                 spec: .extensionServer, sign: sign)
        if let iconPath = config.iconPath {
            try ServeAppIcon.writePNG(to: iconPath, pixels: iconPixels)
        }
    }
}
