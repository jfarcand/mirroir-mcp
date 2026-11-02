// ABOUTME: The `.mirroir/` tree the full-loop suite plants — archetype, plan, scenario — plus the fixture mutations it drives.
// ABOUTME: One place to read what an adopter's repository looks like to mirroir-run, and what "reworded" and "broken" mean.

use std::fs;
use std::path::Path;

use super::{Sandbox, fixture_summary_text};

/// Plan-entry name. Also the composed sample's directory under `.build/`, and
/// therefore the first component of `target/playwright/<sample>/<scenario>/`.
pub const SAMPLE_NAME: &str = "order-desk";

/// The archetype's single flow, and the scenario file's stem.
pub const FLOW: &str = "full-loop";

/// Scenario `name:`. The baseline store and the drift log are keyed by it.
pub const SCENARIO_NAME: &str = "web-fixture — boot, browser, capture, oracle, verdict";

/// Plant `.mirroir/archetypes/order-desk/` — manifest, APP.md, and the one
/// scenario that is the whole loop.
///
/// # Errors
///
/// Returns the failure text when any file cannot be written.
pub fn plant_archetype(sandbox: &Sandbox, port: u16) -> Result<(), String> {
    sandbox.write(
        ".mirroir/archetypes/order-desk/archetype.md",
        concat!(
            "# order-desk\n\n",
            "```yaml\n",
            "version: 1\n",
            "name: web-fixture/order-desk\n",
            "archetype_version: 1.0.0\n",
            "provides:\n",
            "  flows:\n",
            "    - full-loop\n",
            "```\n",
        ),
    )?;
    sandbox.write(
        ".mirroir/archetypes/order-desk/APP.md",
        &format!(
            concat!(
                "# order-desk\n\n",
                "```yaml\n",
                "version: 1\n",
                "app: order-desk\n",
                "surface: web\n",
                "url: \"http://127.0.0.1:{port}/summary.html\"\n",
                "```\n\n",
                "| Element | Selector |\n",
                "|---|---|\n",
                "| Order button | `[data-test=place-order]` |\n",
                "| Confirmation | `[data-test=order-summary]` |\n",
            ),
            port = port
        ),
    )?;
    sandbox.write(
        ".mirroir/archetypes/order-desk/scenarios/full-loop.yaml",
        &scenario_yaml(port),
    )?;
    Ok(())
}

/// Plant `.mirroir/mirroir.yaml` and return its absolute path.
///
/// `boot_once: false` is the load-bearing choice: the scenario owns the
/// server's whole lifecycle, so its `kill:` is a real kill rather than the
/// no-op a session-shared boot turns it into, and `assert_log_clean:` reads the
/// log of the process the scenario itself started.
///
/// # Errors
///
/// Returns the failure text when the file cannot be written.
pub fn plant_plan(sandbox: &Sandbox, port: u16) -> Result<String, String> {
    let site = sandbox.path().join("site").display().to_string();
    sandbox.write(
        ".mirroir/mirroir.yaml",
        &format!(
            concat!(
                "version: 1\n",
                "plan:\n",
                "  must_pass:\n",
                "    - name: {name}\n",
                "      archetypes: [\"./archetypes/order-desk\"]\n",
                "      flows: [{flow}]\n",
                "      boot:\n",
                "        command: \"python3 -c \\\"import http.server as h, socketserver as s; h.ThreadingHTTPServer.server_bind = s.TCPServer.server_bind; h.ThreadingHTTPServer(('127.0.0.1', {port}), h.SimpleHTTPRequestHandler).serve_forever()\\\"\"\n",
                "        cwd: \"{site}\"\n",
                "        boot_once: false\n"
            ),
            name = SAMPLE_NAME,
            flow = FLOW,
            port = port,
            site = site
        ),
    )
}

