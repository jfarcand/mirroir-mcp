// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Turns a launch_app Spotlight attempt into its MCP result by checking Spotlight closed.
// ABOUTME: A query that matched no app leaves Spotlight open, which is reported as an error.

import Foundation
import HelperLib

/// Decides what `launch_app` reports after pressing Return in Spotlight.
enum LaunchAppConfirmation {

    /// Confirm Spotlight closed after `launch_app` pressed Return, so a query that
    /// matched no app is reported instead of claimed as launched.
    static func outcome(
        appName: String, describer: any ScreenDescribing, windowHeight: Double?,
        settleUs: UInt32 = EnvConfig.launchVerifySettleUs,
        retryDelayUs: UInt32 = SpotlightDetector.retryDelayMs * 1000
    ) -> MCPToolResult {
        guard let windowHeight else {
            return .text("Launched '\(appName)' via Spotlight (screen unavailable, launch not confirmed)")
        }
        usleep(settleUs)
        switch SpotlightDetector.verifyLaunch(
            describer: describer, query: appName, windowHeight: windowHeight, retryDelayUs: retryDelayUs
        ) {
        case .launched:
            return .text("Launched '\(appName)' via Spotlight")
        case .unreadable:
            return .text("Launched '\(appName)' via Spotlight (screen unreadable, launch not confirmed)")
        case .spotlightStillVisible:
            return .error("""
                Spotlight is still open after searching '\(appName)', so no app launched. \
                Use the exact name shown under the home-screen icon, or call press_home to close Spotlight.
                """)
        }
    }
}
