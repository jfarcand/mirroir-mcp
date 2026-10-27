// ABOUTME: Argument types for the web-surface steps — tap, type, wait_for, assert_visible.
// ABOUTME: Each accepts the original string shorthand plus a record form carrying last/timeout_s.

use std::result::Result as StdResult;

use serde::Deserialize;

/// Arguments for `tap`. Accepts the string shorthand `- tap: "send"` or the
/// record form `- tap: { label, last?, timeout_s? }`.
///
/// `last` selects the final match when the label resolves to several elements
/// — the shape a chat transcript needs (`message-agent` names every bubble,
/// the assertion is about the newest one). `timeout_s` bounds the click.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TapArgs {
    /// The label, `data-test` value, or locator-engine string to click.
    pub label: String,
    /// Select the last of several matches instead of requiring a unique one.
    pub last: bool,
    /// Per-step timeout override, in seconds. `None` accepts the emitter default.
    pub timeout_s: Option<u32>,
}

impl TapArgs {
    /// A tap on `label` with no `last` selection and no timeout override —
    /// what the string shorthand parses to.
    #[must_use]
    pub const fn new(label: String) -> Self {
        Self {
            label,
            last: false,
            timeout_s: None,
        }
    }
}

impl<'de> Deserialize<'de> for TapArgs {
    fn deserialize<D>(deserializer: D) -> StdResult<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Repr {
            Shorthand(String),
            Full {
                label: String,
                #[serde(default)]
                last: bool,
                #[serde(default)]
                timeout_s: Option<u32>,
            },
        }
        Ok(match Repr::deserialize(deserializer)? {
            Repr::Shorthand(label) => Self::new(label),
            Repr::Full {
                label,
                last,
                timeout_s,
            } => Self {
                label,
                last,
                timeout_s,
            },
        })
    }
}

/// Arguments for `type`. Accepts the string shorthand `- type: "hello"` or the
/// record form `- type: { text, into?, last?, timeout_s? }`.
///
/// `into` names the element the text is written to. When it is absent the
/// emitter writes into the element the closest preceding `tap:` /
/// `long_press:` targeted, which is the shape every recorded scenario has:
/// touch the field, then type into it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TypeArgs {
    /// The text to write.
    pub text: String,
    /// Label of the element to write into. `None` inherits the preceding touch.
    pub into: Option<String>,
    /// Select the last of several matches for `into`.
    pub last: bool,
    /// Per-step timeout override, in seconds.
    pub timeout_s: Option<u32>,
}

impl TypeArgs {
    /// Text typed into the element the preceding touch targeted — what the
    /// string shorthand parses to.
    #[must_use]
    pub const fn new(text: String) -> Self {
        Self {
            text,
            into: None,
            last: false,
            timeout_s: None,
        }
    }
}

impl<'de> Deserialize<'de> for TypeArgs {
    fn deserialize<D>(deserializer: D) -> StdResult<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Repr {
            Shorthand(String),
            Full {
                text: String,
                #[serde(default)]
                into: Option<String>,
                #[serde(default)]
                last: bool,
                #[serde(default)]
                timeout_s: Option<u32>,
            },
        }
        Ok(match Repr::deserialize(deserializer)? {
            Repr::Shorthand(text) => Self::new(text),
            Repr::Full {
                text,
                into,
                last,
                timeout_s,
            } => Self {
                text,
                into,
                last,
                timeout_s,
            },
        })
    }
}

/// Arguments for `assert_visible` and `assert_not_visible`. Accepts the string
/// shorthand `- assert_visible: "welcome"` or the record form
/// `- assert_visible: { label, contains?, last?, timeout_s? }`.
///
/// `contains` upgrades the assertion from presence to content: the element is
/// asserted to carry that text. `assert_not_visible` inverts whichever
/// assertion the arguments select.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssertArgs {
    /// The label, `data-test` value, or locator-engine string to assert on.
    pub label: String,
    /// Text the element must contain. `None` asserts visibility only.
    pub contains: Option<String>,
    /// Select the last of several matches instead of requiring a unique one.
    pub last: bool,
    /// Per-step timeout override, in seconds.
    pub timeout_s: Option<u32>,
}

