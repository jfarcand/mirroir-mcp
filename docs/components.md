# Component Detection

Component definitions teach the explorer what UI elements look like and how to interact with them. Instead of guessing from raw OCR text, the explorer matches screen regions against component definitions — a `.md` file per UI pattern — to decide what to tap, what to skip, and when to backtrack.

## Why Components?

Raw OCR returns a flat list of text elements with no structure. A Settings row like `General  >` is two separate elements ("General" and ">") that mean "tappable row that navigates." Without component definitions, the explorer must infer this from heuristics that break across apps.

Component definitions make this explicit: a `table-row-disclosure` definition says "a row with 1-4 text elements, a chevron, in the content zone — tap the first navigation element, expect navigation, go back after."

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
- click_result: navigates
- back_after_click: true

## Grouping
- absorbs_same_row: true
- absorbs_below_within_pt: 0
- absorb_condition: any
```

### Match Rules

Match rules determine whether a row of OCR elements belongs to this component. Hard constraints fail immediately; soft signals accumulate a specificity score. The highest-scoring definition that passes all hard constraints wins.

| Rule | Type | Description |
|------|------|-------------|
| `zone` | hard | Screen region: `nav_bar` (top 12%), `content` (middle 76%), `tab_bar` (bottom 12%) |
| `min_elements` / `max_elements` | hard | OCR element count range for the row |
| `max_row_height_pt` | hard | Maximum vertical span in points |
| `row_has_chevron` | hard+soft | Require or forbid chevron characters (>, ›, ❯). `true` = +3.0 score, `false` = +1.0 |
| `has_numeric_value` | hard+soft | Require or forbid numeric values |
| `has_long_text` | hard+soft | Require or forbid long text (>40 characters) |
| `has_dismiss_button` | hard+soft | Require or forbid dismiss-style buttons (Done, Cancel, Close) |
| `min_confidence` | hard | Minimum average OCR confidence for the row (0.0-1.0). Rejects ghost text from OCR artifacts |
| `exclude_numeric_only` | modifier | When `true`, bare digit elements (e.g., "23") are excluded from the element count |
| `text_pattern` | hard | Regex that at least one element's text must match |

### Interaction

| Field | Values | Description |
|-------|--------|-------------|
| `clickable` | `true` / `false` | Whether the explorer should tap this component |
| `click_target` | `first_navigation_element`, `first_dismiss_button`, `centered_element`, `none` | Which element in the group to tap |
| `click_result` | `navigates`, `toggles`, `dismisses`, `none` | What happens after tapping |
| `back_after_click` | `true` / `false` | Whether to tap the back button after visiting the new screen |

### Grouping (Multi-Row Components)

Some UI elements span multiple OCR rows — a Health app summary card might have a title on row 1, a large number on row 2, and a unit on row 3. Without grouping, the explorer would tap each row separately.

| Field | Description |
|-------|-------------|
| `absorbs_same_row` | Merge all elements in the same Y-band into one component |
| `absorbs_below_within_pt` | Absorb rows within this many points below. Set to 0 for single-row components |
| `absorb_condition` | `any` absorbs all rows; `info_or_decoration_only` only absorbs rows whose elements are all info or decoration role |

## File Locations

Component definitions are loaded from multiple directories in priority order (first match wins by name):

| Priority | Path | Use Case |
|----------|------|----------|
| 1 | `<cwd>/.mirroir-mcp/components/` | Project-local overrides |
| 2 | `~/.mirroir-mcp/components/` | User's global custom components |
| 3 | `<cwd>/.mirroir-mcp/skills/components/ios/` | Skills repo (iOS) |
| 4 | `<cwd>/.mirroir-mcp/skills/components/custom/` | Skills repo (custom) |
| 5 | `../mirroir-skills/components/ios/` | Sibling skills repo (iOS) |
| 6 | `../mirroir-skills/components/custom/` | Sibling skills repo (custom) |

Install the community components:

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
| `decoration` | Status bar text, chevrons (>), short fragments (<3 chars) |
| `info` | "On"/"Off", numeric values, secondary labels |
| `navigation` | Elements in rows with chevrons, tappable labels |
| `stateChange` | Elements in rows with toggles |

### Scoring

Definitions compete for each row. Hard constraints eliminate mismatches; soft signals accumulate specificity:

- Chevron required (`true`): +3.0
- Chevron forbidden (`false`): +1.0
- Numeric/long text/dismiss signals: +2.0 to +3.0 each
- Tight element range (max-min < 3): +1.0
- NavBar or TabBar zone: +2.0

The highest score wins. Unmatched rows become individual "unclassified" components.

## Calibration

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

## Built-in Components

The [mirroir-skills](https://github.com/jfarcand/mirroir-skills) repo includes 20 iOS component definitions:

| Component | Pattern |
|-----------|---------|
| `table-row-disclosure` | Settings-style row with chevron (>) — drill-down navigation |
| `table-row-detail` | Row with detail text but no chevron — info only |
| `toggle-row` | Row with On/Off toggle switch |
| `tab-bar-item` | Bottom tab bar items |
| `navigation-bar` | Top navigation bar with title and back button |
| `summary-card` | Multi-row metric cards (Health app) |
| `modal-sheet` | Modal dialogs with dismiss buttons |
| `alert-dialog` | System alert modals with dismiss/confirm buttons |
| `search-bar` | Search input field |
| `segmented-control` | Segmented picker control |
| `list-item` | Generic list row |
| `action-button` | Prominent action buttons |
| `bottom-navigation-bar` | Bottom navigation bar (alternative to tab bar) |
| `page-title` | Large page title text |
| `section-header` | Non-interactive section titles |
| `section-footer` | Non-interactive section footers |
| `explanation-text` | Descriptive text blocks |
| `chart-axis-label` | Chart axis labels (Health/Fitness charts) |
| `article-modal` | Article-style modal content |
| `empty-state` | Empty state placeholder views |

## Writing Custom Components

1. Identify the UI pattern you want to teach the explorer
2. Note the visual characteristics: how many text elements, chevrons, screen zone, typical confidence
3. Create a `.md` file following the format above
4. Use `calibrate_component` against a real screen to validate and tune
5. Place the file in `~/.mirroir-mcp/components/` or your project's `.mirroir-mcp/components/`

Custom definitions take priority over community ones with the same name.
