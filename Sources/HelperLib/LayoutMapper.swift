// ABOUTME: Translates characters between keyboard layouts using macOS UCKeyTranslate.
// ABOUTME: Builds substitution tables so US QWERTY HID keycodes produce correct characters on non-US layouts.

import Carbon
import Foundation

/// Translates characters between keyboard layouts.
///
/// When the iPhone's hardware keyboard layout differs from US QWERTY (which the
/// Karabiner HID helper uses), the same HID keycode produces different characters.
/// This mapper uses `UCKeyTranslate` to build a character substitution table: for
/// each physical key, it compares what US QWERTY produces vs what the target layout
/// produces, then maps target→US so the helper sends the right keycode.
public enum LayoutMapper {

    /// Get the `UCKeyboardLayout` data for a keyboard input source by its TIS source ID.
    /// Example source IDs: "com.apple.keylayout.US", "com.apple.keylayout.Canadian-CSA"
    ///
    /// Uses `includeAllInstalled=true` to access macOS-bundled layouts that aren't
    /// currently enabled in the user's input source preferences.
    public static func layoutData(forSourceID sourceID: String) -> Data? {
        let properties: NSDictionary = [
            kTISPropertyInputSourceID as String: sourceID
        ]
        guard let sourceList = TISCreateInputSourceList(properties, true),
              let sources = sourceList.takeRetainedValue() as? [TISInputSource],
              let source = sources.first
        else {
            return nil
        }
        return extractLayoutData(from: source)
    }

    /// Find the iPhone's keyboard layout for character translation.
    ///
    /// Detection order:
    /// 1. `IPHONE_KEYBOARD_LAYOUT` environment variable (e.g. "Canadian-CSA")
    /// 2. First enabled non-US keyboard layout that differs from US QWERTY
    /// 3. Locale-matched layout from all installed system layouts
    /// 4. First installed layout that differs from US QWERTY
    ///
    /// Uses `includeAllInstalled=true` to access all 250+ macOS-bundled layouts,
    /// even those the user hasn't enabled in System Settings. This is needed because
    /// the iPhone's hardware keyboard layout often differs from the Mac's enabled layouts.
    public static func findNonUSLayout() -> (sourceID: String, layoutData: Data)? {
        // 1. Check environment variable for explicit layout selection.
        //    Accepts either full source ID ("com.apple.keylayout.Canadian-CSA")
        //    or short name ("Canadian-CSA").
        if let envLayout = ProcessInfo.processInfo.environment["IPHONE_KEYBOARD_LAYOUT"],
           !envLayout.isEmpty
        {
            let fullID = envLayout.hasPrefix("com.apple.keylayout.")
                ? envLayout
                : "com.apple.keylayout.\(envLayout)"
            if let data = layoutData(forSourceID: fullID) {
                return (fullID, data)
            }
        }

        // Load US QWERTY data to check which layouts actually differ.
        // Some layouts (e.g., "Canadian") are identical to US QWERTY for all
        // standard keys and would produce an empty substitution table.
        guard let usData = layoutData(forSourceID: "com.apple.keylayout.US") else {
            return nil
        }

        // 2. Search all installed keyboard layouts (not just enabled ones).
        let properties: NSDictionary = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
        ]
        guard let sourceList = TISCreateInputSourceList(properties, true),
              let sources = sourceList.takeRetainedValue() as? [TISInputSource]
        else {
            return nil
        }

        // Build the system locale's region name for matching (e.g., "CA" → "canadian").
        let regionCode = Locale.current.region?.identifier ?? ""
        let regionSearch = regionDisplayName(for: regionCode).lowercased()

        var enabledMatch: (String, Data)?
        var localeMatch: (String, Data)?
        var anyMatch: (String, Data)?

        for source in sources {
            guard let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                continue
            }
            let sourceID = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String

            if sourceID == "com.apple.keylayout.US" { continue }
            if !sourceID.hasPrefix("com.apple.keylayout.") { continue }

            guard let data = extractLayoutData(from: source) else { continue }

            // Skip layouts identical to US QWERTY (empty substitution).
            let sub = buildSubstitution(usLayoutData: usData, targetLayoutData: data)
            if sub.isEmpty { continue }

