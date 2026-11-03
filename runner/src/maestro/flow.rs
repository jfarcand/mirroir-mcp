// ABOUTME: Reads a Maestro flow file — optional header document, `---`, then the command list — with line locations.
// ABOUTME: Each command carries the line of its `- ` item so an unsupported one is reported as file:line.

use std::fs;
use std::ops::Range;
use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_norway::{Deserializer, Mapping, Value};

use crate::maestro::error::{Location, MaestroError};

/// The line that ends a Maestro flow's header document.
const DOCUMENT_SEPARATOR: &str = "---";

/// One parsed Maestro flow file.
#[derive(Debug, Clone)]
pub struct FlowFile {
    /// The file as given (relative includes resolve against its directory).
    pub path: PathBuf,
    /// The header document's keys; empty when the flow has no header.
    pub header: Mapping,
    /// The command list, in order.
    pub commands: Vec<Command>,
    lines: Vec<String>,
    header_lines: Range<usize>,
}

/// One command of a flow, with where it sits.
#[derive(Debug, Clone)]
pub struct Command {
    /// Where the command sits.
    pub location: Location,
    /// The command as YAML: a bare name (`- launchApp`) or a one-key map.
    pub value: Value,
    span: Option<Range<usize>>,
}

impl Command {
    /// The command's name and its arguments (`Null` for the bare form).
    ///
    /// # Errors
    ///
    /// The reason, when the item is neither a bare name nor a one-key map.
    pub fn name_and_args(&self) -> Result<(String, Value), String> {
        match &self.value {
            Value::String(name) => Ok((name.clone(), Value::Null)),
            Value::Mapping(map) if map.len() == 1 => match map.iter().next() {
                Some((Value::String(name), args)) => Ok((name.clone(), args.clone())),
                _ => Err("a command's key must be its name".to_owned()),
            },
            _ => Err("a command is a bare name or a map with exactly one key".to_owned()),
        }
    }
}

impl FlowFile {
    /// Read and parse the flow at `path`.
    ///
    /// # Errors
    ///
    /// [`MaestroError::Read`], [`MaestroError::Parse`], or
    /// [`MaestroError::Shape`] when the documents are not a header map
    /// followed by a command list.
    pub fn load(path: &Path) -> Result<Self, MaestroError> {
        let raw = fs::read_to_string(path).map_err(|source| MaestroError::Read {
            path: path.to_path_buf(),
            source,
        })?;
        let documents = Deserializer::from_str(&raw)
            .map(Value::deserialize)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|source| MaestroError::Parse {
                path: path.to_path_buf(),
                source,
            })?;
        let lines: Vec<String> = raw.lines().map(str::to_owned).collect();
        let shape = |reason: &str| MaestroError::Shape {
            location: Location {
                file: path.to_path_buf(),
                line: None,
                path: "flow".to_owned(),
            },
            reason: reason.to_owned(),
        };
        let (header, commands) = match documents.as_slice() {
            [Value::Sequence(commands)] => (Mapping::new(), commands.clone()),
            [Value::Mapping(header), Value::Sequence(commands)] => {
                (header.clone(), commands.clone())
            }
            [Value::Mapping(header), Value::Null] => (header.clone(), Vec::new()),
            [Value::Mapping(_)] => {
                return Err(shape(
                    "the header must be followed by `---` and the command list",
                ));
            }
            _ => {
                return Err(shape(
                    "expected a command list, or a header map, `---`, then a command list",
                ));
            }
        };
        let separator = (documents.len() == 2)
            .then(|| header_separator(&lines))
            .flatten();
        let header_lines = 0..separator.unwrap_or(0);
        let command_lines = separator.map_or(0, |at| at + 1)..lines.len();
        let mut flow = Self {
            path: path.to_path_buf(),
            header,
            commands: Vec::new(),
            lines,
            header_lines,
        };
        flow.commands = flow.located(command_lines, commands, |index| format!("command {index}"));
        Ok(flow)
    }

    /// The commands under `key` inside `parent` (`runFlow`'s or `repeat`'s
    /// `commands:`), located within the parent's lines.
    #[must_use]
    pub fn nested(&self, parent: &Command, key: &str, values: Vec<Value>) -> Vec<Command> {
        let range = parent
            .span
            .clone()
            .and_then(|span| self.key_line(span.clone(), key).map(|at| at + 1..span.end))
            .unwrap_or(0..0);
        let prefix = parent.location.path.clone();
        self.located(range, values, |index| format!("{prefix} › {key} {index}"))
    }

    /// The commands under the header key `key` (`onFlowStart`).
    #[must_use]
    pub fn header_commands(&self, key: &str, values: Vec<Value>) -> Vec<Command> {
        let range = self
            .key_line(self.header_lines.clone(), key)
            .map_or(0..0, |at| at + 1..self.header_lines.end);
        self.located(range, values, |index| format!("header {key} {index}"))
    }

    /// Where the header key `key` sits.
    #[must_use]
    pub fn header_location(&self, key: &str) -> Location {
        Location {
            file: self.path.clone(),
            line: self
                .key_line(self.header_lines.clone(), key)
                .map(|at| at + 1),
            path: format!("header `{key}`"),
        }
    }

    /// Pair each value with the line of its `- ` item inside `range`.
    fn located(
        &self,
        range: Range<usize>,
        values: Vec<Value>,
        path: impl Fn(usize) -> String,
    ) -> Vec<Command> {
        let starts = item_lines(&self.lines, range.clone(), values.len());
        values
            .into_iter()
            .enumerate()
            .map(|(index, value)| {
                let start = starts.as_ref().and_then(|s| s.get(index).copied());
                let end = starts
                    .as_ref()
                    .and_then(|s| s.get(index + 1).copied())
                    .unwrap_or(range.end);
                Command {
                    location: Location {
                        file: self.path.clone(),
                        line: start.map(|at| at + 1),
                        path: path(index + 1),
                    },
                    value,
                    span: start.map(|at| at..end),
                }
            })
            .collect()
    }

    /// The first line in `range` whose content, after any `- `, opens `key:`.
    fn key_line(&self, range: Range<usize>, key: &str) -> Option<usize> {
        let opener = format!("{key}:");
        range.into_iter().find(|&at| {
            self.lines.get(at).is_some_and(|line| {
                let content = line.trim_start();
                let content = content.strip_prefix("- ").unwrap_or(content);
                content.starts_with(&opener)
            })
        })
    }
}

