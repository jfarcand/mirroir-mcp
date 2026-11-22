# Playwright setup

`mirroir-run` compiles scenario web steps to a Playwright `.spec.ts` and
runs them via `npx playwright test`. This document covers the one-time
installation and how `MIRROIR_PLAYWRIGHT_HOME` connects the two.

Source of truth: `runner/src/compile/invoke.rs`.

## One-time setup (local dev)

```bash
# 1. Pick a stable location for Playwright + node_modules. Anywhere works;
#    using /opt is conventional on Linux, $HOME elsewhere.
export MIRROIR_PLAYWRIGHT_HOME=$HOME/.cache/mirroir-playwright
mkdir -p "$MIRROIR_PLAYWRIGHT_HOME"
cd "$MIRROIR_PLAYWRIGHT_HOME"

# 2. Initialize a minimal Node package + install @playwright/test.
npm init -y > /dev/null
npm install --no-save @playwright/test

# 3. Install browsers. chromium is what the mega-sample needs; firefox + webkit
#    are required for cross-browser scenarios.
npx playwright install chromium                          # ~120 MB
npx playwright install firefox webkit                    # +~500 MB

# 4. Optional: persist MIRROIR_PLAYWRIGHT_HOME in your shell rc.
echo 'export MIRROIR_PLAYWRIGHT_HOME=$HOME/.cache/mirroir-playwright' >> ~/.zshrc
```

## How `MIRROIR_PLAYWRIGHT_HOME` is consumed

When the runner is about to invoke `npx playwright test`, it:

1. Recreates the scenario's workspace, `target/playwright/<sample>/<scenario>/`.
2. Writes the emitted `playwright.config.ts` + `<scenario>.spec.ts` into it.
3. If `MIRROIR_PLAYWRIGHT_HOME` is set and points at a directory containing
   `node_modules/`, **symlinks** that `node_modules/` into the workspace.
4. Spawns `npx playwright test --config … <scenario>.spec.ts` with `cwd` set
   to the workspace.

Result: Node's module resolution from the workspace's `playwright.config.ts`
finds `@playwright/test` via the symlink. No copying, no per-run `npm install`.

If `MIRROIR_PLAYWRIGHT_HOME` is unset, the runner still attempts `npx`, but
relies on `@playwright/test` being globally resolvable. That works only when
the user has installed it globally — most setups should set
`MIRROIR_PLAYWRIGHT_HOME`.

## CI setup

Every lane that drives a browser — `runner-smoke`, `runner-full-loop`,
`runner-e2e`, `runner-e2e-allbrowsers` — provisions Playwright through one
composite action, `.github/actions/setup-playwright`, so the provisioning
cannot drift between them. The calling job supplies
`MIRROIR_PLAYWRIGHT_HOME`; the action installs Node, restores the browser
cache, and runs `npm install @playwright/test` + `npx playwright install`
into it.

```yaml
env:
  MIRROIR_PLAYWRIGHT_HOME: /tmp/mirroir-pw

- name: Setup Playwright + chromium
  uses: ./.github/actions/setup-playwright

# …or, for the all-browsers lane:
- name: Setup Playwright + all browsers
  uses: ./.github/actions/setup-playwright
  with:
    browsers: chromium firefox webkit
    cache-key: allbrowsers-v1
    with-deps: 'true'          # Linux-only; firefox/webkit need the OS libs
```

The Playwright browsers cache is keyed by OS — `actions/cache@v4` keys are
global, so a Linux entry would otherwise collide with the macOS entry — and by
`cache-key`, so the chromium-only lanes and the all-browsers lane keep separate
entries.

## What the runner emits

Given this scenario:

```yaml
version: 1
name: smoke
steps:
  - target: { kind: web, browsers: [chrome, firefox, webkit], url: "http://localhost:8081/" }
  - wait_for: "Connected"
  - tap: "Send"
  - assert_visible: "delivered"
```

The runner generates:

