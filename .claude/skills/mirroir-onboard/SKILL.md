---
name: mirroir-onboard
description: Onboard a consumer web app to mirroir's .mirroir/ dotfile by EXPLORING the running app (chrome-devtools-mcp) — derive real selectors from the accessibility tree, exercise each surface's primary action, emit the .mirroir/ tree, and validate by LIVE REPLAY with a self-heal loop. Reject shallow "page renders" coverage.
allowed-tools:
  - "mcp__chrome-devtools__*"
  - "Read"
  - "Write"
  - "Edit"
  - "Bash"
  - "Glob"
  - "Grep"
  - "TaskCreate"
  - "TaskUpdate"
  - "TaskList"
---

# mirroir-onboard

You are the **web explorer**. You drive a consumer's running web app the way
an agent drives an iPhone in `generate_skill action=explore`: navigate, read
the live accessibility tree, find each surface's *primary action*, derive the
exact selector that resolves it, execute it, capture the resulting state change,
and emit a replayable `.mirroir/` suite. Then you **prove it by live replay**
and **self-heal** any selector that doesn't resolve.

The output is a `.mirroir/` tree at the consumer root that goes **green under
`mirroir-run`** (a real boot + real Playwright replay against the real backend),
not merely one that compiles. Compile-clean is necessary but not sufficient —
selectors that pass `--emit playwright` still fail at replay (wrong element,
strict-mode, or never resolves). The replay is the gate.

You do not hand-author from spec files. Every selector comes from a DOM you
observed via `mcp__chrome-devtools__take_snapshot`. You are mechanizing the
human loop, not transcribing a test plan.

---

## What makes this worth doing (read before you start)

A mocked Playwright/Cypress suite (`page.route(...)`) verifies the **frontend in
isolation** — it stays green even when the backend wiring, DB seed, auth gate,
dev proxy, or LLM path is broken. mirroir's only job is to catch exactly those:
**"the real stack boots and the headline journeys actually work."** If your
scenarios don't exercise real primary actions against the real backend, you've
rebuilt the mocked suite slower — delete them and stop.

So: **complementary, never a replacement.** Run
`find <root> -name '*.spec.ts' -o -name '*.cy.ts' | grep -v node_modules | wc -l`
first; if non-zero, the `mirroir.yaml` description must say "complementary" and
name that count. Assume an existing suite exists until proven otherwise.

---

## Phase 0 — Get the app to a usable, logged-in-able state

This is the phase that silently eats hours. A web app being "up on :PORT" does
**not** mean a real user can log in and reach an authenticated surface. Confirm
each link of the chain before exploring, because every one of these has bitten
real onboarding:

1. **Boot a genuinely fresh stack — kill stale processes first.** If a previous
   stack is still listening on the frontend port, a fresh boot's "wait for port"
   can race the old stack's teardown and you'll drive a dying server. Stop all
   services, confirm the port is **down**, then boot.

2. **Beware test-mode env flags — they often disable the real backend.** Many
   apps gate a dev proxy / mock layer on a flag like `E2E_TEST`, `CI`,
   `MOCK_API`. Their *own* mocked suite sets it so the frontend serves canned
   responses. For mirroir that is poison: with the proxy off, the login POST
   (e.g. `/oauth/token`) 404s and every authed scenario fails. **Do not set
   these flags.** If login fails, open the network panel / check the auth
   endpoint's status — a `404`/`502` on the auth POST means the proxy is off.