/// The `---` line that ends the header — the first one after the header's
/// first content line, so a document that opens with `---` still splits.
fn header_separator(lines: &[String]) -> Option<usize> {
    let first_content = lines.iter().position(|line| is_content(line))?;
    lines
        .iter()
        .enumerate()
        .skip(first_content + 1)
        .find(|(_, line)| line.trim_end() == DOCUMENT_SEPARATOR)
        .map(|(at, _)| at)
}

/// The 0-based lines of the `expected` block-sequence items in `range`.
///
/// The first `- ` line fixes the sequence's indent; every later `- ` line at
/// that indent is an item, and a content line indented less ends it. A count
/// that disagrees with the parsed sequence (flow-style lists, block scalars
/// that look like items) yields `None`, so no command is given a wrong line.
fn item_lines(lines: &[String], range: Range<usize>, expected: usize) -> Option<Vec<usize>> {
    let first = range
        .clone()
        .find(|&at| lines.get(at).is_some_and(|line| is_item(line)))?;
    let indent = indent_of(lines.get(first)?);
    let mut found = Vec::new();
    for at in first..range.end {
        let Some(line) = lines.get(at) else {
            break;
        };
        if !is_content(line) {
            continue;
        }
        let current = indent_of(line);
        if current < indent {
            break;
        }
        if current == indent && is_item(line) {
            found.push(at);
        }
    }
    (found.len() == expected).then_some(found)
}

fn is_item(line: &str) -> bool {
    let content = line.trim_start();
    content.starts_with("- ") || content.trim_end() == "-"
}

fn is_content(line: &str) -> bool {
    let content = line.trim_start();
    !content.is_empty() && !content.starts_with('#')
}

fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start().len()
}

#[cfg(test)]
mod tests {
    use std::error::Error as StdError;
    use std::result::Result as StdResult;

    use tempfile::TempDir;

    use super::*;

    type TestResult = StdResult<(), Box<dyn StdError>>;

    fn write_flow(body: &str) -> StdResult<(TempDir, PathBuf), Box<dyn StdError>> {
        let dir = TempDir::new()?;
        let path = dir.path().join("flow.yaml");
        fs::write(&path, body)?;
        Ok((dir, path))
    }

    #[test]
    fn commands_carry_the_line_of_their_item() -> TestResult {
        let (_dir, path) = write_flow(concat!(
            "appId: com.example.app\n",
            "---\n",
            "- launchApp\n",
            "# a comment\n",
            "- tapOn:\n",
            "    text: \"Login\"\n",
            "- repeat:\n",
            "    times: 2\n",
            "    commands:\n",
            "      - tapOn: \"Next\"\n",
            "      - scroll\n",
        ))?;
        let flow = FlowFile::load(&path)?;
        let lines: Vec<_> = flow.commands.iter().map(|c| c.location.line).collect();
        assert_eq!(lines, vec![Some(3), Some(5), Some(7)]);
        let repeat = flow.commands.get(2).ok_or("no repeat")?;
        let (_, args) = repeat.name_and_args()?;
        let nested_values = match args.get("commands") {
            Some(Value::Sequence(values)) => values.clone(),
            _ => return Err("no nested commands".into()),
        };
        let nested = flow.nested(repeat, "commands", nested_values);
        let nested_lines: Vec<_> = nested.iter().map(|c| c.location.line).collect();
        assert_eq!(nested_lines, vec![Some(10), Some(11)]);
        assert_eq!(
            nested.get(1).map(|c| c.location.path.as_str()),
            Some("command 3 › commands 2")
        );
        Ok(())
    }

    #[test]
    fn a_flow_without_a_header_is_a_bare_command_list() -> TestResult {
        let (_dir, path) = write_flow("- launchApp\n- scroll\n")?;
        let flow = FlowFile::load(&path)?;
        assert!(flow.header.is_empty());
        assert_eq!(flow.commands.len(), 2);
        assert_eq!(flow.commands.get(1).and_then(|c| c.location.line), Some(2));
        Ok(())
    }

    #[test]
    fn a_header_with_no_command_list_is_refused() -> TestResult {
        let (_dir, path) = write_flow("appId: com.example.app\n")?;
        match FlowFile::load(&path) {
            Err(MaestroError::Shape { .. }) => Ok(()),
            other => Err(format!("expected Shape, got {other:?}").into()),
        }
    }
}
