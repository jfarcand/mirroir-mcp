# Authoring Archetype Packs

> See the [`.mirroir/` user reference](./mirroir-dotfile.md) for the consumer side.

This page is the reference for **pack authors** — folks publishing
archetypes for use across multiple consumer repos.

## What is an archetype?

An archetype is a parameterized test specification for a *category* of
applications. Where a single consumer might have 21 samples that all use
the same Vue console, the archetype captures the shared structure once:

- Stable selectors (`[data-testid=…]`)
- Canonical flows (chat-stream, chat-broadcast, …)
- Required inputs (`PORT`, `MESSAGE`, …)
- Behavioral invariants

Consumer repos reference the archetype + supply the per-instance config
(boot command, port, env). Compose produces a ready-to-replay sample
tree for each consumer instance.

## Pack repo layout

A pack repo carries **one archetype tree per commit**:

```
<pack-repo>/
├── INDEX.md
└── archetypes/
    └── <archetype-name>/
        ├── archetype.md
        ├── APP.md
        ├── SKILL.md
        └── scenarios/<flow>.yaml
```

There are **no in-tree version directories**. `INDEX.md`'s `pack_version`
names the version: `mirroir-run pack install <repo> [--ref <branch-or-tag>]`
installs the fetched commit at `~/.mirroir/skills/<pack>/<pack_version>/`,
one directory per installed version. A git tag is optional provenance (the
lockfile records it when `HEAD` sits on one); it does not pick the version.

An installed version is immutable — lockfiles pin its checksum — so
`pack install` refuses a different commit under a `pack_version` that is
already installed. **Bump `pack_version` whenever the archetype tree
changes**, following *Semver discipline* below.

## `INDEX.md` (pack manifest)

````markdown
```yaml
version: 1
name: <pack-name>
pack_version: 1.0.0      # exact MAJOR.MINOR.PATCH; the install directory
description: |
  One-line summary.
repository: https://github.com/...
license: Apache-2.0
archetypes:
  - <archetype-name>
```

# <pack-name>
````

## `archetype.md` (manifest)

````markdown
```yaml
version: 1
name: <pack-or-archetype-namespace>/<archetype-name>
archetype_version: 1.0.0
description: |
  What this archetype models.
requires:
  vars:
    - name: PORT
      description: TCP port the app binds to.
      required: true
    - name: MESSAGE
      description: User prompt to send.
      default: "Hello"
  env:
    - name: SOME_ENV
      default: "false"
provides:
  flows:
    - flow-a
    - flow-b
compatible_with:
  some-framework: ">=4.0.0,<5.0.0"
```

# <archetype-name>

Prose describing the archetype.
````

### Fields

- `name` — fully-qualified name. By convention `<namespace>/<archetype>`
  (e.g., `atmosphere/ai-console`).
- `archetype_version` — semver. Bumps follow normal semver rules.
- `requires.vars[]` — declares what inputs an instance must (or may) fill.
  - `required: true` → instance must supply this in `vars:`.
  - `default: "..."` → falls back at compose time when instance omits it.
- `requires.env[]` — environment variables the boot process expects.
  Each `default:` is folded into the instance's `boot.env` for any key the
  plan entry omits, and the synthesized `SAMPLE.md` carries it. An explicit
  `boot.env` value always wins; a declared env var with no `default` is left
  for the boot process to supply.
- `provides.flows[]` — names of flows under `scenarios/`. Each must have
  a matching `scenarios/<name>.yaml`.
- `compatible_with` — informational; not enforced at compose time.

## `APP.md` + `SKILL.md`

Author these as parameterized markdown with a fenced yaml frontmatter
block. Use `${VAR}` for placeholders — they're substituted at compose
time. Use `${VAR:-default}` for inline fallbacks.

```markdown
```yaml
version: 1
app: <archetype-name>
surface: web
url_root: http://127.0.0.1:${PORT}/path/
```

# App structure
…
```

Compose substitutes the yaml block on every consumer's `.build/` output.

## Scenarios

One yaml file per flow under `scenarios/`. Standard mirroir-run scenario
format. Use `${VAR}` for instance-supplied values.

```yaml
version: 1
name: <flow-name>
tags: [<archetype>, must-pass]
steps:
  - target:
      kind: web
      browsers: [chromium]
      url: "http://127.0.0.1:${PORT}/console/"
  - wait_for: "[data-testid=status-label]:has-text('Connected')"
  - tap: "[data-testid=input]"
  - type: "${MESSAGE:-Hello}"
  - tap: "[data-testid=send]"
  - wait_for: "[data-testid=message-bubble]"
```

## Releasing a version

```bash
# Change the archetype tree, bump `pack_version` in INDEX.md, merge to main.
# Optionally tag the commit — the lockfile records the tag as provenance:
git tag -a v1.0.1 -m "atmosphere/ai-console v1.0.1"
git push origin v1.0.1
```

Consumers update by installing the new version beside the old one and
re-locking:

```bash
mirroir-run pack install https://github.com/<owner>/<pack-repo>
mirroir-run            # default mode regenerates mirroir.lock
```

A floating ref (`@v1`) resolves to the highest installed `1.x.x`, so the
plan picks the new version up without editing `mirroir.yaml`; an exact pin
(`@1.0.0`) is bumped in `mirroir.yaml`.

## Semver discipline

- **Major bump** (`v1.x.x` → `v2.0.0`): breaking change. Selectors
  removed, flows removed, required vars added.
- **Minor bump** (`v1.0.x` → `v1.1.0`): additive. New flows, new
  optional vars, new selectors. Backwards-compatible.
- **Patch bump** (`v1.0.0` → `v1.0.1`): no behavioral change. Prose
  edits, docs, internal refactors.

## Testing an archetype

Two paths:

1. **Smoke against a known instance.** Maintain a sample consumer config
   in the pack repo's `tests/` and run it against a representative
   target.
2. **Compose-only against a fixture.** Build a minimal `.mirroir/`
   tree in a tempdir, point at the pack, run `mirroir-run --compose-only`.
   Assert the composed output looks right.

Pack-side automated testing convention is **TBD** — track the
architecture spec's "Archetype testing" open question for the canonical
approach when it lands.
