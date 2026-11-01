# Exploring a New App

A step-by-step checklist for onboarding a new iOS app to mirroir-mcp so the explorer can produce useful skills on the first run instead of wandering.

This page is a **playbook**. The deep references it points at:

- [`docs/APP.md.spec.md`](APP.md.spec.md) — every APP.md field and what reads it
- [`docs/permissions.md`](permissions.md) — `permissions.json` (global + per-app)
- [`docs/components.md`](components.md) — component pattern format
- [`docs/tools.md`](tools.md) — `launch_app`, `generate_skill`, `record_step`
- `mirroir-skills/patterns/apps/` — live APP.md examples

## 1. Pre-flight

```bash
# iPhone Mirroring connected?
mcp__mirroir__status

# App launches via Spotlight under the name you'll use? Localized matters —
# "Settings" finds "Réglages" on a French iPhone, "Helix" might map to
# "Helix Vidéotron" or "Helix Tv".
mcp__mirroir__launch_app(name: "<TheName>")
mcp__mirroir__describe_screen   # confirm we landed in the app, not stuck on Spotlight
```

If launch_app fails or lands on Spotlight, fix that first — explore depends on a clean cold launch. The localized name you discover here is the value to use everywhere downstream (`app:` in APP.md, `name:` in `reset_app`, etc.).

## 2. Write APP.md

Location options (loader walks all three):

- `<cwd>/.mirroir-mcp/skills/patterns/apps/<AppName>/APP.md`
- `~/.mirroir-mcp/skills/patterns/apps/<AppName>/APP.md`
- `<cwd>/../mirroir-skills/patterns/apps/<AppName>/APP.md`  *(canonical for shared patterns)*

Minimal viable APP.md:

```markdown
---
app: HelixVideotron       # must match what launch_app finds (see step 1)
archetype: media          # see APP.md.spec for the list
reset_before_explore: true   # set true if app retains overlays / login state on relaunch
---

## Structure

Short prose — what region the user sees first, what an edge-control cluster looks like, what's content vs chrome. The explorer reads this verbatim into the generated skill's "App Context" section.

## Tabs

- Live TV
- On Demand
- Recordings
- Search

## Tab Layout

- orientation: horizontal       # or vertical (Tapo-style edge rail)
- edge: bottom                  # bottom | top | left | right

## Obstacles

- Auto-play preview → tap pause
- "Continue watching" prompt → tap "No thanks"

## Skip

- Disconnect / Sign out
- Purchase / Rent
- Delete recording
```

What each field actually does — see [APP.md.spec.md § "Field-by-Field Behavior"](APP.md.spec.md). Both `## Credentials` and `## Tips` are consumed: declared credential keys (never values) surface as a "## Required Credentials" section in the generated SKILL.md, and `## Tips` entries surface as a "## Tips" section. Check the spec for which fields are read by the explorer versus only the generator.

Tip: if you're unsure about Tabs, run `describe_screen` on the app's home, write down the bottom-edge labels exactly as OCR returns them, and use those.

## 3. Permissions and per-app rules

Global / blocked apps live in `~/.mirroir-mcp/permissions.json`. Confirm:

```json
{
  "blockedApps": ["Wallet", "Banking"],   // your new app should NOT be here
  "perApp": {
    "HelixVideotron": {
      "deny": ["type_text"]               // block text-typing for apps with PIN/payment fields
    }
  }
}
```

Per-app `deny` is the safest way to protect destructive flows (PPV purchase, account deletion) while still letting the explorer browse. If the explorer needs a tool the per-app rule blocks, `generate_skill` refuses to start with a clear message — see [`permissions.md`](permissions.md).

## 4. Component coverage check

Before exploring, scan `mirroir-skills/patterns/elements/` for patterns that match your app's UI primitives. Common cases:

- **List rows with chevron** → `table-row-disclosure` component (covered)
- **Summary cards** → `summary-card` (covered)
- **Video tiles in horizontal carousels** → may need a new pattern
- **Now-playing bar (persistent footer)** → may need a new pattern

If a UI primitive doesn't match an existing component, write one — format and field reference in [`components.md`](components.md). Without it, the explorer falls back to `unclassified` and only treats the row as explorable when there's a chevron in it (otherwise the explorer would burn taps on CTAs and article fragments). So **new app = new component definitions** if the app has unusual UI.

## 5. Baseline state capture

```bash
mcp__mirroir__press_home
mcp__mirroir__launch_app(name: "<TheName>")
mcp__mirroir__describe_screen   # save this as your "expected home screen"
```

Note element count and the labels you'd expect the explorer to find. After running explore, compare. Discrepancies usually mean APP.md tabs are wrong or a component is missing.

## 6. Define the exploration goal

`generate_skill(action: "explore", ...)` accepts a `goal` string. It guides which screens get prioritized when multiple paths exist. Be specific:

- ❌ `"Test the app"`
- ✅ `"Browse live TV channels and play one"`
- ✅ `"Find a movie in On Demand and start playback"`

```bash
mcp__mirroir__generate_skill(
  action: "explore",
  app_name: "HelixVideotron",
  goal: "Browse live TV channels and play one",
  max_depth: 4,
  max_screens: 30,
  max_time: 300
)
```

## 7. (Optional) compile a skill for fast replay

`record_step` is not an interactive flow recorder (that is `mirroir record`). It is the compilation hook: while an AI agent executes an existing skill step by step, it calls `record_step` after each step with the observed coordinates, timing, and match data, and then `save_compiled` writes a `.compiled.json` next to the source skill. The compiled artifact lets future runs replay deterministically instead of re-driving the AI. `save_compiled` with `emit: true` (and `output_dir`, the consumer repo root) also writes the walk as the iOS leg under `.mirroir/apps/<app>/`, as `generate_skill … emit=true` does; the skill must open with `launch:`. See [compiled-skills.md](compiled-skills.md). (For a raw screen-capture video of a run, use `start_recording` / `stop_recording` instead — those produce a `.mov`, not skill steps.)

## When something goes wrong

- **App launches but explorer reports "Spotlight still visible"** — `launchApp` race; the `searchResultsPopulateUs` setting (env var `MIRROIR_SEARCH_RESULTS_POPULATE_US`) bumps the wait. See [troubleshooting.md](troubleshooting.md).
- **Wrong app dismissed during reset_before_explore** — re-confirm `app:` matches the launch name; `AppSwitcherDismissal` fails closed when OCR can't disambiguate, so you'll get a clear error rather than a silent wrong dismissal.
- **Explorer ignores the tabs you declared** — check OCR output for the tab labels; ordinal fallback only fires when text matching fails. The explorer also restricts edge sampling to the declared `## Tab Layout` band.
- **Taps land above buttons in non-grid toolbars** — `TapPointCalculator`'s icon-row offset was over-eager on horizontal toolbars; the uniform-spacing gate fixes it. If it still happens, capture the OCR row and file an issue with x positions.

## Companion repo

Skill `.md` files and patterns live in [`mirroir-skills`](https://github.com/jfarcand/mirroir-skills). Submit your APP.md / new components there once they work — that's how the marketplace grows.