/// The scenario: process lifecycle in Rust, one contiguous web block in
/// Playwright, and the oracle + HTTP + teardown hooks after it.
fn scenario_yaml(port: u16) -> String {
    format!(
        concat!(
            "version: 1\n",
            "name: {name}\n",
            "description: |\n",
            "  The whole loop in one scenario: boot the static site, drive it in one\n",
            "  browser run, let the confirmation leave the page on the captures\n",
            "  attachment, judge it in Rust, probe the server over HTTP, tear it down,\n",
            "  and read its log. Every non-web step is a runner-side hook around the\n",
            "  single Playwright invocation the web block compiles to.\n",
            "tags: [\"web-fixture\", \"e2e\", \"full-loop\"]\n",
            "drift:\n",
            "  # The scenario's subject is the confirmation's wording, so its own\n",
            "  # ceiling is tighter than the global default.\n",
            "  response_levenshtein_pct: {{ max: 0.20 }}\n",
            "steps:\n",
            "  - spawn: {{ id: fixture, from: SAMPLE.md }}\n",
            "  - wait_port: {{ port: {port}, timeout_s: 20 }}\n",
            "  - target:\n",
            "      kind: web\n",
            "      browsers: [chrome]\n",
            "      url: \"http://127.0.0.1:{port}/summary.html\"\n",
            "  - assert_visible: \"page-title\"\n",
            "  - tap: \"place-order\"\n",
            "  - wait_for: {{ label: \"order-summary\", timeout_s: 10 }}\n",
            "  - assert_not_visible:\n",
            "      label: \"order-summary\"\n",
            "      contains: \"{unclicked}\"\n",
            "      timeout_s: 10\n",
            "  - judge:\n",
            "      profile: byte-stable\n",
            "      user_prompt_template_hash: \"{hash}\"\n",
            "      response_selector: \"[data-test=order-summary]\"\n",
            "      pass_threshold: 0.6\n",
            "      pass_threshold_tolerance: 0.2\n",
            "      expected_signal: \"confirms the order was placed and names the price\"\n",
            "  - http:\n",
            "      method: GET\n",
            "      url: \"http://127.0.0.1:{port}/summary.html\"\n",
            "      expect_status: 200\n",
            "      expect_body_contains: [\"data-test=\\\"place-order\\\"\"]\n",
            "  - kill: {{ id: fixture, grace_s: 3 }}\n",
            "  - assert_log_clean:\n",
            "      id: fixture\n",
            "      deny:\n",
            "        - {{ pattern: \"Traceback \\\\(most recent call last\\\\)\" }}\n",
            "  - remember: \"boot → browser → capture → oracle → HTTP → teardown, in one run\"\n"
        ),
        name = SCENARIO_NAME,
        port = port,
        unclicked = super::full_loop::UNCLICKED_SUMMARY,
        hash = super::full_loop::JUDGE_PROMPT_HASH
    )
}

/// Reword the served `summary.html` to the confirmation its shipped twin
/// renders: same button, same attributes, same state change, different prose.
///
/// # Errors
///
/// Returns the failure text when either page no longer carries the sentence the
/// mutation swaps, which means the fixture moved and the suite's premise with it.
pub fn reword_summary(page: &Path) -> Result<String, String> {
    let baseline = fixture_summary_text("summary.html")?;
    let reworded = fixture_summary_text("summary-reworded.html")?;
    if baseline == reworded {
        return Err("the fixture's drift pair no longer differs in wording".to_owned());
    }
    replace_once(page, &baseline, &reworded)?;
    Ok(reworded)
}

/// Break the served `summary.html`'s behavior while leaving its DOM alone: the
/// order button is bound to an event that never fires, so every locator still
/// resolves and the click no longer does anything.
///
/// # Errors
///
/// Returns the failure text when the page no longer binds a click handler.
pub fn break_summary(page: &Path) -> Result<(), String> {
    replace_once(page, "addEventListener('click'", &dead_listener())
}

/// Undo [`break_summary`].
///
/// # Errors
///
/// Returns the failure text when the page was not broken.
pub fn restore_summary(page: &Path) -> Result<(), String> {
    replace_once(page, &dead_listener(), "addEventListener('click'")
}

fn dead_listener() -> String {
    format!("addEventListener('{}'", super::full_loop::DEAD_EVENT)
}

/// Rewrite `page`, replacing the single occurrence of `from` with `to`.
fn replace_once(page: &Path, from: &str, to: &str) -> Result<(), String> {
    let body = fs::read_to_string(page).map_err(|e| format!("read {}: {e}", page.display()))?;
    let occurrences = body.matches(from).count();
    if occurrences != 1 {
        return Err(format!(
            "{} carries `{from}` {occurrences} times; expected exactly one",
            page.display()
        ));
    }
    fs::write(page, body.replace(from, to)).map_err(|e| format!("write {}: {e}", page.display()))
}

/// Edit one byte inside the locked archetype tree, and name the file it
/// touched. The ref string and the version pin are untouched: only the tree's
/// content moved, which is the case a ref-set diff cannot answer.
///
/// # Errors
///
/// Returns the failure text when the manifest no longer carries the name this
/// edits.
pub fn plant_archetype_tamper(archetype_dir: &Path) -> Result<String, String> {
    replace_once(
        &archetype_dir.join("archetype.md"),
        "web-fixture/order-desk",
        "web-fixture/order-desK",
    )?;
    Ok("archetype.md".to_owned())
}
