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
// ABOUTME: Sets Airplane Mode, Wi-Fi or Cellular in iOS Settings by reading its switch, then tapping it only if needed.
// ABOUTME: Shared by the set_network tool and the set_network skill step; row labels are pattern data.

import CoreGraphics
import Foundation
import HelperLib

/// The set_network procedure: open Settings, find the switch the mode names
/// (Airplane Mode on the first page; Wi-Fi and cellular data on the page their
/// row opens), read it, and tap it only when it is not already in the asked
/// state; read it again after the tap and report what it shows. Labels come
/// from `system-phrases.md` (the iPhone's language is not known to the Mac).
/// A switch that cannot be read, or reads differently twice, is never
/// tapped. Turning Airplane Mode on or Wi-Fi off can cut iPhone Mirroring's
/// connection, after which nothing here can turn it back.
///
/// When iPhone Mirroring gives Control Center (macOS 27 with an iPhone on
/// iOS 27), the switch is its connectivity tile instead and Settings is not
/// opened (`ControlCenterNetwork`); Mirroring refuses Control Center to an
/// older iPhone, which then goes through Settings. Both paths read, tap only
/// when needed, and read again the same way (`apply`).
enum NetworkToggle {

    /// A `set_network` mode: which switch, and the state asked for.
    enum Mode: String, CaseIterable {
        case airplaneOn = "airplane_on", airplaneOff = "airplane_off"
        case wifiOn = "wifi_on", wifiOff = "wifi_off"
        case cellularOn = "cellular_on", cellularOff = "cellular_off"

        /// The state the switch is asked to be in.
        var wantsOn: Bool { [.airplaneOn, .wifiOn, .cellularOn].contains(self) }

        /// What the switch is called in results.
        var switchName: String {
            switch self {
            case .airplaneOn, .airplaneOff: return "Airplane Mode"
            case .wifiOn, .wifiOff: return "Wi-Fi"
            case .cellularOn, .cellularOff: return "cellular data"
            }
        }

        /// The first-page row: the switch itself for Airplane Mode, the row
        /// opening the switch's page for the others.
        var rowSection: SystemPhrases.Section {
            switch self {
            case .airplaneOn, .airplaneOff: return .settingsAirplaneRow
            case .wifiOn, .wifiOff: return .settingsWiFiRow
            case .cellularOn, .cellularOff: return .settingsCellularRow
            }
        }

        /// The switch row on the page `rowSection` opens; nil when the row
        /// itself holds the switch.
        var switchSection: SystemPhrases.Section? {
            switch self {
            case .airplaneOn, .airplaneOff: return nil
            case .wifiOn, .wifiOff: return .settingsWiFiSwitch
            case .cellularOn, .cellularOff: return .settingsCellularSwitch
            }
        }

        /// The mode's tile on Control Center's connectivity page.
        var controlCenterTile: SystemPhrases.Section {
            switch self {
            case .airplaneOn, .airplaneOff: return .controlCenterAirplaneTile
            case .wifiOn, .wifiOff: return .controlCenterWiFiTile
            case .cellularOn, .cellularOff: return .controlCenterCellularTile
            }
        }

        /// Whether the asked state can cut iPhone Mirroring's connection.
        var cutsMirroring: Bool { self == .airplaneOn || self == .wifiOff }

        /// Every mode's name, in declaration order.
        static var names: [String] { allCases.map(\.rawValue) }
    }

    /// Reads the switch on the row at a y, from one screen read.
    typealias SwitchRead = @Sendable (ScreenDescriber.DescribeResult, Double, CGSize) -> SettingsSwitchReader.Reading

    /// The live reader: the screen read's own screenshot.
    static let pixelRead: SwitchRead = { screen, rowY, size in
        SettingsSwitchReader.read(rowY: rowY, pngBase64: screen.screenshotBase64, windowSize: size)
    }

    /// The app the permission policy checks before Settings is opened
    /// (`blockedApps` names it in English whatever the phone's language).
    static let settingsAppName = "Settings"

    /// Back taps tried to reach Settings' first page when it reopens on a sub-page.
    static let maxBackSteps = 3