            // Check if this layout is currently enabled
            let isEnabled: Bool
            if let enabledRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) {
                isEnabled = CFBooleanGetValue(
                    Unmanaged<CFBoolean>.fromOpaque(enabledRef).takeUnretainedValue()
                )
            } else {
                isEnabled = false
            }

            if isEnabled && enabledMatch == nil {
                enabledMatch = (sourceID, data)
            }

            // Check if layout name matches the system locale region
            if !regionSearch.isEmpty
                && sourceID.lowercased().contains(regionSearch)
                && localeMatch == nil
            {
                localeMatch = (sourceID, data)
            }

            if anyMatch == nil {
                anyMatch = (sourceID, data)
            }
        }

        // Prefer: enabled > locale-matched > any non-US
        return enabledMatch ?? localeMatch ?? anyMatch
    }

    /// Map a region code to a search term for matching Apple keyboard layout source IDs.
    /// Apple names layouts after countries/regions (e.g., "Canadian-CSA", "French-PC").
    private static func regionDisplayName(for regionCode: String) -> String {
        let regionMap: [String: String] = [
            "CA": "canadian",
            "FR": "french",
            "DE": "german",
            "CH": "swiss",
            "BE": "belgian",
            "GB": "british",
            "IE": "irish",
            "IT": "italian",
            "ES": "spanish",
            "PT": "portuguese",
            "NL": "dutch",
            "BR": "brazilian",
            "JP": "japanese",
            "KR": "korean",
            "CN": "chinese",
            "TW": "chinese",
            "RU": "russian",
            "UA": "ukrainian",
            "PL": "polish",
            "CZ": "czech",
            "SK": "slovak",
            "HU": "hungarian",
            "RO": "romanian",
            "BG": "bulgarian",
            "HR": "croatian",
            "SI": "slovenian",
            "RS": "serbian",
            "GR": "greek",
            "TR": "turkish",
            "IL": "hebrew",
            "SA": "arabic",
            "IN": "indian",
            "TH": "thai",
            "VN": "vietnamese",
            "NO": "norwegian",
            "SE": "swedish",
            "DK": "danish",
            "FI": "finnish",
            "IS": "icelandic",
            "EE": "estonian",
            "LV": "latvian",
            "LT": "lithuanian",
        ]
        return regionMap[regionCode] ?? regionCode.lowercased()
    }

    /// Build a character substitution table between US QWERTY and a target layout.
    ///
    /// For each virtual keycode and modifier state (unshifted / shifted), translates
    /// the keycode through both layouts. When the characters differ, records
    /// `targetChar → usChar` so that sending `usChar` to the HID helper produces
    /// `targetChar` on the iPhone.
    public static func buildSubstitution(
        usLayoutData: Data, targetLayoutData: Data
    ) -> [Character: Character] {
        var map = [Character: Character]()

        // Modifier states: no modifier and shift.
        // These match what HIDKeyMap supports (unshifted + leftShift).
        let modifierStates: [UInt32] = [
            0,  // no modifiers
            2,  // shift (Carbon shiftKey=0x200, shifted right 8 = 2)
        ]

        // Virtual keycodes 0-50 cover all main keyboard alphanumeric and punctuation keys.
        for keycode: UInt16 in 0...50 {
            for modState in modifierStates {
                guard let usChar = translateKeycode(
                    keycode, modifiers: modState, layoutData: usLayoutData
                ),
                    let targetChar = translateKeycode(
                        keycode, modifiers: modState, layoutData: targetLayoutData
                    )
                else { continue }

                if usChar != targetChar {
                    map[targetChar] = usChar
                }
            }
        }

        return map
    }

    /// Apply a substitution table to translate text.
    /// Characters not in the table pass through unchanged.
    public static func translate(
        _ text: String, substitution: [Character: Character]
    ) -> String {
        if substitution.isEmpty { return text }
        return String(text.map { substitution[$0] ?? $0 })
    }

    /// Translate a single virtual keycode + modifier state to a character
    /// using the provided keyboard layout data.
    ///
    /// Uses `kUCKeyTranslateNoDeadKeysMask` to get the immediate character
    /// without dead-key composition.
    public static func translateKeycode(
        _ keycode: UInt16, modifiers: UInt32, layoutData: Data
    ) -> Character? {
        return layoutData.withUnsafeBytes { buffer in
            guard let layoutPtr = buffer.baseAddress?
                .assumingMemoryBound(to: UCKeyboardLayout.self)
            else {
                return nil
            }

            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0

            // Keyboard type 0 (ANSI default) works for all standard layouts.
            // LMGetKbdType() reads low-memory globals that may not be initialized
            // in headless/test contexts.
            let status = UCKeyTranslate(
                layoutPtr,
                keycode,
                UInt16(kUCKeyActionDown),
                modifiers,
                0,
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )

            guard status == noErr, length > 0 else { return nil }
            let str = String(utf16CodeUnits: chars, count: length)
            return str.first
        }
    }

    // MARK: - Private

    /// Extract UCKeyboardLayout data from a TIS input source.
    private static func extractLayoutData(from source: TISInputSource) -> Data? {
        guard let rawPtr = TISGetInputSourceProperty(
            source, kTISPropertyUnicodeKeyLayoutData
        ) else {
            return nil
        }
        let cfData = Unmanaged<CFData>.fromOpaque(rawPtr).takeUnretainedValue()
        return cfData as Data
    }
}
