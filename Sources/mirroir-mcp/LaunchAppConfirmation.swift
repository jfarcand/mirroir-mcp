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
// ABOUTME: Turns a launch_app attempt into its MCP result by checking Spotlight closed and the Home Screen left.
// ABOUTME: A query that matched no app leaves Spotlight open, which is reported as an error.

import Foundation
import HelperLib

/// Decides what `launch_app` reports after pressing Return in Spotlight.
enum LaunchAppConfirmation {

    /// Confirm Spotlight closed after `launch_app` opened the app (a Spotlight
    /// tile, Return, or a Home Screen icon), so a query that matched no app is
    /// reported instead of claimed as launched.
    static func outcome(
        appName: String, describer: any ScreenDescribing, windowHeight: Double?,
        settleUs: UInt32 = EnvConfig.launchVerifySettleUs,
        retryDelayUs: UInt32 = SpotlightDetector.retryDelayMs * 1000
    ) -> MCPToolResult {
        guard let windowHeight else {
            return .text("Launched '\(appName)' (screen unavailable, launch not confirmed)")
        }
        usleep(settleUs)
        switch SpotlightDetector.verifyLaunch(
            describer: describer, query: appName, windowHeight: windowHeight, retryDelayUs: retryDelayUs
        ) {
        case .launched:
            return .text("Launched '\(appName)'")
        case .unreadable:
            return .text("Launched '\(appName)' (screen unreadable, launch not confirmed)")
        case .stillOnHomeScreen:
            return .error("""
                The home screen is still showing after launching '\(appName)': Spotlight did not open \
                or closed without launching. Call launch_app again.
                """)
        case .spotlightStillVisible:
            return .error("""
                Spotlight is still open after searching '\(appName)', so no app launched. \
                Use the exact name shown under the home-screen icon, or call press_home to close Spotlight.
                """)
        }
    }
}