    /// Set `mode`. Returns the result to report or the failure.
    /// - Parameters:
    ///   - settleUs: How long to wait after the switch tap before reading it
    ///     again, and between reads while it has not changed yet.
    ///   - changeTimeoutUs: How long the tapped control may take to read the
    ///     asked state.
    ///   - loadUs: How long Settings or a page takes to load before it is read.
    ///   - phrases: Where the labels come from; the shipped file by default.
    ///   - read: Reads a row's switch; the screenshot's pixels by default.
    ///   - settingsRefusal: Why the Settings app may not be opened (the
    ///     permission policy), checked only when the Settings path is taken.
    ///   - controlCenterDescriber: Reads Control Center's tiles; `describer` by
    ///     default. The configured describer: a vision model reads the faint
    ///     state lines OCR can miss. `describer` (OCR) locates the icon to tap.
    static func toggle(
        mode modeName: String, input: any InputProviding, describer: any ScreenDescribing,
        controlCenterDescriber: (any ScreenDescribing)? = nil,
        menuBridge: any MenuActionCapable, settleUs: UInt32,
        changeTimeoutUs: UInt32 = EnvConfig.networkChangeTimeoutUs,
        loadUs: UInt32 = EnvConfig.settingsLoadUs, phrases: SystemPhrases = .live,
        read: @escaping SwitchRead = pixelRead,
        settingsRefusal: () -> String? = { nil }
    ) -> Result<String, ToggleError> {
        guard let mode = Mode(rawValue: modeName) else {
            return .failure(ToggleError(
                "Unknown mode: \(modeName). Use: \(Mode.names.joined(separator: ", "))"))
        }
        guard let size = menuBridge.getWindowInfo()?.size else {
            return .failure(ToggleError("The '\(menuBridge.targetName)' window is not available"))
        }
        let outcome: Result<String, ToggleError>
        let tileDescriber = controlCenterDescriber ?? describer
        switch ControlCenterNetwork.open(menuBridge: menuBridge, input: input, describer: tileDescriber,
                                         size: size, loadUs: loadUs, phrases: phrases) {
        case .opened:
            outcome = controlCenterSet(mode: mode, input: input, describer: tileDescriber,
                                       locator: describer, size: size,
                                       settleUs: settleUs, changeTimeoutUs: changeTimeoutUs,
                                       phrases: phrases)
        case .failed(let reason):
            outcome = .failure(ToggleError(reason))
        case .unavailable(let reason):
            DebugLog.log("set_network", "Control Center unavailable (\(reason)); using Settings")
            if let refusal = settingsRefusal() { return .failure(ToggleError(refusal)) }
            let session = Session(mode: mode, input: input, describer: describer, size: size,
                                  settleUs: settleUs, changeTimeoutUs: changeTimeoutUs,
                                  loadUs: loadUs, phrases: phrases, read: read)
            outcome = session.run()
        }
        _ = menuBridge.triggerMenuAction(
            menu: MirroringMenuCommand.menu, item: MirroringMenuCommand.homeScreen.rawValue)
        return outcome
    }

    /// One run of the procedure.
    private struct Session {
        let mode: Mode
        let input: any InputProviding
        let describer: any ScreenDescribing
        let size: CGSize
        let settleUs: UInt32
        let changeTimeoutUs: UInt32
        let loadUs: UInt32
        let phrases: SystemPhrases
        let read: SwitchRead

        func run() -> Result<String, ToggleError> {
            if let error = openSettings() { return .failure(error) }
            guard let row = firstPageRow() else {
                let named = phrases.phrases(mode.rowSection).map { "\"\($0)\"" }.joined(separator: " or ")
                return .failure(ToggleError("\(named.isEmpty ? "No row label" : named) not found in Settings "
                    + "(system-phrases.md, \(mode.rowSection.rawValue)). Nothing was tapped."))
            }
            var switchLabels = phrases.phrases(mode.rowSection)
            if let switchSection = mode.switchSection {
                if let error = input.tap(x: row.tapX, y: row.tapY) {
                    return .failure(ToggleError("Failed to open the \(mode.switchName) page: \(error)"))
                }
                usleep(loadUs)
                switchLabels = phrases.phrases(switchSection)
            }
            return setSwitch(labels: switchLabels)
        }

        /// Open Settings under the first of its names that launches.
        private func openSettings() -> ToggleError? {
            var errors: [String] = []
            for name in phrases.phrases(.settingsApp) {
                let displayName = name.prefix(1).uppercased() + name.dropFirst()
                guard let error = input.launchApp(name: displayName) else {
                    usleep(loadUs)
                    return nil
                }
                errors.append("\(displayName): \(error)")
            }
            return ToggleError("Failed to launch Settings (" + errors.joined(separator: "; ") + ")")
        }

        /// The mode's row on Settings' first page, going back when Settings
        /// reopened on a page it was left on.
        private func firstPageRow() -> TapPoint? {
            for step in 0 ... maxBackSteps {
                guard let screen = describer.describe() else { return nil }
                if let row = labelled(phrases.phrases(mode.rowSection), in: screen.elements).first {
                    return row
                }
                guard step < maxBackSteps else { return nil }
                ExplorerUtilities.tapBackButton(elements: screen.elements, input: input, windowSize: size)
                usleep(loadUs)
            }
            return nil
        }

        /// Read the switch beside one of `labels`, twice; tap it if it is not
        /// in the asked state, then read it again.
        private func setSwitch(labels: [String]) -> Result<String, ToggleError> {
            NetworkToggle.apply(
                mode: mode, control: "switch", settleUs: settleUs, changeTimeoutUs: changeTimeoutUs,
                notFound: "No \(mode.switchName) switch was found: the row is a menu on "
                    + "this iPhone (with two SIMs, cellular data is), or the switch could not be read "
                    + "(only the light appearance is measured). Nothing was tapped.",
                read: { switchRow(labels: labels)?.reading },
                tap: { input.tap(x: $0.x, y: $0.y) })
        }

