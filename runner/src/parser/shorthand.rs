// ABOUTME: Shorthand-or-record decoding for step arguments — `tap: "send"` or `tap: { label, last }`.
// ABOUTME: Decodes the record straight from the map, so the version seam still sees its unknown keys.

use std::fmt;
use std::marker::PhantomData;
use std::result::Result as StdResult;

use serde::de::value::MapAccessDeserializer;
use serde::de::{self, IntoDeserializer, MapAccess, Visitor};
use serde::{Deserialize, Deserializer};

/// A step argument written either as a scalar shorthand or as a record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShorthandOr<S, R> {
    /// The scalar form (`tap: "send"`).
    Shorthand(S),
    /// The mapping form (`tap: { label: send, last: true }`).
    Record(R),
}

impl<'de, S, R> Deserialize<'de> for ShorthandOr<S, R>
where
    S: Deserialize<'de>,
    R: Deserialize<'de>,
{
    /// Decodes without `#[serde(untagged)]`: an untagged enum buffers its input,
    /// which hides the record's unknown keys from `serde_ignored`. Handing the
    /// live map to `R` keeps them visible, so a typo inside a record is refused
    /// like a typo anywhere else in the artifact.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> StdResult<Self, D::Error> {
        deserializer.deserialize_any(ShorthandOrVisitor(PhantomData))
    }
}

struct ShorthandOrVisitor<S, R>(PhantomData<(S, R)>);

impl<'de, S, R> Visitor<'de> for ShorthandOrVisitor<S, R>
where
    S: Deserialize<'de>,
    R: Deserialize<'de>,
{
    type Value = ShorthandOr<S, R>;

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a string shorthand or a mapping")
    }

    fn visit_str<E: de::Error>(self, value: &str) -> StdResult<Self::Value, E> {
        S::deserialize(value.into_deserializer()).map(ShorthandOr::Shorthand)
    }

    fn visit_map<A: MapAccess<'de>>(self, map: A) -> StdResult<Self::Value, A::Error> {
        R::deserialize(MapAccessDeserializer::new(map)).map(ShorthandOr::Record)
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    #[derive(Debug, Deserialize, PartialEq, Eq)]
    struct Record {
        label: String,
    }

    #[test]
    fn decodes_the_shorthand_and_the_record() -> TestResult {
        let short: ShorthandOr<String, Record> = serde_norway::from_str("send")?;
        assert_eq!(short, ShorthandOr::Shorthand("send".to_owned()));
        let record: ShorthandOr<String, Record> = serde_norway::from_str("label: send")?;
        assert_eq!(
            record,
            ShorthandOr::Record(Record {
                label: "send".to_owned()
            })
        );
        Ok(())
    }

    #[test]
    fn refuses_a_sequence() {
        assert!(serde_norway::from_str::<ShorthandOr<String, Record>>("[a]").is_err());
    }

    #[test]
    fn reports_an_unknown_record_key_to_serde_ignored() -> TestResult {
        let mut ignored = Vec::new();
        let parsed: ShorthandOr<String, Record> = serde_ignored::deserialize(
            serde_norway::Deserializer::from_str("label: send\nlable: typo\n"),
            |path| ignored.push(path.to_string()),
        )?;
        assert!(matches!(parsed, ShorthandOr::Record(_)));
        assert_eq!(ignored, vec!["lable".to_owned()]);
        Ok(())
    }
}
