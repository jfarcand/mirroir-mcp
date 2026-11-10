# Patterns & Skills

mirroir uses a layered system of **patterns** (declarative — what things look like) and **skills** (imperative — what to do). Patterns teach the explorer to recognize UI structure; skills tell it how to execute flows.

| Scale | What it describes | Location |
|-------|------------------|----------|
| **Element patterns** | Row-level UI components (table rows, tab bars, buttons) | `patterns/elements/` |
| **Screen patterns** | Screen archetypes from element composition (dashboard, feed) | `patterns/screens/` |
| **App patterns** | App-level structure, obstacles, skip lists (APP.md) | `patterns/apps/` |
| **Skills** | Step-by-step flows the AI executes | `skills/apps/`, `skills/workflows/` |

Patterns are the atoms (elements), molecules (screens), and organisms (apps) of iOS UI understanding.

## Element Patterns

Element pattern definitions teach the explorer what UI elements look like and how to interact with them. Instead of guessing from raw OCR text, the explorer matches screen regions against pattern definitions — a `.md` file per UI pattern — to decide what to tap, what to skip, and when to backtrack.

### Why Patterns?

Raw OCR returns a flat list of text elements with no structure. A Settings row like `General  >` is two separate elements ("General" and ">") that mean "tappable row that navigates." Without pattern definitions, the explorer must infer this from heuristics that break across apps.

Pattern definitions make this explicit: a `table-row-disclosure` definition says "a row with 1-4 text elements, a chevron, in the content zone — tap the first navigation element, expect navigation, go back after."

## Definition Format

Each component is a `.md` file with YAML front matter and markdown sections:

```markdown
---
version: 1
name: table-row-disclosure
platform: ios
---

# Table Row with Disclosure Indicator

## Description
A standard iOS table row with a right chevron indicating drill-down navigation.

## Visual Pattern
- One or two text labels aligned left
- Optional detail text or value aligned right
- Chevron character (>, ›) at the far right edge

## Match Rules
- row_has_chevron: true
- min_elements: 1
- max_elements: 4
- max_row_height_pt: 90
- zone: content
- min_confidence: nil
- exclude_numeric_only: nil

## Interaction
- clickable: true
- click_target: first_navigation_element
- click_result: pushes_screen
- back_after_click: true
- label_rule: first_text

## Exploration
- explorable: true
- role: depth_navigation
- priority: normal

## Grouping
- absorbs_same_row: true
- absorbs_below_within_pt: 0
- absorb_condition: any
- split_mode: none
```

### Match Rules

Match rules determine whether a row of OCR elements belongs to this component. Hard constraints fail immediately; soft signals accumulate a specificity score. The highest-scoring definition that passes all hard constraints wins.

| Rule | Type | Description |
|------|------|-------------|
| `zone` | hard | Screen region: `nav_bar` (top 12%), `content` (middle 76%), `tab_bar` (bottom 12%) |
| `min_elements` / `max_elements` | hard | OCR element count range for the row |
| `max_row_height_pt` | hard | Maximum vertical span in points |
| `row_has_chevron` | hard+soft | Legacy chevron constraint. Require or forbid chevron characters (>, ›, ❯). `true` = +3.0 score, `false` = +1.0. Prefer `chevron_mode` for new definitions |
| `chevron_mode` | hard+soft | Chevron constraint mode, takes precedence over `row_has_chevron`. `required` (hard, +3.0), `forbidden` (hard, +1.0), or `preferred` (soft — chevron present = +3.0, absent = no penalty) |
| `has_numeric_value` | hard+soft | Require or forbid numeric values |
| `has_long_text` | hard+soft | Require or forbid long text (>50 characters) |
| `has_dismiss_button` | hard+soft | Require or forbid dismiss-style close glyphs (`x`, `X`, `✕`, `×`, `✖`, `xmark`) |
| `min_confidence` | hard | Minimum average OCR confidence for the row (0.0-1.0). Rejects ghost text from OCR artifacts |
| `exclude_numeric_only` | modifier | When `true`, bare digit elements (e.g., "23") are excluded from the element count |
| `text_pattern` | hard | Regex that at least one element's text must match |

