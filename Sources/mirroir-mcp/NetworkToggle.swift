// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Toggles Airplane Mode, Wi-Fi or Cellular by opening iOS Settings and tapping the row.
// ABOUTME: Shared by the set_network tool and the set_network skill step; row labels are pattern data.

import Foundation
import HelperLib

/// The set_network procedure: open Settings, find the row the mode names on
/// screen, tap its label, then go back to the Home Screen whatever happened.
/// The row labels come from `system-phrases.md` (the iPhone's language is not
/// known to the Mac). The procedure reads no switch state: `_on` and `_off`
/// of one row tap the same label, and what that tap does on the phone (flip a
/// switch, or open the row's page) is decided by iOS, not checked here.
enum NetworkToggle {
    /// A `set_network` mode. It names the Settings row whose label is tapped.
    enum Mode: String, CaseIterable {
        case airplaneOn = "airplane_on", airplaneOff = "airplane_off"
        case wifiOn = "wifi_on", wifiOff = "wifi_off"
        case cellularOn = "cellular_on", cellularOff = "cellular_off"

        /// The `system-phrases.md` section listing this mode's Settings row.
        var rowSection: SystemPhrases.Section {
            switch self {
            case .airplaneOn, .airplaneOff: return .settingsAirplaneRow
            case .wifiOn, .wifiOff: return .settingsWiFiRow
            case .cellularOn, .cellularOff: return .settingsCellularRow
            }
        }

        /// Every mode's name, in declaration order.
        static var names: [String] { allCases.map(\.rawValue) }
    }

    /// The app the rows live in, as launch_app opens it.
    static let settingsAppName = "Settings"

    /// Toggle `mode`. Returns the success message or the failure to report.
    /// - Parameters:
    ///   - settleUs: How long to wait after the tap before going home.
    ///   - loadUs: How long Settings takes to load before its screen is read.
    ///   - phrases: Where the row labels come from; the shipped file by default.
    static func toggle(
        mode modeName: String, input: any InputProviding, describer: any ScreenDescribing,
        menuBridge: any MenuActionCapable, settleUs: UInt32,
        loadUs: UInt32 = EnvConfig.settingsLoadUs, phrases: SystemPhrases = .live
    ) -> Result<String, ToggleError> {
        guard let mode = Mode(rawValue: modeName) else {
            return .failure(ToggleError(
                "Unknown mode: \(modeName). Use: \(Mode.names.joined(separator: ", "))"))
        }
        if let error = input.launchApp(name: settingsAppName) {
            return .failure(ToggleError("Failed to launch \(settingsAppName): \(error)"))
        }
        usleep(loadUs)

        let outcome = tapRow(of: mode, input: input, describer: describer, phrases: phrases)
        if case .success = outcome { usleep(settleUs) }
        _ = menuBridge.triggerMenuAction(
            menu: MirroringMenuCommand.menu, item: MirroringMenuCommand.homeScreen.rawValue)
        return outcome.map { "Toggled \(mode.rawValue)" }
    }

    /// Find the first of the mode's row labels on the Settings screen and tap it.
    private static func tapRow(
        of mode: Mode, input: any InputProviding, describer: any ScreenDescribing,
        phrases: SystemPhrases
    ) -> Result<Void, ToggleError> {
        let labels = phrases.phrases(mode.rowSection)
        guard let screen = describer.describe() else {
            return .failure(ToggleError("Failed to capture \(settingsAppName) screen"))
        }
        let match = labels.lazy.compactMap {
            label in ElementMatcher.findMatch(label: label, in: screen.elements).map { (label, $0) }
        }.first
        guard let (label, found) = match else {
            let named = labels.map { "\"\($0)\"" }.joined(separator: " or ")
            return .failure(ToggleError("\(named.isEmpty ? "No row label" : named) not found in "
                + "\(settingsAppName) (system-phrases.md, \(mode.rowSection.rawValue))"))
        }
        if let error = input.tap(x: found.element.tapX, y: found.element.tapY) {
            return .failure(ToggleError("Failed to tap \(label): \(error)"))
        }
        return .success(())
    }

    /// Why a toggle failed, worded for the agent or the test report.
    struct ToggleError: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
