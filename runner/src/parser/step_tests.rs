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
// ABOUTME: Unit tests for the SkillStep grammar — string and shorthand steps, conditions, and target blocks.
// ABOUTME: Included by step.rs as its `tests` module, so `super::` names the step types.

use std::error::Error as StdError;

use serde_norway::Deserializer;
use serde_norway::with::singleton_map_recursive;

use super::*;

type TestResult = StdResult<(), Box<dyn StdError>>;

fn parse(yaml: &str) -> StdResult<SkillStep, serde_norway::Error> {
    singleton_map_recursive::deserialize(Deserializer::from_str(yaml))
}

fn fail<T>(reason: String) -> StdResult<T, Box<dyn StdError>> {
    Err(reason.into())
}

#[test]
fn launch_string() -> TestResult {
    assert_eq!(
        parse("launch: \"Expo Go\"")?,
        SkillStep::Launch("Expo Go".to_owned())
    );
    Ok(())
}

#[test]
fn tap_string() -> TestResult {
    assert_eq!(
        parse("tap: \"Email\"")?,
        SkillStep::Tap(TapArgs::new("Email".to_owned()))
    );
    Ok(())
}

#[test]
fn wait_for_shorthand_and_full() -> TestResult {
    let short = parse("wait_for: \"Welcome\"")?;
    let full = parse("wait_for: { label: \"Welcome\", timeout_s: 30 }")?;
    let SkillStep::WaitFor(short_args) = short else {
        return fail("expected WaitFor, got other variant".to_owned());
    };
    let SkillStep::WaitFor(full_args) = full else {
        return fail("expected WaitFor, got other variant".to_owned());
    };
    assert_eq!(short_args.label, "Welcome");
    assert!(short_args.timeout_s.is_none());
    assert_eq!(full_args.label, "Welcome");
    assert_eq!(full_args.timeout_s, Some(30));
    Ok(())
}

#[test]
fn home_unit_variant_with_null() -> TestResult {
    assert!(matches!(parse("home: null")?, SkillStep::Home(_)));
    Ok(())
}

#[test]
fn condition_with_then_and_else() -> TestResult {
    let yaml = r#"
condition:
  if_visible: "Invalid"
  then:
    - tap: "Sign Up"
  else:
    - wait_for: "Welcome"
"#;
    let SkillStep::Condition(c) = parse(yaml)? else {
        return fail("expected Condition variant".to_owned());
    };
    assert_eq!(c.if_visible, "Invalid");
    assert_eq!(c.then.len(), 1);
    let Some(else_steps) = c.else_steps else {
        return fail("expected else_steps to be Some".to_owned());
    };
    assert_eq!(else_steps.len(), 1);
    Ok(())
}

#[test]
fn target_web_with_browsers() -> TestResult {
    let yaml = r#"
target:
  kind: web
  browsers: [chrome, firefox, webkit]
  url: "http://localhost:8081/"
"#;
    let SkillStep::Target(args) = parse(yaml)? else {
        return fail("expected Target variant".to_owned());
    };
    assert_eq!(args.kind, TargetKind::Web);
    assert_eq!(
        args.browsers,
        vec![Browser::Chrome, Browser::Firefox, Browser::Webkit]
    );
    assert_eq!(args.url.as_deref(), Some("http://localhost:8081/"));
    Ok(())
}

/// `web` is the one surface a `target:` can declare here — it compiles to
/// Playwright and `ios` to one `mirroir-mcp test`. `macos` windows are
/// `mirroir-mcp test`'s directly, and `process` and `http` name no executor
/// of their own: their work is dispatched by `spawn:` / `http:` steps,
/// which need no `target:` at all.
#[test]
fn web_and_ios_are_the_surfaces_a_block_opens() {
    for kind in [TargetKind::Web, TargetKind::Ios] {
        assert!(kind.runner_executes(), "{kind:?} opens a block");
    }
    for kind in [TargetKind::Process, TargetKind::Http, TargetKind::Macos] {
        assert!(
            !kind.runner_executes(),
            "{kind:?} names no executor a `target:` opens"
        );
    }
}
