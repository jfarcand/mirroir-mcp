// ABOUTME: Unit tests for the Maestro → mirroir mapping table — every mapped command, and the refusals.
// ABOUTME: Expected steps are written as scenario YAML and parsed by the runner's own parser, so both sides use one grammar.

use std::error::Error as StdError;
use std::result::Result as StdResult;

use serde_norway::with::singleton_map_recursive;
use serde_norway::{Mapping, Value};

use super::*;
use crate::maestro::refused::refused_commands;
use crate::parser::scenario::Scenario;
use crate::parser::step::SkillStep;

type TestResult = StdResult<(), Box<dyn StdError>>;

/// The bundle id the tests' flows launch, and the name `--app` maps it to.
const APP_ID: &str = "com.example.shop";
const APP_NAME: &str = "Shop";

/// The documentation page whose mapping table must name every refusal.
const DOCS: &str = include_str!("../../docs/maestro-import.md");

fn apps() -> StdResult<AppNames, Box<dyn StdError>> {
    Ok(AppNames::parse(&[format!("{APP_ID}={APP_NAME}")])?)
}

fn yaml(text: &str) -> StdResult<Value, Box<dyn StdError>> {
    Ok(serde_norway::from_str(text)?)
}

/// Map `name: <args>` and parse the result through the runner's parser.
fn mapped(
    name: &str,
    args: &str,
) -> StdResult<StdResult<Vec<SkillStep>, String>, Box<dyn StdError>> {
    let apps = apps()?;
    let scope = EnvScope::default();
    let ctx = LeafContext {
        app_id: Some(APP_ID),
        apps: &apps,
        scope: &scope,
    };
    let values = match map_leaf(name, &yaml(args)?, ctx) {
        Ok(values) => values,
        Err(reason) => return Ok(Err(reason)),
    };
    let mut steps = Vec::new();
    for value in values {
        let mut map = Mapping::new();
        map.insert(value.kind.into(), value.args);
        steps.push(singleton_map_recursive::deserialize(Value::Mapping(map))?);
    }
    Ok(Ok(steps))
}

/// The steps `body` (a YAML step list) parses to.
fn expected(body: &str) -> StdResult<Vec<SkillStep>, Box<dyn StdError>> {
    let scenario: Scenario =
        serde_norway::from_str(&format!("version: 1\nname: expected\nsteps:\n{body}"))?;
    Ok(scenario.steps)
}

fn assert_maps(name: &str, args: &str, body: &str) -> TestResult {
    let got = mapped(name, args)?.map_err(|reason| format!("{name} {args}: refused: {reason}"))?;
    assert_eq!(got, expected(body)?, "{name} {args}");
    Ok(())
}

fn assert_refused(name: &str, args: &str, needle: &str) -> TestResult {
    match mapped(name, args)? {
        Err(reason) if reason.contains(needle) => Ok(()),
        Err(reason) => Err(format!("{name} {args}: reason `{reason}` lacks `{needle}`").into()),
        Ok(steps) => Err(format!("{name} {args}: crossed as {steps:?}").into()),
    }
}

#[test]
fn launch_and_stop_use_the_app_name_and_force_quit_first() -> TestResult {
    assert_maps(
        "launchApp",
        "null",
        "  - reset_app: \"Shop\"\n  - launch: \"Shop\"\n",
    )?;
    assert_maps("launchApp", "{ stopApp: false }", "  - launch: \"Shop\"\n")?;
    assert_maps("stopApp", "null", "  - reset_app: \"Shop\"\n")?;
    assert_maps("killApp", "com.example.shop", "  - reset_app: \"Shop\"\n")?;
    assert_refused("launchApp", "com.other.app", "--app com.other.app=")?;
    assert_refused("launchApp", "{ clearState: true }", "clearState")?;
    assert_refused("launchApp", "{ arguments: { a: 1 } }", "arguments")?;
    Ok(())
}

#[test]
fn taps_target_ocr_text_and_unroll_repeat() -> TestResult {
    assert_maps("tapOn", "Login", "  - tap: \"Login\"\n")?;
    assert_maps("tapOn", "{ text: \".*Save.*\" }", "  - tap: \"Save\"\n")?;
    assert_maps(
        "tapOn",
        "{ text: Plus, repeat: 3 }",
        "  - tap: \"Plus\"\n  - tap: \"Plus\"\n  - tap: \"Plus\"\n",
    )?;
    assert_maps("longPressOn", "Photo", "  - long_press: \"Photo\"\n")?;
    assert_refused("tapOn", "{ id: login_button }", "accessibility tree")?;
    assert_refused("tapOn", "{ point: \"50%,50%\" }", "coordinate")?;
    assert_refused("tapOn", "{ text: Go, index: 1 }", "nth-match")?;
    assert_refused("tapOn", "{ text: Go, delay: 200, repeat: 2 }", "delay")?;
    assert_refused("tapOn", "\"Order [0-9]+\"", "regular expression")?;
    Ok(())
}