        /// The first row labelled with one of `labels` whose switch reads.
        private func switchRow(labels: [String]) -> (label: TapPoint, reading: SettingsSwitchReader.Reading)? {
            guard let screen = describer.describe() else { return nil }
            for label in labelled(labels, in: screen.elements) {
                let reading = read(screen, label.tapY, size)
                if reading.state != .none { return (label, reading) }
            }
            return nil
        }

        /// The elements whose text is one of `labels` or starts with one, in
        /// screen order.
        private func labelled(_ labels: [String], in elements: [TapPoint]) -> [TapPoint] {
            elements.filter { element in
                let text = SystemPhrases.fold(element.text).trimmingCharacters(in: .whitespaces)
                return labels.contains { text == $0 || text.hasPrefix($0 + " ") }
            }
        }

    }

    /// Set `mode` on Control Center's connectivity page, already open: the
    /// state is read there with `describer`, and the tile's icon is tapped
    /// there, placed from `locator`'s OCR text (`ControlCenterNetwork.tapIcon`).
    private static func controlCenterSet(
        mode: Mode, input: any InputProviding, describer: any ScreenDescribing,
        locator: any ScreenDescribing, size: CGSize, settleUs: UInt32, changeTimeoutUs: UInt32,
        phrases: SystemPhrases
    ) -> Result<String, ToggleError> {
        apply(
            mode: mode, control: "tile", settleUs: settleUs, changeTimeoutUs: changeTimeoutUs,
            notFound: "No \(mode.switchName) tile with a readable state was found in Control Center "
                + "(system-phrases.md, \(mode.controlCenterTile.rawValue)). Nothing was tapped.",
            read: {
                guard let screen = describer.describe(),
                      let tile = ControlCenterNetwork.tile(mode.controlCenterTile, in: screen.elements,
                                                           phrases: phrases) else { return nil }
                let state = ControlCenterNetwork.state(of: tile, phrases: phrases)
                guard state != .none else { return nil }
                return .init(state: state, center: CGPoint(x: tile.label.tapX, y: tile.label.tapY))
            },
            tap: { _ in
                ControlCenterNetwork.tapIcon(mode.controlCenterTile, input: input,
                                             locator: locator, size: size, phrases: phrases)
            })
    }

    /// Read the control twice; tap it if it is not in the asked state, then
    /// read it again, every `settleUs` until it reads that state or
    /// `changeTimeoutUs` has passed: Wi-Fi's tile keeps showing the network a
    /// moment after the tap while it disconnects (iPhone 16, iOS 27). `control`
    /// names it in results ("switch", "tile"); `tap` taps it, given where it
    /// was read.
    static func apply(
        mode: Mode, control: String, settleUs: UInt32, changeTimeoutUs: UInt32,
        notFound: String, read: () -> SettingsSwitchReader.Reading?,
        tap: (CGPoint) -> String?
    ) -> Result<String, ToggleError> {
        let name = "\(mode.switchName) \(control)"
        guard let first = read() else { return .failure(ToggleError(notFound)) }
        guard let second = read(), second.state == first.state else {
            return .failure(ToggleError("The \(name) read differently twice; nothing was tapped."))
        }
        let wanted: SettingsSwitchReader.State = mode.wantsOn ? .on : .off
        if first.state == wanted {
            return .success("\(mode.switchName) is already \(word(wanted)): nothing was tapped.")
        }
        guard let center = second.center else {
            return .failure(ToggleError("The \(name) has no tap point; nothing was tapped."))
        }
        if let error = tap(center) {
            return .failure(ToggleError("Failed to tap the \(name): \(error)"))
        }
        var after: SettingsSwitchReader.Reading?
        for _ in 0 ..< max(1, Int(changeTimeoutUs / max(settleUs, 1))) {
            usleep(settleUs)
            after = read()
            if after?.state == wanted { break }
        }
        let warning = mode.cutsMirroring
            ? " Turning \(mode.switchName) \(word(wanted)) can cut iPhone Mirroring's connection; "
                + "only the iPhone can turn it back."
            : ""
        guard let after else {
            return .success("Tapped the \(name), which read \(word(first.state)); "
                + "it could not be read afterwards.\(warning)")
        }
        guard after.state == wanted else {
            return .failure(ToggleError("Tapped the \(name), but it still reads "
                + "\(word(after.state)).\(warning)"))
        }
        return .success("Turned \(mode.switchName) \(word(wanted)): the \(control) now reads "
            + "\(word(wanted)).\(warning)")
    }

    private static func word(_ state: SettingsSwitchReader.State) -> String {
        switch state {
        case .on: return "on"
        case .off: return "off"
        case .none: return "unreadable"
        }
    }

    /// Why a toggle failed, worded for the agent or the test report.
    struct ToggleError: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
