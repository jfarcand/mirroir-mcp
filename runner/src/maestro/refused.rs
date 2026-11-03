// ABOUTME: The Maestro commands with no faithful mirroir equivalent, each with the reason the import names.
// ABOUTME: One table, so the refusal a user reads and the docs' mapping table come from the same list.

/// `(command, reason)` for every Maestro command mirroir cannot run as written.
const REFUSED: &[(&str, &str)] = &[
    (
        "doubleTapOn",
        "the scenario grammar has no double-tap step; mirroir-mcp's `double_tap` tool takes coordinates, not a label",
    ),
    (
        "back",
        "iOS has no system back key (Maestro's `back` is Android-only); tap the screen's own back control instead",
    ),
    (
        "hideKeyboard",
        "no scenario step dismisses the iOS keyboard; tap the next control or press return in the flow instead",
    ),
    (
        "waitForAnimationToEnd",
        "mirroir has no settle-wait step; wait for the text the next screen shows with `extendedWaitUntil`",
    ),
    (
        "clearState",
        "a stock iPhone exposes no reset of one app's data; that needs a simulator or a developer install",
    ),
    (
        "clearKeychain",
        "a stock iPhone exposes no Keychain reset to an automation client",
    ),
    (
        "toggleAirplaneMode",
        "the resulting state depends on the current one, which `set_network` cannot read; use `setAirplaneMode`",
    ),
    (
        "evalScript",
        "mirroir evaluates no JavaScript; compute the value outside the flow and pass it as a `${VAR}`",
    ),
    (
        "runScript",
        "mirroir evaluates no JavaScript; compute the value outside the flow and pass it as a `${VAR}`",
    ),
    (
        "assertTrue",
        "mirroir evaluates no JavaScript; assert on screen text with `assertVisible` instead",
    ),
    (
        "copyTextFrom",
        "reading an element's text into `maestro.copiedText` has no step; mirroir keeps no flow-side clipboard",
    ),
    (
        "pasteText",
        "pastes Maestro's own copied text, which mirroir never holds; type the value with `inputText`",
    ),
    (
        "setClipboard",
        "the scenario grammar has no clipboard step; type the value with `inputText`",
    ),
    (
        "inputRandomEmail",
        "mirroir-run generates no random values; pass one in as a `${VAR}`",
    ),
    (
        "inputRandomNumber",
        "mirroir-run generates no random values; pass one in as a `${VAR}`",
    ),
    (
        "inputRandomPersonName",
        "mirroir-run generates no random values; pass one in as a `${VAR}`",
    ),
    (
        "inputRandomText",
        "mirroir-run generates no random values; pass one in as a `${VAR}`",
    ),
    (
        "setLocation",
        "a stock iPhone accepts no simulated location from an automation client",
    ),
    (
        "travel",
        "a stock iPhone accepts no simulated location from an automation client",
    ),
    (
        "addMedia",
        "a stock iPhone accepts no media pushed into its photo library by an automation client",
    ),
    (
        "setPermissions",
        "permissions cannot be pre-set on a stock iPhone; their dialogs appear as they do for a user",
    ),
    (
        "setOrientation",
        "the scenario grammar has no rotation step",
    ),
    (
        "startRecording",
        "the scenario grammar has no screen-recording step",
    ),
    (
        "stopRecording",
        "the scenario grammar has no screen-recording step",
    ),
    (
        "assertWithAI",
        "an AI-only check cannot run inside an ios block; `mirroir-mcp test` has no model",
    ),
    (
        "assertNoDefectsWithAI",
        "an AI-only check cannot run inside an ios block; `mirroir-mcp test` has no model",
    ),
    (
        "extractTextWithAI",
        "an AI-only step cannot run inside an ios block; `mirroir-mcp test` has no model",
    ),
    (
        "assertScreenshot",
        "mirroir compares screens against the scenario's compiled reference, not a PNG; record one with a first green run",
    ),
    (
        "assertDarkMode",
        "the scenario grammar has no appearance step",
    ),
    (
        "assertLightMode",
        "the scenario grammar has no appearance step",
    ),
    ("setDarkMode", "the scenario grammar has no appearance step"),
    (
        "toggleDarkMode",
        "the scenario grammar has no appearance step",
    ),
    (
        "retry",
        "an ios block runs once and stops at its first failure; it has no retry",
    ),
];

/// The reason `command` has no mirroir equivalent, if it is one of them.
#[must_use]
pub fn refusal(command: &str) -> Option<&'static str> {
    REFUSED
        .iter()
        .find(|(name, _)| *name == command)
        .map(|(_, reason)| *reason)
}

/// Every refused command, in table order.
#[cfg(test)]
pub fn refused_commands() -> impl Iterator<Item = &'static str> {
    REFUSED.iter().map(|(name, _)| *name)
}