### Interaction

| Field | Values | Description |
|-------|--------|-------------|
| `clickable` | `true` / `false` | Whether the explorer should tap this component |
| `click_target` | `first_navigation_element`, `first_text`, `first_dismiss_button`, `centered_element`, `none` | Which element in the group to tap |
| `click_result` | `pushes_screen`, `switches_context`, `opens_modal`, `mutates_in_place`, `dismisses`, `none` | What happens after tapping. `pushes_screen`/`opens_modal` require a backtrack; `switches_context` (tab/sidebar) does not. Legacy `navigates`/`toggles` are accepted and mapped to `pushes_screen`/`mutates_in_place` |
| `back_after_click` | `true` / `false` | Whether to tap the back button after visiting the new screen |
| `label_rule` | `tap_target`, `first_text`, `longest_text` | How the human-readable step label is derived from the component's elements — prevents OCR artifacts ("icon", ">") leaking into skill steps |

### Exploration

The optional `## Exploration` section controls how the BFS explorer treats a matched component. It is kept separate from `## Interaction` to avoid conflating UI truth ("is this tappable?") with exploration policy ("should the explorer visit it?"). When the section is absent, `explorable` defaults to the interaction's `clickable`, `role` defaults to `depth_navigation`, and `priority` defaults to `normal`.

| Field | Values | Description |
|-------|--------|-------------|
| `explorable` | `true` / `false` | Whether the explorer should visit this component |
| `role` | `breadth_navigation`, `depth_navigation`, `action`, `info` | Frontier ordering: breadth (tabs, sidebar) before depth (rows, cards) before action (search, buttons); `info` is never explored |
| `priority` | `high`, `normal`, `low` | Priority within the role category |

### Grouping (Multi-Row Components)

Some UI elements span multiple OCR rows — a Health app summary card might have a title on row 1, a large number on row 2, and a unit on row 3. Without grouping, the explorer would tap each row separately.

| Field | Description |
|-------|-------------|
| `absorbs_same_row` | Merge all elements in the same Y-band into one component |
| `absorbs_below_within_pt` | Absorb rows within this many points below. Set to 0 for single-row components |
| `absorb_condition` | `any` absorbs all rows; `info_or_decoration_only` only absorbs rows whose elements are all info or decoration role; `no_chevron_rows_only` absorbs only rows without a chevron (keeps adjacent navigable rows separate) |
| `split_mode` | `none` (default) emits one component per matched row; `per_item` emits one component per non-decoration element — used for multi-target containers like tab bars |

### File Locations

Element patterns are loaded from all of these directories in priority order (first match wins by name):

| Priority | Path | Use Case |
|----------|------|----------|
| 1 | `<cwd>/.mirroir-mcp/components/` | Project-local overrides |
| 2 | `~/.mirroir-mcp/components/` | User's global custom patterns |
| 3 | `<cwd>/.mirroir-mcp/skills/patterns/elements/` | Project-local skills repo (new structure) |
| 4 | `~/.mirroir-mcp/skills/patterns/elements/` | User's global skills repo (new structure) |
| 5 | `../mirroir-skills/patterns/elements/` | Sibling skills repo (new) |
| 6 | `<cwd>/.mirroir-mcp/skills/components/ios/` | Project-local skills repo (legacy fallback) |
| 7 | `<cwd>/.mirroir-mcp/skills/components/custom/` | Project-local skills repo (legacy custom) |
| 8 | `../mirroir-skills/components/ios/` | Sibling skills repo (legacy fallback) |
| 9 | `../mirroir-skills/components/custom/` | Sibling skills repo (legacy custom) |

The home directory `~/.mirroir-mcp/` is the Swift MCP's own config home — distinct from `.mirroir/`, the runner's consumer dotfile. Install the community patterns under the global skills home (priority 4 discovers them):

```bash
git clone https://github.com/jfarcand/mirroir-skills ~/.mirroir-mcp/skills
```

