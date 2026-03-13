// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Formatted dump of all effective EnvConfig values, grouped by section.
// ABOUTME: Used at startup to log the active configuration for debugging.

import Foundation

extension EnvConfig {

    /// Returns a formatted two-column dump of all effective configuration values,
    /// grouped by section. Suitable for startup logging.
    public static func formattedConfigDump() -> String {
        let sections: [(String, [(String, String)])] = [
            ("Cursor & Input", [
                ("cursorSettleUs", "\(cursorSettleUs)"),
                ("clickHoldUs", "\(clickHoldUs)"),
                ("doubleTapHoldUs", "\(doubleTapHoldUs)"),
                ("doubleTapGapUs", "\(doubleTapGapUs)"),
                ("dragModeHoldUs", "\(dragModeHoldUs)"),
                ("focusSettleUs", "\(focusSettleUs)"),
                ("keystrokeDelayUs", "\(keystrokeDelayUs)"),
            ]),
            ("App Switching", [
                ("statusBarTapY", "\(statusBarTapY)"),
                ("spaceSwitchSettleUs", "\(spaceSwitchSettleUs)"),
                ("spotlightAppearanceUs", "\(spotlightAppearanceUs)"),
                ("searchResultsPopulateUs", "\(searchResultsPopulateUs)"),
                ("safariLoadUs", "\(safariLoadUs)"),
                ("addressBarActivateUs", "\(addressBarActivateUs)"),
                ("preReturnUs", "\(preReturnUs)"),
            ]),
            ("Process & Polling", [
                ("processPollUs", "\(processPollUs)"),
                ("earlyFailureDetectUs", "\(earlyFailureDetectUs)"),
                ("resumeFromPausedUs", "\(resumeFromPausedUs)"),
                ("postHeartbeatSettleUs", "\(postHeartbeatSettleUs)"),
            ]),
            ("Keyboard", [
                ("deadKeyDelayUs", "\(deadKeyDelayUs)"),
                ("keyboardLayout", "\(keyboardLayout.isEmpty ? "(none)" : keyboardLayout)"),
            ]),
            ("Drag & Swipe", [
                ("dragInterpolationSteps", "\(dragInterpolationSteps)"),
                ("swipeInterpolationSteps", "\(swipeInterpolationSteps)"),
                ("scrollPixelScale", "\(scrollPixelScale)"),
                ("swipeDistanceFraction", "\(swipeDistanceFraction)"),
                ("scrollSwipeFromYFraction", "\(scrollSwipeFromYFraction)"),
                ("scrollSwipeToYFraction", "\(scrollSwipeToYFraction)"),
                ("defaultSwipeDurationMs", "\(defaultSwipeDurationMs)"),
                ("defaultDragDurationMs", "\(defaultDragDurationMs)"),
                ("defaultLongPressDurationMs", "\(defaultLongPressDurationMs)"),
                ("defaultScrollMaxAttempts", "\(defaultScrollMaxAttempts)"),
            ]),
            ("OCR", [
                ("ocrBackend", ocrBackend),
                ("ocrRecognitionLevel", ocrRecognitionLevel),
                ("ocrLanguageCorrection", "\(ocrLanguageCorrection)"),
            ]),
            ("YOLO", [
                ("yoloModelURL", yoloModelURL.isEmpty ? "(none)" : yoloModelURL),
                ("yoloModelPath", yoloModelPath.isEmpty ? "(none)" : yoloModelPath),
                ("yoloConfidenceThreshold", "\(yoloConfidenceThreshold)"),
            ]),
            ("Scroll Dedup", [
                ("scrollDedupStrategy", scrollDedupStrategy),
                ("scrollDedupLevenshteinMax", "\(scrollDedupLevenshteinMax)"),
                ("scrollDedupProximityPt", "\(scrollDedupProximityPt)"),
                ("scrollAnchorMinCount", "\(scrollAnchorMinCount)"),
            ]),
            ("Content Bounds", [
                ("brightnessThreshold", "\(brightnessThreshold)"),
            ]),
            ("Tap Point", [
                ("tapMaxLabelLength", "\(tapMaxLabelLength)"),
                ("tapMaxLabelWidthFraction", "\(tapMaxLabelWidthFraction)"),
                ("tapMinGapForOffset", "\(tapMinGapForOffset)"),
                ("tapIconRowMinLabels", "\(tapIconRowMinLabels)"),
                ("tapIconOffset", "\(tapIconOffset)"),
                ("tapRowTolerance", "\(tapRowTolerance)"),
                ("tapBottomZoneFraction", "\(tapBottomZoneFraction)"),
            ]),
            ("Safe Area", [
                ("safeBottomMarginPt", "\(TimingConstants.safeBottomMarginPt)"),
            ]),
            ("Grid Overlay", [
                ("gridSpacing", "\(gridSpacing)"),
                ("gridLineAlpha", "\(gridLineAlpha)"),
                ("gridLabelFontSize", "\(gridLabelFontSize)"),
                ("gridLabelEveryN", "\(gridLabelEveryN)"),
            ]),
            ("Event Classification", [
                ("eventTapDistanceThreshold", "\(eventTapDistanceThreshold)"),
                ("eventSwipeDistanceThreshold", "\(eventSwipeDistanceThreshold)"),
                ("eventLongPressThreshold", "\(eventLongPressThreshold)"),
                ("eventLabelMaxDistance", "\(eventLabelMaxDistance)"),
            ]),
            ("Step Execution", [
                ("waitForTimeoutSeconds", "\(waitForTimeoutSeconds)"),
                ("stepSettlingDelayMs", "\(stepSettlingDelayMs)"),
                ("compiledSleepBufferMs", "\(compiledSleepBufferMs)"),
                ("waitForPollIntervalUs", "\(waitForPollIntervalUs)"),
                ("measurePollIntervalUs", "\(measurePollIntervalUs)"),
                ("defaultMeasureTimeoutSeconds", "\(defaultMeasureTimeoutSeconds)"),
                ("settingsLoadUs", "\(settingsLoadUs)"),
            ]),
            ("App Switcher", [
                ("appSwitcherCardOffset", "\(appSwitcherCardOffset)"),
                ("appSwitcherCardXFraction", "\(appSwitcherCardXFraction)"),
                ("appSwitcherCardYFraction", "\(appSwitcherCardYFraction)"),
                ("appSwitcherSwipeDistance", "\(appSwitcherSwipeDistance)"),
                ("appSwitcherSwipeDurationMs", "\(appSwitcherSwipeDurationMs)"),
                ("appSwitcherMaxSwipes", "\(appSwitcherMaxSwipes)"),
                ("toolSettlingDelayUs", "\(toolSettlingDelayUs)"),
            ]),
            ("Icon Detection", [
                ("iconOcrProximityFilter", "\(iconOcrProximityFilter)"),
                ("iconMinZoneHeight", "\(iconMinZoneHeight)"),
                ("iconSaliencyMinZone", "\(iconSaliencyMinZone)"),
                ("iconBottomZoneFraction", "\(iconBottomZoneFraction)"),
                ("iconTopZoneFraction", "\(iconTopZoneFraction)"),
                ("iconMaxZoneElements", "\(iconMaxZoneElements)"),
                ("iconNoiseMaxLength", "\(iconNoiseMaxLength)"),
                ("iconMaxSaliencySize", "\(iconMaxSaliencySize)"),
                ("iconMinForInterpolation", "\(iconMinForInterpolation)"),
                ("iconSpacingTolerance", "\(iconSpacingTolerance)"),
                ("iconDeduplicationRadius", "\(iconDeduplicationRadius)"),
            ]),
            ("Icon Clusters", [
                ("iconColorThreshold", "\(iconColorThreshold)"),
                ("iconMinColumnDensity", "\(iconMinColumnDensity)"),
                ("iconMinClusterWidth", "\(iconMinClusterWidth)"),
                ("iconMaxClusterWidth", "\(iconMaxClusterWidth)"),
                ("iconSmoothingWindow", "\(iconSmoothingWindow)"),
                ("iconCornerInsetPixels", "\(iconCornerInsetPixels)"),
                ("iconBarRowBgFraction", "\(iconBarRowBgFraction)"),
            ]),
            ("AI Provider", [
                ("openAITimeoutSeconds", "\(openAITimeoutSeconds)"),
                ("ollamaTimeoutSeconds", "\(ollamaTimeoutSeconds)"),
                ("anthropicTimeoutSeconds", "\(anthropicTimeoutSeconds)"),
                ("embacleTimeoutSeconds", "\(embacleTimeoutSeconds)"),
                ("commandTimeoutSeconds", "\(commandTimeoutSeconds)"),
                ("defaultAIMaxTokens", "\(defaultAIMaxTokens)"),
            ]),
            ("Exploration", [
                ("explorationMaxDepth", "\(explorationMaxDepth)"),
                ("explorationMaxScreens", "\(explorationMaxScreens)"),
                ("explorationMaxTimeSeconds", "\(explorationMaxTimeSeconds)"),
            ]),
            ("Screen Describer", [
                ("screenDescriberMode", screenDescriberMode),
                ("visionImageWidth", "\(visionImageWidth)"),
                ("agent", agent.isEmpty ? "(none)" : agent),
            ]),
            ("Compiled Safety", [
                ("compiledTapMinConfidence", "\(compiledTapMinConfidence)"),
                ("verifyTaps", "\(verifyTaps)"),
            ]),
            ("Component Detection", [
                ("componentDetection", componentDetection),
            ]),
            ("App Identity", [
                ("mirroringBundleID", mirroringBundleID),
                ("mirroringProcessName", mirroringProcessName),
            ]),
        ]

        var lines = [String]()
        let keyWidth = 30
        let columnWidth = 60

        for (section, entries) in sections {
            lines.append("  [\(section)]")
            // Lay out entries in two columns
            var i = 0
            while i < entries.count {
                let (k1, v1) = entries[i]
                let left = "    \(k1.padding(toLength: keyWidth, withPad: " ", startingAt: 0)) \(v1)"
                if i + 1 < entries.count {
                    let (k2, v2) = entries[i + 1]
                    // Pad with spaces; never truncate long values
                    let gap = max(columnWidth - left.count, 2)
                    let padding = String(repeating: " ", count: gap)
                    lines.append("\(left)\(padding)\(k2.padding(toLength: keyWidth, withPad: " ", startingAt: 0)) \(v2)")
                    i += 2
                } else {
                    lines.append(left)
                    i += 1
                }
            }
        }

        return lines.joined(separator: "\n")
    }
}
