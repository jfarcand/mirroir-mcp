// ABOUTME: Unit tests for the Maestro flow walker — env scoping, includes, platform conditions, hooks, rendering.
// ABOUTME: Flows are written to a temp dir; every rendered scenario is read back by the runner's own loader.

use std::error::Error as StdError;
use std::fs;
use std::path::PathBuf;
use std::result::Result as StdResult;

use tempfile::TempDir;

use super::*;
use crate::maestro::emit::render_scenario;

type TestResult = StdResult<(), Box<dyn StdError>>;

struct Flows {
    dir: TempDir,
}

impl Flows {
    fn new() -> StdResult<Self, Box<dyn StdError>> {
        Ok(Self {
            dir: TempDir::new()?,
        })
    }

    fn write(&self, name: &str, body: &str) -> StdResult<PathBuf, Box<dyn StdError>> {
        let path = self.dir.path().join(name);
        fs::write(&path, body)?;
        Ok(path)
    }
}

fn shop() -> StdResult<AppNames, Box<dyn StdError>> {
    Ok(AppNames::parse(&["com.example.shop=Shop".to_owned()])?)
}

fn steps(flow: &ImportedFlow) -> Vec<&SkillStep> {
    flow.lines
        .iter()
        .filter_map(|line| match line {
            Line::Step { step, .. } => Some(step.as_ref()),
            Line::Comment(_) | Line::Skipped(_) => None,
        })
        .collect()
}

#[test]
fn a_javascript_default_in_the_header_becomes_a_runner_default() -> TestResult {
    let flows = Flows::new()?;
    let path = flows.write(
        "flow.yaml",
        "appId: com.example.shop\nenv:\n  USER: ${USER_ID || \"guest\"}\n---\n- inputText: ${USER}\n",
    )?;
    let flow = import_flow(&path, &shop()?)?;
    assert!(flow.unsupported.is_empty(), "{:?}", flow.unsupported);
    let rendered = render_scenario(&flow)?;
    // The runner's `${VAR:-default}` form, built so it is not read as a
    // format string.
    let expected = format!("  - type: \"${{{}}}\"\n", "USER_ID:-guest");
    assert!(rendered.contains(&expected), "{rendered}");
    Ok(())
}

#[test]
fn run_flow_env_scopes_the_include_and_a_conflicting_header_is_refused() -> TestResult {
    let flows = Flows::new()?;
    flows.write(
        "sub.yaml",
        "appId: com.example.shop\nenv:\n  NAME: header\n---\n- inputText: ${NAME}\n",
    )?;
    flows.write("plain.yaml", "- inputText: ${NAME}\n")?;
    let path = flows.write(
        "main.yaml",
        concat!(
            "appId: com.example.shop\n",
            "---\n",
            "- runFlow: { file: plain.yaml, env: { NAME: passed } }\n",
            "- inputText: ${NAME}\n",
            "- runFlow: { file: sub.yaml, env: { NAME: passed } }\n",
        ),
    )?;
    let flow = import_flow(&path, &shop()?)?;
    let typed: Vec<String> = steps(&flow)
        .into_iter()
        .filter_map(|step| match step {
            SkillStep::Type(args) => Some(args.text.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(typed, vec!["passed", "${NAME}", "passed"]);
    let [conflict] = flow.unsupported.as_slice() else {
        return Err(format!("expected one conflict, got {:?}", flow.unsupported).into());
    };
    assert!(conflict.reason.contains("does not document which wins"));
    assert!(conflict.location.file.ends_with("sub.yaml"));
    Ok(())
}

#[test]
fn stop_then_launch_force_quits_once_and_on_flow_start_runs_first() -> TestResult {
    let flows = Flows::new()?;
    let path = flows.write(
        "flow.yaml",
        concat!(
            "appId: com.example.shop\n",
            "onFlowStart:\n",
            "  - tapOn: \"Accept cookies\"\n",
            "---\n",
            "- stopApp\n",
            "- launchApp\n",
        ),
    )?;
    let flow = import_flow(&path, &shop()?)?;
    let rendered = render_scenario(&flow)?;
    let body = rendered.split("steps:\n").nth(1).ok_or("no steps")?;
    assert_eq!(
        body,
        concat!(
            "  - target: { kind: \"ios\", app: \"Shop\" }\n",
            "  - tap: \"Accept cookies\"\n",
            "  - reset_app: \"Shop\"\n",
            "  - launch: \"Shop\"\n",
        )
    );
    Ok(())
}

#[test]
fn hooks_and_live_conditions_are_reported_with_their_lines() -> TestResult {
    let flows = Flows::new()?;
    let path = flows.write(
        "flow.yaml",
        concat!(
            "appId: com.example.shop\n",
            "onFlowComplete:\n",
            "  - stopApp\n",
            "---\n",
            "- runFlow:\n",
            "    when:\n",
            "      visible: \"Promo\"\n",
            "    commands:\n",
            "      - tapOn: \"Close\"\n",
            "- repeat:\n",
            "    times: 2\n",
            "    commands:\n",
            "      - tapOn: { text: Next }\n",
            "      - hideKeyboard\n",
            "- tapOn: \"Done\"\n",
            "  # trailing comment\n",
        ),
    )?;
    let flow = import_flow(&path, &shop()?)?;
    let found: Vec<(Option<usize>, &str)> = flow
        .unsupported
        .iter()
        .map(|item| (item.location.line, item.command.as_str()))
        .collect();
    assert_eq!(
        found,
        vec![
            (Some(2), "onFlowComplete"),
            (Some(5), "runFlow"),
            (Some(14), "hideKeyboard"),
        ]
    );
    assert_eq!(
        flow.unsupported
            .get(2)
            .map(|item| item.location.path.as_str()),
        Some("command 2 › commands 2")
    );
    // Skipped once per unrolled iteration, listed once.
    let skipped = flow
        .lines
        .iter()
        .filter(|line| matches!(line, Line::Skipped(item) if item.command == "hideKeyboard"))
        .count();
    assert_eq!(skipped, 2);
    Ok(())
}

#[test]
fn an_ios_platform_condition_runs_its_commands() -> TestResult {
    let flows = Flows::new()?;
    let path = flows.write(
        "flow.yaml",
        "- runFlow:\n    when: { platform: iOS }\n    commands:\n      - tapOn: \"Allow\"\n",
    )?;
    let flow = import_flow(&path, &AppNames::default())?;
    assert_eq!(flow.unsupported, Vec::<UnsupportedItem>::new());
    assert!(
        matches!(steps(&flow).as_slice(), [SkillStep::Target(_), SkillStep::Tap(tap)] if tap.label == "Allow")
    );
    Ok(())
}

/// A value the one-step-per-line dialect cannot carry is refused at import,
/// attributed to the Maestro command, not discovered when the block runs.
#[test]
fn a_value_the_ios_dialect_cannot_carry_is_unsupported() -> TestResult {
    let flows = Flows::new()?;
    let path = flows.write("flow.yaml", "- inputText: \"line one\\nline two\"\n")?;
    let flow = import_flow(&path, &AppNames::default())?;
    let [item] = flow.unsupported.as_slice() else {
        return Err(format!("expected one item, got {:?}", flow.unsupported).into());
    };
    assert_eq!(item.command, "inputText");
    assert!(item.reason.contains("spanning lines"), "{}", item.reason);
    Ok(())
}