3. **IPv4 vs IPv6 loopback.** Dev servers (Vite's default `localhost`) often
   bind `[::1]` only, so `http://127.0.0.1:PORT` is refused while
   `http://localhost:PORT` works. Use `localhost` in scenario URLs, and know
   that any port-readiness probe must check both `127.0.0.1` and `[::1]`.

4. **The auth/onboarding gate may demand seeded state.** A user can authenticate
   yet be trapped on a "connect a provider / finish onboarding" wall that blocks
   every real surface — by design, and often *not* satisfied by the default
   seed. If a freshly-seeded user lands on such a gate, you cannot explore the
   app as them. Find which seeded user clears the gate (read the seeder), or
   surface to the user that the seed needs to make one demo user fully usable.
   Do not fake your way past it — that's no longer a real-stack test.

5. **Backend readiness ≠ frontend readiness.** The frontend may bind its port
   before the backend has finished a slow startup (migrations, a remote content
   sync). With the proxy on, the app's first calls hit a not-ready backend. Give
   the boot real headroom and confirm an authed API call returns `200` before
   exploring.

Record the working facts as a discovery task: boot command, frontend port, the
**usable** user credentials (and which gate they clear), and any flag you had to
*avoid*. You will reference these throughout.

> You generally do **not** boot the user's stack for them — it's their
> environment. But you must *verify* the chain above against the running app
> before exploring, and tell the user precisely which link is broken if one is.

---

## Phase 1 — Explore (one primary action per surface)

Confirm the app is up (`list_pages`; navigate to the consumer URL if needed).
Then walk it like a graph.

### 1a. Unauthenticated landing
Clear storage + cookies for the origin, navigate to `/`, `take_snapshot`.
Capture the form field selectors and a **unique-on-page** heading string
(avoid "Sign in" if it appears as both an `<h1>` and a button). → one
`unauthenticated-landing` scenario asserting the form is present.

### 1b. Login per role, map the landing
For each role the seeder creates (admin, regular/demo user): fill credentials,
submit, wait for an authenticated signal, capture `location` and one sidebar
item **unique to that role** (e.g. an admin-only nav button). → one login
scenario per role asserting a real post-login element (not just "logged in").

### 1c. Per-surface deep walk — THE anti-shallow rule
For **every** top-level nav surface, find and **execute its primary action** —
the thing a user comes to that surface to *do*, not the fact that it rendered:

| Surface kind | Primary action (examples) |
|---|---|
| Chat / assistant | type a message → send → wait for the real reply |
| List/store of items | open an item → assert its detail view |
| Empty-state collection | click "Create …" → assert the create modal/form |
| Feed | trigger the share/react/adapt action → assert the result |
| Admin table | Approve/Suspend/Delete a row → assert the count/row change |

A read-only surface with no action is **not** a deep flow — don't manufacture a
shallow scenario for it (that's the anti-pattern); either find its real action
or leave it to the mocked suite. One scenario per (surface × primary action);
never collapse two distinct actions into one.

---

## Phase 2 — Derive selectors from the accessibility tree

mirroir compiles `tap:`/`wait_for:`/`assert_visible:` labels to Playwright via a
helper that resolves a label as follows:

- starts with `[ # . : > *` → raw CSS / locator passthrough (`page.locator`)
- starts with `role= text= xpath= css= id= data-testid=` → Playwright
  locator-engine passthrough (`page.locator('role=button[name="X"]')`, etc.)
- otherwise → `[data-test="<label>"]` **OR** `getByText("<label>", {exact:true})`

Pick the label form from what the **a11y snapshot** shows, in this priority:

1. **Form inputs / unique-attribute elements** → raw CSS: `[name="email"]`,
   `[name="password"]`, `[placeholder="…"]`. (Password inputs are **not**
   `role=textbox`; target them by `[name=...]`/`[type="password"]`.)
2. **Buttons / headings with a clean accessible name** → `role=`:
   `role=button[name="Create Group"]`, `role=heading[name="Create Coaching Group"]`.
   This is the workhorse for real apps — most use ARIA roles + accessible
   names, not `data-test`. **The role engine matches `name` EXACTLY** (trimmed,
   case-insensitive) — it is *not* substring. So this only works when the
   accessible name equals your string.
3. **Elements whose accessible name is a long concatenation** (e.g. a card
   `<button>` whose name is category+count+title+description) → `role=` will
   **not** match a fragment. Instead target the unique inner text node with the
   bare-text form (`Taper Builder`) — the click bubbles to the card — or use
   `text=` for a substring match.
4. **Substring / partial text** → `text=Pending Users` (matches
   "Pending Users (3)"); plain bare text is **exact** via `getByText`, so a
   label with a trailing count/badge needs `text=`.
5. **Duplicate matches** (label resolves to >1 element → Playwright strict-mode
   failure) → append `>> nth=0` (`role=button[name="Create Group"] >> nth=0`) or
   scope to a parent.

Accessible name truth source: the **chrome-devtools `take_snapshot` tree** shows
the same accessible name Playwright's role engine uses (e.g. it renders
`button "Pending 3"` *with* the space even when `textContent` is `"Pending3"`).
Trust the snapshot's name string, not `el.textContent`.

For each label you choose, **confirm it resolves to exactly one element** on the
live page before writing it (a quick `take_snapshot` check, or count via
`evaluate_script`). One label → one element at that step's moment.

---

## Phase 3 — Capture a state-CHANGE assertion, not presence

The final `assert_visible` / `wait_for` of a deep flow must prove the action
*happened*, not that a button exists:

- modal opened → assert a heading/control that exists **only** in the modal
  (`role=button[name="Close modal"]`, the modal title).
- detail opened → assert a section that exists only in detail (e.g. a
  "System Prompt" heading absent from the list view).
- mutation → assert the **delta**: a count that changed (`role=button[name="Pending 2"]`
  after approving one of three), a new row, a success toast.
- async reply (LLM, network) → wait for a robust, version-agnostic signal via
  `text=` substring (e.g. `text=claude-opus` survives a model bump from 4.7→4.8;
  asserting the exact model string is brittle). Give it a real timeout.

Multi-step confirmations are real flow: if "Approve" opens an inline "Approve
User" confirm, both clicks belong in the scenario.

---

## Phase 4 — Audit anti-patterns BEFORE you emit

Run this audit on your drafted scenarios **before** writing the tree (not after).
Any hit → fix that scenario now:

- Ends with `wait_for: <heading>` and has no `tap:`/`type:` after login → shallow
  "page renders". Add the primary action or drop it.
- Asserts something you never saw in a `take_snapshot` → cold-authored. Re-walk
  that surface.
- Reuses the login submit selector where multiple submit buttons now exist →
  strict-mode. Disambiguate.
- `assert_visible` on text that repeats per-card/per-row → strict-mode. Use a
  unique-on-page string or `>> nth=0`.
- A flow that already has a `baselines/<flow>.ios.txt` and whose scenario has no
  `cross_surface:` step → the parity gate has no web half. Add it (Phase 5).
- `mirroir.yaml` omits "complementary" + the existing spec count → fix.
- Any scenario name is a project concept leaking nowhere it shouldn't — fine
  *inside* the consumer's `.mirroir/` (the consumer describing itself), but
  never let consumer concepts leak into mirroir-mcp's own code/tests.

---

## Phase 5 — Emit the `.mirroir/` tree

```
<consumer-root>/.mirroir/
├── mirroir.yaml          # plan; description says COMPLEMENTARY + spec count
└── apps/<sample>/
    ├── SAMPLE.md         # session.boot (command, cwd, ports, timeout), scenarios list
    ├── APP.md            # routes, selector style, usable test users + gate notes
    ├── SKILL.md          # the canonical flows + why each was chosen
    ├── baselines/        # cross-surface oracles, shared with the iOS leg:
    │                     #   <flow>.ios.txt (device capture, committed)
    │                     #   <flow>.web.txt (scraped by the run, gitignored)
    └── scenarios/<flow>.yaml × N
```

SAMPLE.md `boot`:
- `cwd` is resolved **relative to the SAMPLE.md directory** — for a sample at
  `.mirroir/apps/<x>/`, the repo root is `../../..`.
- `boot_ready_port` = the frontend port; `boot_ready_timeout_s` generous enough
  for a **cold checkout** (full rebuild) — minutes, not seconds.
- **No** test-mode env flag that disables the backend proxy (see Phase 0.2).

Scenario URLs use `http://localhost:PORT/` (Phase 0.3). Add to consumer
`.gitignore`: `.mirroir/.build/`, `.mirroir/mirroir.local.yaml`,
`mirroir-run-report.json`, `.mirroir/apps/*/baselines/*.web.txt`.

### 5a. Pairing a flow with an iOS capture

`baselines/` is the one directory the web leg shares with the iOS leg.
`generate_skill … emit=true` writes `baselines/<flow>.ios.txt` there:
whitespace-joined OCR text of the iPhone screen at the flow's equivalence point.
When a flow you authored has one, your scenario owes the other half — and it
produces that half itself. End the flow's **own** web block with a
`cross_surface:` step whose `capture:` scrapes the same screen:

```yaml
  # …the primary action and its state-change assertion (Phase 3)…
  - cross_surface:
      capture:
        # Resolved by the same helper as Phase 2's labels: raw CSS, role=,
        # text=, or a bare label.
        selector: "[data-test=order-summary]"
        to: "${MIRROIR_SAMPLE_DIR}/baselines/<flow>.web.txt"
      response_files:
        - "${MIRROIR_SAMPLE_DIR}/baselines/<flow>.web.txt"
        - "${MIRROIR_SAMPLE_DIR}/baselines/<flow>.ios.txt"
      min_similarity: 0.5
```

Rules that bite:

- The step belongs **inside the flow's own scenario, after its web block**. A
  `cross_surface:` alone in a file of its own has no page to scrape, so the
  `.web.txt` is never written and that gate can only ever fail.
- `capture.to` must be one of `response_files` — the runner refuses the step
  otherwise, because the scrape would go unread and a stale file compared instead.
- `min_similarity` is required; there is no default. `0.5` suits iOS↔web phrasing
  divergence — the iOS side carries chrome (back chevron, nav title) the web page
  has no equivalent of. Raise it for high-entropy screens; be careful on
  low-vocabulary ones, where a generic token set clears a low bar by coincidence.
- Scrape the **equivalence point**, not `body`. Whole-page text drags in nav and
  footers with no iOS counterpart and drops the score for no reason.
- A pair below threshold is a **failure** (exit 1), not drift, and files no
  drift-log row. `mirroir-run accept` re-records the `.web.txt` only; the
  `.ios.txt` closes on a device re-capture, which is the point of the gate.

No `.ios.txt` for a flow → no `cross_surface:` step for it. Never hand-write one:
a baseline you typed is not a device observation, and the gate it feeds proves
nothing.

---

## Phase 6 — Validate by LIVE REPLAY, then self-heal

Compile-check first (fast sanity): for each scenario,
`mirroir-run --emit playwright <abs-path>` must write a `.spec.ts` carrying a
`test(...)` block under `target/playwright/`.
**But compile-clean is not done** — the 2 most common real failures
(role-name-not-exact, strict-mode duplicates) pass compile and only surface at
replay.

Then run the real thing from the consumer root:
```bash
# kill any stale stack first (Phase 0.1), then:
MIRROIR_PLAYWRIGHT_HOME=<dir containing node_modules/@playwright/test> mirroir-run --scenarios all
```
(`MIRROIR_PLAYWRIGHT_HOME` points at where the consumer's `@playwright/test`
is installed — often the repo root or the frontend workspace root — so the
emitted Playwright config can resolve it.)

**Self-heal loop** — this is the differentiator over a static suite. For each
failing scenario, read the failure:
- `strict mode violation: resolved to N elements` → the label is ambiguous;
  go back to the live DOM, pick a unique label or add `>> nth=0`.
- `locator.click: Timeout … exceeded` waiting on a `role=button[name="X"]` →
  the accessible name isn't exactly `X` (concatenated card, or extra
  badge text); re-snapshot, switch to the inner text node or `text=`.