#[test]
fn text_entry_and_keys_map_to_type_and_press_key() -> TestResult {
    assert_maps("inputText", "\"${EMAIL}\"", "  - type: \"${EMAIL}\"\n")?;
    assert_maps("inputText", "{ text: hello }", "  - type: \"hello\"\n")?;
    assert_maps(
        "eraseText",
        "2",
        "  - press_key: \"delete\"\n  - press_key: \"delete\"\n",
    )?;
    let default_erase = mapped("eraseText", "null")??;
    assert_eq!(default_erase.len(), 50);
    assert_refused("eraseText", "101", "at most 100")?;
    assert_maps("pressKey", "Enter", "  - press_key: \"return\"\n")?;
    assert_maps("pressKey", "backspace", "  - press_key: \"delete\"\n")?;
    assert_maps("pressKey", "Home", "  - home:\n")?;
    assert_refused("pressKey", "volume up", "hardware button")?;
    assert_refused("pressKey", "back", "Android-only")?;
    Ok(())
}

#[test]
fn scrolls_and_swipes_cross_only_with_their_defaults() -> TestResult {
    assert_maps("scroll", "null", "  - swipe: \"up\"\n")?;
    assert_maps("swipe", "{ direction: LEFT }", "  - swipe: \"left\"\n")?;
    assert_refused(
        "swipe",
        "{ start: \"90%, 50%\", end: \"10%, 50%\" }",
        "`start`",
    )?;
    assert_refused("swipe", "{ direction: UP, duration: 2000 }", "`duration`")?;
    assert_maps(
        "scrollUntilVisible",
        "{ element: Privacy, direction: DOWN, timeout: 20000 }",
        "  - scroll_to: \"Privacy\"\n",
    )?;
    assert_refused(
        "scrollUntilVisible",
        "{ element: Privacy, direction: UP }",
        "direction",
    )?;
    assert_refused(
        "scrollUntilVisible",
        "{ element: Privacy, timeout: 5000 }",
        "budget",
    )?;
    assert_refused(
        "scrollUntilVisible",
        "{ element: { id: row } }",
        "accessibility",
    )?;
    Ok(())
}

#[test]
fn assertions_and_waits_keep_maestro_timeouts() -> TestResult {
    assert_maps(
        "assertVisible",
        "Welcome",
        "  - wait_for: { label: \"Welcome\", timeout_s: 7 }\n",
    )?;
    assert_maps(
        "assertNotVisible",
        "Error",
        "  - assert_not_visible: \"Error\"\n",
    )?;
    assert_maps(
        "extendedWaitUntil",
        "{ visible: Done, timeout: 10500 }",
        "  - wait_for: { label: \"Done\", timeout_s: 11 }\n",
    )?;
    assert_refused(
        "extendedWaitUntil",
        "{ notVisible: Spinner, timeout: 1000 }",
        "wait-until-gone",
    )?;
    assert_refused(
        "extendedWaitUntil",
        "{ visible: Done }",
        "`timeout` is required",
    )?;
    Ok(())
}

#[test]
fn links_screenshots_and_airplane_mode_map_directly() -> TestResult {
    assert_maps(
        "openLink",
        "\"https://example.com\"",
        "  - open_url: \"https://example.com\"\n",
    )?;
    assert_maps(
        "openLink",
        "{ link: \"shop://cart\" }",
        "  - open_url: \"shop://cart\"\n",
    )?;
    assert_refused(
        "openLink",
        "{ link: \"https://x.dev\", autoVerify: true }",
        "autoVerify",
    )?;
    assert_maps("takeScreenshot", "home", "  - screenshot: \"home\"\n")?;
    assert_maps(
        "setAirplaneMode",
        "enabled",
        "  - set_network: \"airplane_on\"\n",
    )?;
    assert_maps(
        "setAirplaneMode",
        "disabled",
        "  - set_network: \"airplane_off\"\n",
    )?;
    Ok(())
}

/// Every command in the refusal table is refused with its reason, and the
/// documentation's mapping table names it, so the two cannot drift apart.
#[test]
fn every_refused_command_is_refused_and_documented() -> TestResult {
    for command in refused_commands() {
        let reason = refusal(command).ok_or("table lookup failed")?;
        assert_refused(command, "null", reason)?;
        assert!(
            DOCS.contains(&format!("`{command}`")),
            "docs/maestro-import.md does not list `{command}`"
        );
    }
    assert_refused("fooBar", "null", "not a Maestro command")?;
    Ok(())
}
