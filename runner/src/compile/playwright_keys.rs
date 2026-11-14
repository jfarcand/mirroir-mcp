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
// ABOUTME: Translates mirroir's friendly key / modifier / swipe names into Playwright equivalents.
// ABOUTME: Pure string mapping — no emission, no I/O, so the tables stay readable next to each other.

/// Wheel delta, in CSS pixels, one `swipe:` step scrolls by.
const SWIPE_DELTA_PX: i32 = 300;

/// Build a Playwright key-press string like `"Control+Shift+KeyA"`. Mirroir
/// uses friendly names ("return", "escape", "command"); map them to the
/// equivalents Playwright's keyboard understands.
#[must_use]
pub fn playwright_key_combo(key: &str, modifiers: &[String]) -> String {
    let mut parts: Vec<String> = modifiers.iter().map(|m| map_modifier(m)).collect();
    parts.push(map_key(key));
    parts.join("+")
}

fn map_modifier(name: &str) -> String {
    match name.to_lowercase().as_str() {
        "command" | "cmd" | "meta" => "Meta".to_owned(),
        "control" | "ctrl" => "Control".to_owned(),
        "shift" => "Shift".to_owned(),
        "alt" | "option" => "Alt".to_owned(),
        other => capitalize(other),
    }
}

fn map_key(name: &str) -> String {
    match name.to_lowercase().as_str() {
        "return" | "enter" => "Enter".to_owned(),
        "escape" | "esc" => "Escape".to_owned(),
        "tab" => "Tab".to_owned(),
        "backspace" | "delete" => "Backspace".to_owned(),
        "space" => "Space".to_owned(),
        "arrowup" | "up" => "ArrowUp".to_owned(),
        "arrowdown" | "down" => "ArrowDown".to_owned(),
        "arrowleft" | "left" => "ArrowLeft".to_owned(),
        "arrowright" | "right" => "ArrowRight".to_owned(),
        other => capitalize(other),
    }
}

fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    chars.next().map_or_else(String::new, |c| {
        let rest: String = chars.collect();
        format!("{}{rest}", c.to_uppercase())
    })
}

/// The `(deltaX, deltaY)` a `swipe: <direction>` step scrolls by. A swipe up
/// reveals content above, which is a negative wheel delta.
#[must_use]
pub fn swipe_delta(direction: &str) -> (i32, i32) {
    match direction.to_lowercase().as_str() {
        "up" => (0, -SWIPE_DELTA_PX),
        "down" => (0, SWIPE_DELTA_PX),
        "left" => (-SWIPE_DELTA_PX, 0),
        "right" => (SWIPE_DELTA_PX, 0),
        _ => (0, 0),
    }
}

#[cfg(test)]
mod tests {
    use super::{playwright_key_combo, swipe_delta};

    #[test]
    fn modifiers_and_keys_map_to_playwright_names() {
        assert_eq!(
            playwright_key_combo("return", &["command".to_owned(), "shift".to_owned()]),
            "Meta+Shift+Enter"
        );
        assert_eq!(playwright_key_combo("esc", &[]), "Escape");
        assert_eq!(playwright_key_combo("a", &["ctrl".to_owned()]), "Control+A");
    }

    #[test]
    fn unknown_directions_scroll_nowhere() {
        assert_eq!(swipe_delta("up"), (0, -300));
        assert_eq!(swipe_delta("RIGHT"), (300, 0));
        assert_eq!(swipe_delta("sideways"), (0, 0));
    }
}