- `wait_for`/`assert` timeout → the post-action signal was wrong; re-execute
  the action live, observe what *actually* changes, fix the assertion.

Re-drive the live app, re-derive, re-run. Repeat until the sample is green
(`MIRROIR_EXIT=0`, sample verdict `pass`). A red replay is not done.

---

## Phase 7 — Stop. Do not commit.

Summarize: scenarios authored grouped by surface; the primary action each
exercises; any selector fallbacks and why; and the green replay verdict. Wait
for the user to inspect and authorize the commit. Never `git add`/`git commit`
unprompted.

---

## Scope limits

- **Web only.** iOS surface generation is the separate
  `mcp__mirroir__generate_skill` MCP tool (CGEvent + OCR on a real iPhone). You
  *consume* the `baselines/<flow>.ios.txt` it writes (Phase 5a); you never
  author one.
- **`local:` samples only.** Promoting a flow to a shared **archetype** (so the
  next app of the same shape — auth + sidebar + chat-console, etc. — inherits
  coverage by declaring the archetype + a few selectors) is the cross-app
  multiplier, but it's a separate task: `runner/docs/archetype-authoring.md`.
- **Requires a runner with `role=` engine passthrough and dual-stack
  (`127.0.0.1` + `[::1]`) port readiness.** Older runners lack these and will
  fail real-app exploration. Verify the runner is current.

## Reference
- Runner CLI: `runner/docs/mirroir-dotfile.md`
- Pack authoring: `runner/docs/archetype-authoring.md`
- Canonical architecture: https://gist.github.com/jfarcand/a0ef5d91043851e70ceeb728553514c4