impl AssertArgs {
    /// A visibility assertion on `label` — what the string shorthand parses to.
    #[must_use]
    pub const fn new(label: String) -> Self {
        Self {
            label,
            contains: None,
            last: false,
            timeout_s: None,
        }
    }
}

impl<'de> Deserialize<'de> for AssertArgs {
    fn deserialize<D>(deserializer: D) -> StdResult<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Repr {
            Shorthand(String),
            Full {
                label: String,
                #[serde(default)]
                contains: Option<String>,
                #[serde(default)]
                last: bool,
                #[serde(default)]
                timeout_s: Option<u32>,
            },
        }
        Ok(match Repr::deserialize(deserializer)? {
            Repr::Shorthand(label) => Self::new(label),
            Repr::Full {
                label,
                contains,
                last,
                timeout_s,
            } => Self {
                label,
                contains,
                last,
                timeout_s,
            },
        })
    }
}

/// Arguments for `wait_for`. Accepts the string shorthand `- wait_for: "x"` or
/// the record form `- wait_for: { label, timeout_s?, last? }`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WaitForArgs {
    /// The text label or `data-test` identifier to wait for.
    pub label: String,
    /// Optional per-step timeout override, in seconds. `None` lets the runner pick a default.
    pub timeout_s: Option<u32>,
    /// Select the last of several matches instead of requiring a unique one.
    pub last: bool,
}

impl WaitForArgs {
    /// A wait on `label` with no timeout override and no `last` selection.
    #[must_use]
    pub const fn new(label: String) -> Self {
        Self {
            label,
            timeout_s: None,
            last: false,
        }
    }
}

impl<'de> Deserialize<'de> for WaitForArgs {
    fn deserialize<D>(deserializer: D) -> StdResult<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Repr {
            Shorthand(String),
            Full {
                label: String,
                #[serde(default)]
                timeout_s: Option<u32>,
                #[serde(default)]
                last: bool,
            },
        }
        Ok(match Repr::deserialize(deserializer)? {
            Repr::Shorthand(label) => Self::new(label),
            Repr::Full {
                label,
                timeout_s,
                last,
            } => Self {
                label,
                timeout_s,
                last,
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;

    use serde_norway::Deserializer;
    use serde_norway::with::singleton_map_recursive;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn parse<T: for<'de> Deserialize<'de>>(yaml: &str) -> StdResult<T, serde_norway::Error> {
        singleton_map_recursive::deserialize(Deserializer::from_str(yaml))
    }

    #[test]
    fn tap_accepts_both_shorthand_and_record() -> TestResult {
        assert_eq!(
            parse::<TapArgs>("\"send\"")?,
            TapArgs::new("send".to_owned())
        );
        assert_eq!(
            parse::<TapArgs>("{ label: \"message-agent\", last: true, timeout_s: 5 }")?,
            TapArgs {
                label: "message-agent".to_owned(),
                last: true,
                timeout_s: Some(5),
            }
        );
        Ok(())
    }

    #[test]
    fn type_shorthand_inherits_the_preceding_touch() -> TestResult {
        let short: TypeArgs = parse("\"hello\"")?;
        assert_eq!(short.text, "hello");
        assert!(short.into.is_none());
        let full: TypeArgs = parse("{ text: \"hello\", into: \"prompt-input\" }")?;
        assert_eq!(full.into.as_deref(), Some("prompt-input"));
        Ok(())
    }

    #[test]
    fn assert_accepts_contains_and_last() -> TestResult {
        assert_eq!(
            parse::<AssertArgs>("\"welcome\"")?,
            AssertArgs::new("welcome".to_owned())
        );
        let full: AssertArgs = parse("{ label: \"message-agent\", contains: \"4\", last: true }")?;
        assert_eq!(full.contains.as_deref(), Some("4"));
        assert!(full.last);
        Ok(())
    }

    #[test]
    fn wait_for_keeps_its_original_two_shapes() -> TestResult {
        assert_eq!(
            parse::<WaitForArgs>("\"Connected\"")?,
            WaitForArgs::new("Connected".to_owned())
        );
        let full: WaitForArgs = parse("{ label: \"Connected\", timeout_s: 30 }")?;
        assert_eq!(full.timeout_s, Some(30));
        assert!(!full.last);
        Ok(())
    }
}