```typescript
// playwright.config.ts
import { defineConfig, devices } from '@playwright/test';
export default defineConfig({
  reporter: [['json', { outputFile: 'playwright-report.json' }]],
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox',  use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit',   use: { ...devices['Desktop Safari'] } },
  ],
});

// scenario.spec.ts
import { test, expect } from '@playwright/test';
// Helper: pass through raw CSS and Playwright locator-engine strings
// (role=, text=, xpath=, css=, id=, data-testid=); otherwise resolve a
// bare label in Playwright's own locator priority — role, then label,
// then placeholder, then the data-test attribute, then visible text.
const _by = (page, label) => {
  if (/^[\[#.:>*]/.test(label)) return page.locator(label);
  if (/^(role|text|xpath|css|id|data-testid)=/.test(label)) return page.locator(label);
  return page.getByRole('button', { name: label, exact: true })
    .or(page.getByRole('link', { name: label, exact: true }))
    .or(page.getByLabel(label, { exact: true }))
    .or(page.getByPlaceholder(label, { exact: true }))
    .or(page.locator(`[data-test="${label}"]`))
    .or(page.getByText(label, { exact: true }));
};

test("smoke", async ({ page }) => {
  const _captures = { metrics: {}, judge: {}, cross_surface: {}, page_errors: [], failed_requests: [] };
  _watch(page, _captures);
  await page.goto("http://localhost:8081/");
  await _by(page, "Connected").waitFor({ state: 'visible', timeout: 30000 });
  await _by(page, "Send").click({ timeout: 30000 });
  await expect(_by(page, "delivered")).toBeVisible({ timeout: 30000 });
  await test.info().attach('mirroir-captures', { body: JSON.stringify(_captures), contentType: 'application/json' });
  expect(_captures.page_errors, 'uncaught page errors').toEqual([]);
  expect(_captures.failed_requests, 'failed requests').toEqual([]);
});
```

`_watch` is the browser-side half of `assert_log_clean`: every compiled spec
collects uncaught exceptions (`pageerror`) and failed responses for the
resource types a page depends on (`document`, `script`, `stylesheet`, `fetch`,
`xhr`), and asserts both are empty. A page that throws is a failure even when
every locator resolved.

You can compile any scenario to disk without running it:

```bash
mirroir-run --emit playwright path/to/scenario.yaml
mirroir-run --emit playwright samples/web-fixture --scenarios all
```

Both write `target/playwright/<sample>/<scenario>/` — the `.spec.ts`, the
`playwright.config.ts`, and (after a run) `playwright-report.json`,
`report-html/`, and `test-results/<test>/trace.zip` + `video.webm` +
`test-failed-1.png`. A run writes the same directory, so the spec a reviewer
reads is the spec Playwright executes.

## Reporter ingest

`mirroir-run` reads `playwright-report.json` after the invocation and returns
both an aggregate verdict and the values the spec attached:

```rust
pub struct ReporterOutcome {
    pub verdict: ReporterVerdict,       // passed / failed / skipped / flaky
    pub captures: RunCaptures,          // metrics / judge / cross_surface
}
```

A non-zero `failed` count maps to `ReportError::TestFailures`, which
carries each failing test's title and the reporter's own error message — the
strict-mode locator text, the timeout, the assertion diff — so `samples[].error`
in the run summary names what failed instead of counting it. In `--sample` mode
the overall verdict aggregates as `SampleScenarioFailures`, whose `first_error`
carries that message forward.

## The captures attachment

Every compiled spec closes with:

```typescript
await test.info().attach('mirroir-captures', {
  body: JSON.stringify(_captures), contentType: 'application/json',
});
```

`_captures` holds `metrics` (a `measure:` step's elapsed milliseconds, keyed by
its name) and `judge` / `cross_surface` (text scraped from the live page, keyed
by the scenario step index that asked for it). The JSON reporter base64-encodes
attachment bodies; the runner decodes them and hands the values to the
post-hooks. This is the only channel between the page and Rust — no scraped
value is written to a side-channel file.

## There is no way to skip the web run

A scenario's web steps are its assertions. A lane that cannot run them has not
tested anything, so the runner has no flag that skips the invocation and calls
the rest a pass: with `npx` off `PATH` it fails with
`PlaywrightError::NotInstalled` and the scenario exits non-zero.

Install Node and Playwright in every lane that replays web scenarios — see
`runner-smoke` and `runner-e2e` in `.github/workflows/runner.yml` for the
install + cache pattern. A scenario with no web steps at all (process / HTTP /
judge / cross-surface only) needs neither.

## Selector strategy

The `_by(page, label)` helper in every emitted spec resolves a mirroir
label by trying, in order:

1. Raw CSS / `page.locator(label)` pass-through when the label starts with a
   CSS-selector character (`[`, `#`, `.`, `:`, `>`, `*`).
2. Playwright locator-engine pass-through when the label is prefixed with an
   engine (`role=`, `text=`, `xpath=`, `css=`, `id=`, `data-testid=`).
3. A bare label resolves through Playwright's own locator priority, as one
   `.or()` union: `getByRole('button')` → `getByRole('link')` → `getByLabel`
   → `getByPlaceholder` → `[data-test="<label>"]` → `getByText(exact)`.

Raw CSS and the `role=` / `text=` (and other engine-prefixed) forms therefore
already work — pass them as the label directly. Authors who want a different
strategy write the engine-prefixed form, or compile with
`mirroir-run --emit playwright` and read the resulting `.spec.ts`.