## Detection Pipeline

When the explorer captures a screen, the component detection pipeline transforms raw OCR into structured, actionable components:

```
Vision OCR → [TapPoint]
    ↓
ElementClassifier.classify() → [ClassifiedElement] with roles
    ↓
Group elements into rows by Y proximity
    ↓
Per row: compute RowProperties (zone, element count, chevron, confidence, ...)
    ↓
Score each ComponentDefinition against each row
    ↓
Best-scoring definition wins → ScreenComponent
    ↓
Absorption pass: merge multi-row components
    ↓
ScreenPlanner: filter clickable, rank by score → [RankedElement]
    ↓
Explorer taps highest-ranked unvisited element
```

### Element Classification

Before component matching, each OCR element gets a role:

| Role | Examples |
|------|----------|
| `decoration` | Chevrons (>, <), punctuation-only, or very short text |
| `info` | "On"/"Off", numeric values, value/state indicators ("3.2 GB", "Connected") |
| `navigation` | Elements in rows with chevrons, tappable labels |
| `stateChange` | Elements in rows with toggles |
| `destructive` | Elements matching destructive/dangerous skip patterns (delete, sign out) |

### Scoring

Definitions compete for each row. Hard constraints eliminate mismatches; soft signals accumulate specificity:

- Chevron required (`true` / `chevron_mode: required`): +3.0
- Chevron forbidden (`false` / `chevron_mode: forbidden`): +1.0
- Chevron preferred (`chevron_mode: preferred`): +3.0 when present, no penalty when absent
- Numeric/long text/dismiss signals: +2.0 to +3.0 each
- Tight element range (max-min < 3): +1.0
- NavBar or TabBar zone: +2.0

The highest score wins. Unmatched rows become individual "unclassified" components.

## Calibration

During BFS exploration, the calibration phase runs component detection on each new screen to build an exploration plan. When using AI vision mode (`screenDescriberMode: "vision"`), the vision model produces clean semantic elements that may not need component-based classification. Pass `skip_calibration: true` on `generate_skill(action: "explore")` to bypass component detection and validation — full-page scrolling still runs to discover below-fold elements, and elements are classified directly into an exploration plan without component matching.

The `calibrate_component` tool tests a definition against the current live screen without running a full exploration. Point it at a `.md` file and it reports what matched, what didn't, and why.

### Workflow

1. Write a `.md` definition with your best guess at match rules
2. Navigate the iPhone to a screen that contains the target UI pattern
3. Run calibration:

```
Use calibrate_component with component_path pointing to my table-row-disclosure.md
```

4. Read the diagnostic report:

```
=== Component Definition ===
name: table-row-disclosure
zone: content, elements: 1-4, chevron: required

=== Screen Analysis (12 OCR elements → 4 rows) ===

Row 0 | zone=content | elements=2 | chevron=true | height=44pt | avg_conf=0.95
  "General" (navigation, 0.98), ">" (decoration, 0.92)
  ✅ Matched: table-row-disclosure  ← YOUR COMPONENT

Row 1 | zone=content | elements=1 | chevron=false | height=20pt | avg_conf=0.31
  "23" (decoration, 0.31)
  ❌ No match (chevron required, confidence below threshold)
```

5. Adjust match rules based on the report — the tool suggests precision values like `min_confidence` and `exclude_numeric_only` based on what it observed

### Precision Tuning

Two match rules are typically set through calibration rather than written by hand:

- **`min_confidence`** — Average OCR confidence threshold. Rejects ghost text (OCR artifacts from icons or gradients). Calibration reports confidence per row and recommends a threshold.
- **`exclude_numeric_only`** — When `true`, bare digit elements ("23", "5") don't count toward `min_elements`/`max_elements`. Useful for tab bars where badge counts shouldn't inflate the element count.

### Built-in Element Patterns

