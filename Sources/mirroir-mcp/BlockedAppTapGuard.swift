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
// ABOUTME: Refuses a tap that lands on the icon of an app blockedApps names, on the Home Screen or a Spotlight tile.
// ABOUTME: launch_app checks blockedApps by name; this closes the route of tapping the app's icon instead.

import CoreGraphics
import Foundation
import HelperLib

/// Checks a tap point against the app icons a screen shows. An icon on a
/// Home Screen page or a Spotlight tile has its name label right below it;
/// a point inside that icon, or on the label, opens the app. When the app is
/// in `blockedApps`, the tap is refused before any input is sent.
///
/// Only labelled icons can be read: Dock icons, folders, the App Library and
/// App Switcher cards carry no name under them, so a tap there is not checked.
enum BlockedAppTapGuard {

    /// Widest horizontal offset, in points, between a tap and the center of the
    /// label under the icon it lands on (icons are about 64pt wide).
    static let iconHalfWidth = 40.0

    /// How far above its label's center an icon reaches, in points.
    static let iconReach = 90.0

    /// How far below its label's center a tap still lands on the label.
    static let labelSlack = 15.0

    /// The refusal for a tap at `point` on the screen `elements` show, or nil
    /// when it lands on no labelled icon of a blocked app. Only the Home
    /// Screen and Spotlight show app icons with their names.
    static func refusal(
        at point: CGPoint, elements: [TapPoint], windowHeight: Double, policy: PermissionPolicy
    ) -> String? {
        guard SpotlightDetector.isHomeScreenVisible(elements: elements, windowHeight: windowHeight)
                || SpotlightDetector.isSpotlightVisible(elements: elements) else { return nil }
        for label in elements where label.text != CoreMLElementDetector.iconLabel && isOnIcon(point, of: label) {
            if case .denied(let reason) = policy.checkAppLaunch(label.text.trimmingCharacters(in: .whitespaces)) {
                return "The tap at (\(Int(point.x)), \(Int(point.y))) lands on the '\(label.text)' icon. \(reason)"
            }
        }
        return nil
    }

    /// The refusal for a tap at `point` on `ctx`'s screen right now. Reads the
    /// screen only when `policy` blocks an app; nil when the screen cannot be read.
    static func refusal(at point: CGPoint, ctx: TargetContext, policy: PermissionPolicy) -> String? {
        refusal(target: .point(point), bridge: ctx.bridge, describer: ctx.ocrDescriber, policy: policy)
    }

    /// What a tap aims at: a point, or the screen text a step names.
    enum Target {
        case point(CGPoint)
        case label(String)
    }

    /// The refusal for a tap at `target` on the screen `describer` reads now.
    /// A label is found the way a tap step finds it (`ElementMatcher`). Reads
    /// the screen only when `policy` blocks an app; nil when it cannot be read
    /// or a label is not on it.
    static func refusal(
        target: Target, bridge: any WindowBridging, describer: any ScreenDescribing,
        policy: PermissionPolicy
    ) -> String? {
        guard !(policy.config?.blockedApps ?? []).isEmpty,
              let height = bridge.getWindowInfo()?.size.height,
              let screen = describer.describe(), screen.ocrFailure == nil else { return nil }
        let point: CGPoint
        switch target {
        case .point(let given): point = given
        case .label(let text):
            if let given = TapStepPoint.parse(text) {
                point = CGPoint(x: given.x, y: given.y)
            } else if let match = ElementMatcher.findMatch(label: text, in: screen.elements) {
                point = CGPoint(x: match.element.tapX, y: match.element.tapY)
            } else {
                return nil
            }
        }
        return refusal(at: point, elements: screen.elements, windowHeight: Double(height), policy: policy)
    }

    /// Whether `point` is inside the icon above `label`, or on the label.
    static func isOnIcon(_ point: CGPoint, of label: TapPoint) -> Bool {
        abs(Double(point.x) - label.tapX) <= iconHalfWidth
            && (label.tapY - iconReach ... label.tapY + labelSlack).contains(Double(point.y))
    }
}