The [mirroir-skills](https://github.com/jfarcand/mirroir-skills) repo includes 33 iOS element patterns in `patterns/elements/`, covering Apple's Human Interface Guidelines (the `patterns/elements/` directory also holds two non-pattern data files, `text-cleanup.md` and `vision-indicators.md`, which the loader skips):

**Navigation & Structure**

| Component | Pattern | Explorable |
|-----------|---------|:---:|
| `table-row-disclosure` | Settings-style row with chevron (>) — drill-down navigation | yes |
| `table-row-detail` | Row with detail text but no chevron — info only | no |
| `table-row-subtitle` | Two-line row (title + subtitle) — Mail, Contacts, notifications | yes |
| `table-row-value` | Key-value row with chevron — Settings ("Language → English") | yes |
| `tab-bar-item` | Bottom tab bar items (split per item) | yes |
| `navigation-bar` | Top navigation bar with title and back button | no |
| `segmented-control` | Segmented picker control (split per item) | no |
| `bottom-navigation-bar` | Bottom navigation bar grouping | no |

**Cards & Content**

| Component | Pattern | Explorable |
|-----------|---------|:---:|
| `summary-card` | Multi-row metric cards (Health, Fitness dashboards) | yes |
| `metric-display` | Large numeric value with unit (72 bpm, 23°, 8,432 steps) | no |
| `collection-cell` | Grid item in collection view (Photos, App Store) | yes |
| `feed-post` | Social feed item (TikTok, Instagram, Reddit) | no |
| `profile-header` | User card with name and avatar | no |

**Interactive Controls**

| Component | Pattern | Explorable |
|-----------|---------|:---:|
| `toggle-row` | Row with On/Off toggle switch | no |
| `search-bar` | Search input field | no |
| `action-button` | Prominent action buttons | yes |
| `destructive-button` | Red delete/sign-out button — never tapped | no |
| `compose-bar` | Bottom text input with send button (Messages, Slack) | no |
| `inline-picker` | Date/time scroll wheel picker | no |

**Dialogs & Overlays**

| Component | Pattern | Explorable |
|-----------|---------|:---:|
| `modal-sheet` | Modal dialogs with dismiss buttons | no |
| `alert-dialog` | System alert modals with dismiss/confirm buttons | no |
| `action-sheet` | Bottom pop-up with stacked action choices | no |
| `article-modal` | Article-style modal content | no |
| `banner-notification` | Transient top notification banner — ignored | no |

**Informational**

| Component | Pattern | Explorable |
|-----------|---------|:---:|
| `page-title` | Large page title text | no |
| `section-header` | Non-interactive section titles | no |
| `section-footer` | Non-interactive section footers | no |
| `explanation-text` | Descriptive text blocks | no |
| `chart-axis-label` | Chart axis labels (Health/Fitness charts) | no |
| `empty-state` | Empty state placeholder views | no |
| `list-item` | Generic list row (fallback) | yes |

**Actions & Toolbars**

| Component | Pattern | Explorable |
|-----------|---------|:---:|
| `action-bar` | Horizontal icon row (Like, Share, Comment) | no |
| `toolbar` | Bottom action icons (Mail compose, Safari share) | no |

## Screen Patterns (Recipes)

Screen patterns identify **app archetypes** from element composition. Instead of checking app names, the system matches the set of detected elements against known recipes to understand the navigation model.

### How Screen Patterns Work

Screen patterns are matched in two ways:

1. **APP.md archetype** (highest priority) — the developer declares the archetype in their APP.md front matter: `archetype: dashboard`. This bypasses auto-detection entirely. The developer knows their app best.

2. **Auto-detection** (fallback) — after the first screen's elements are detected during BFS calibration, the recipe matcher scores the element set against all loaded screen patterns. The best match above threshold becomes the screen's archetype.

The matched archetype informs:

- **Strategy refinement** — a `social-feed` recipe switches from `mobile` to `social` strategy automatically
- **Navigation model** — drill-down, infinite-scroll, grid-browse, etc.
- **Exploration hints** — embedded in generated SKILL.md files as `## Navigation Notes`

### Recipe Format

Recipes are `.recipe.md` files with YAML front matter:

```markdown
---
version: 1
name: dashboard
platform: ios
---

# Dashboard

## Description
Card-based overview showing summary metrics that drill down to detail views.

## Required Components
- summary-card

## Supporting Components
- metric-display
- tab-bar-item
- chart-axis-label

## Forbidden Components
- feed-post
- compose-bar

## Navigation Model
- type: card-drill-down
- backtrack: tap-back-chevron
- scroll_behavior: finite
- depth_pattern: card-to-detail

## Exploration Hints
- Summary cards are the primary drill-down targets
- Metric displays are informational, not tappable
- Tab bar switches between metric categories
```

### Built-in Recipes

| Recipe | Required Components | Navigation Model |
|--------|-------------------|-----------------|
| `settings-list` | `table-row-disclosure` | drill-down |
| `dashboard` | `summary-card` | card-drill-down |
| `social-feed` | `feed-post` | infinite-scroll |
| `content-grid` | `collection-cell` | grid-browse |
| `conversation-list` | `table-row-subtitle` | list-to-thread |
| `utility-display` | `metric-display` | minimal |
| `detail-form` | `table-row-value` | form |

### Screen Pattern File Locations

Recipes honor both the project-local and the global skills directory (`patterns/screens/` and the legacy `recipes/ios/`):

| Priority | Path |
|----------|------|
| 1 | `<cwd>/.mirroir-mcp/recipes/` |
| 2 | `~/.mirroir-mcp/recipes/` |
| 3 | `<cwd>/.mirroir-mcp/skills/patterns/screens/` |
| 4 | `~/.mirroir-mcp/skills/patterns/screens/` |
| 5 | `../mirroir-skills/patterns/screens/` |
| 6 | `<cwd>/.mirroir-mcp/skills/recipes/ios/` (legacy fallback) |
| 7 | `~/.mirroir-mcp/skills/recipes/ios/` (legacy fallback) |
| 8 | `../mirroir-skills/recipes/ios/` (legacy fallback) |

## App Patterns (APP.md)

APP.md files let developers describe their app's structure, obstacles, and danger zones in plain language. This is the human-in-the-loop — the developer gives mirroir a map before it starts exploring. Skip lists prevent destructive taps, obstacles are auto-dismissed, the archetype declares the navigation model, and free-form context helps the AI navigate efficiently.

### Format

```markdown
---
version: 1
app: Santé
locale: fr_CA
archetype: dashboard
obstacle_mode: auto
---

# Santé (Health)

## Structure
Dashboard app with 4 tabs: Résumé, Partage, Parcourir, Profil.

## Résumé Tab
- Summary cards showing health metrics (Activité, Cœur, Sommeil)
- Each card drills down to a detail screen with charts

## Obstacles
- Health Access permission dialog → tap "Autoriser"
- Notification permission → tap "Ne pas autoriser"

## Skip
- Supprimer les données de Santé
- Réinitialiser

## Credentials
- email: ${TEST_EMAIL:-test@example.com}

## Tips
- The Partage tab requires a second user — skip it
- Chart screens have minimal tappable elements — backtrack quickly
```

### Sections

| Section | Parsed | Purpose |
|---------|:------:|---------|
| `## Structure` | AI reads | High-level app overview |
| `## [Name] Tab` | AI reads | Per-tab descriptions |
| `## Obstacles` | machine | Auto-dismiss rules: `trigger → action` |
| `## Skip` | machine | Elements the explorer must never tap, and no generated wait names |
| `## Landmarks` | machine | Stable texts a generated wait takes before any other |
| `## Credentials` | machine | Login data with `${VAR}` substitution |
| `## Tips` | AI reads | Free-form exploration advice |

### Front Matter Fields

| Field | Required | Description |
|-------|:--------:|-------------|
| `app` | yes | App name for matching (case-insensitive, diacritics-insensitive: "Sante" matches "Santé") |
| `locale` | no | BCP-47 locale (e.g. `fr_CA`). Locale-specific files take priority. |
| `archetype` | no | Screen pattern name (e.g. `dashboard`, `social-feed`). Bypasses auto-detection — the developer's declaration wins. |
| `obstacle_mode` | no | `auto` (default), `hint`, or `off` |

### Integration

- **Skip elements** merge into the exploration budget's skip patterns alongside built-in safety patterns and `permissions.json` entries
- **Obstacles** extend the alert detection pipeline — checked after system alerts on every screen during BFS exploration
- **Context** (Structure, tab descriptions, Tips) is injected into generated SKILL.md files as `## App Context`
- **Credentials** support `${VAR}` and `${VAR:-default}` substitution from environment variables

### File Locations

| Priority | Path |
|----------|------|
| 1 | `<cwd>/.mirroir-mcp/skills/` (recursive) |
| 2 | `~/.mirroir-mcp/skills/` (recursive) |
| 3 | `../mirroir-skills/patterns/apps/` (recursive) |
| 4 | `../mirroir-skills/apps/` (recursive, legacy fallback) |

## Text Cleanup

A `text-cleanup.md` file in the element patterns directory defines OCR noise to strip from generated skills:

- **`## Strip Prefixes`** — characters removed from the beginning of labels (bullets `•`, `·`, `○`, etc.)
- **`## Exclude Labels`** — exact text values excluded from landmarks and step labels (`icon`, etc.)

This is data-driven — add entries to the file rather than hardcoding in Swift.

## System Phrases

The explorer has to notice when the phone leaves the app it is driving for a system screen. The words of those screens come from two places, one per side of the glass:

- **Text iOS draws on the phone** (the lock screen and passcode prompt, Spotlight's top-hit heading and its Open word, the Home Screen search pill, system-alert titles and buttons) is in the iPhone's language, which the Mac cannot know. It lives in [`Sources/mirroir-mcp/Resources/system-phrases.md`](../Sources/mirroir-mcp/Resources/system-phrases.md), compiled into the binary so every install has it, as a union across languages: one section per `##` heading, one phrase per bullet, as it reads on a phone. Add your language's wording by adding bullets; a fragment is enough as long as no ordinary app screen would contain it, unless the section asks for the whole label. The order of `## Alert Dismiss` is the order the buttons are tried, most conservative first.
- **Text iPhone Mirroring draws on the Mac** (`iPhone in Use`, and the `Resume`, `Try Again`, `Connect` and `OK` buttons that free a paused session) is read from Apple's own strings inside the installed iPhone Mirroring app, in the Mac's language. Nothing to configure.

## Vision Indicators

When `screenDescriberMode: "vision"` is active, the vision model describes icons in words ("Entraînements chevron") instead of emitting glyphs. A `vision-indicators.md` file in the element patterns directory maps those indicator suffixes back to OCR-compatible characters so the same component detection pipeline works on vision output:

- **`## Indicators`** — `suffix: character` lines. When a vision element's text ends with a known suffix, the suffix is stripped and a separate element with the mapped character is appended (e.g. `Entraînements chevron` → `Entraînements` + `>`).

Default mappings cover `chevron`/`disclosure`/`arrow_right` → `>`, `dismiss`/`close_button`/`xmark` → `×`, and `back` → `<`. Like text cleanup, this is data-driven — the loader skips this file when matching components and only reads its `## Indicators` table.

## Writing Custom Patterns

1. Identify the UI pattern you want to teach the explorer
2. Note the visual characteristics: how many text elements, chevrons, screen zone, typical confidence
3. Create a `.md` file following the element pattern format above
4. Use `calibrate_component` against a real screen to validate and tune
5. Place the file in `~/.mirroir-mcp/components/` or your project's `.mirroir-mcp/components/`

1. Identify the UI pattern you want to teach the explorer
2. Note the visual characteristics: how many text elements, chevrons, screen zone, typical confidence
3. Create a `.md` file following the format above
4. Use `calibrate_component` against a real screen to validate and tune
5. Place the file in `~/.mirroir-mcp/components/` or your project's `.mirroir-mcp/components/`

Custom definitions take priority over community ones with the same name.
