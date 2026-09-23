## CRITICAL: Which Keyboard Shortcuts Reach iOS

Key events DO reach iOS through mirroring. What decides the outcome is whether
the focused iOS app implements that shortcut — not whether the keystroke arrives.
Do not assume "keyboard never works"; assume "only shortcuts iOS itself defines
work", and verify on the device.

**Verified working** (on-device, 2026-08-31, in a focused text field):
- `Cmd+A` select all, `Cmd+C` copy, `Cmd+V` paste — a full
  type → Cmd+A → Cmd+C → Cmd+A → delete → Cmd+V round-trip restores the text.
- `Cmd+L` selects Safari's address bar — `open_url` has always depended on this.

These are the standard iOS text-editing and Safari shortcuts. `type_text` RELIES
on `Cmd+V`: characters with no keycode (CJK, emoji) are routed through the
clipboard, because CGEvent cannot drive an input method — see the next
paragraph for the failure mode that comes with it.

**Universal Clipboard is the fragile part, not the keystroke.** `Cmd+V` pastes the
*iPhone's* clipboard. Getting the Mac's pasteboard onto the phone is Continuity:
Handoff on both ends, Bluetooth + Wi-Fi, same iCloud account. With it off, the
paste silently produces nothing; worse, the sync is asynchronous, so a paste
issued too soon pastes the device's PREVIOUS clipboard value and looks like it
worked. `type_text` waits `pasteboardSyncUs` (1.5s) and pastes at most once per
call for exactly this reason.

**Still true — back navigation.** `press_key(key: "[", modifiers: ["command"])`
does NOT navigate back: `Cmd+[` is a macOS convention that iOS apps do not
implement, so the event arrives and nothing handles it. Back navigation is
OCR-detecting the "<" chevron in the top 15% of the screen and tapping it. The
explorers use `tapBackButton()`; desktop targets, which DO implement `Cmd+[`,
use it via `DesktopAppStrategy`.

**Gestures** remain the way to drive app UI: tap, swipe, drag, long press,
double tap, and `type_text` (which needs a focused text field on the iPhone).

**Not yet verified**: the shortcuts above were confirmed in system UI (Spotlight)
and, for `Cmd+L`, in Safari. Behaviour inside an arbitrary third-party app has
not been measured — if you depend on a shortcut there, test it first.

---

## CRITICAL: MCP Restart After Code Changes

After modifying any Swift source files, the running MCP server still uses the **old binary**. You MUST ask the user to run `/mcp` to restart the server before testing with MCP tools (`generate_skill`, `tap`, `describe_screen`, etc.). Without a restart, your code changes have no effect on MCP tool behavior.

---

## Sibling Repositories

This project has companion repos on the same machine. Reference them when needed:

| Repo | Local Path | Purpose |
|------|-----------|---------|
| [mirroir-skills](https://github.com/jfarcand/mirroir-skills) | `../mirroir-skills` | Community skill YAML files (apps/, workflows/, testing/) |

Compiled `.compiled.json` files live alongside their source `.yaml` in the skills repo.

## Setup After Clone

```bash
git config core.hooksPath .githooks
git submodule update --init   # .registre — the limitation-register gates
brew install ripgrep          # required by .registre/limitation-gates.sh
```

This activates the `commit-msg` hook in `.githooks/` which enforces conventional commit format, max 2-line messages, and rejects `Co-Authored-By: Claude` lines. The `.registre` submodule carries the [llm-registre](https://github.com/dravr-ai/llm-registre) gates run at pre-push and in CI; `registre.toml` at the repo root configures them (private tracker, scanned extensions, `scan_dirs`, 500-line cap, inline clippy allow-list).

### Register and completion skills

Two shell skills (`gh` + `jq`) work the private register and measure a session's completion; the hooks that drive them are wired in the tracked `.claude/settings.json`:

| Skill | Script | Hooks |
|---|---|---|
| `carnet` | `.claude/skills/carnet/carnet.sh` — claim / release / close / create / label issues in the tracker `registre.toml` names; the one path into the register (`register-limitation` files through it) | UserPromptSubmit status line for a named `carnet#N`, PreToolUse auto-claim, SessionEnd release |
| `bilan` | `.claude/skills/bilan/bilan.sh` — the 0-10 completion number from git, the carnet ledger, LIMITATION markers and CI; report its number, never a narrated one | SessionStart baseline + sweep for what a dead session left |

Each has a stub-`gh` suite (`bash .claude/skills/<skill>/test.sh`) run by `carnet.yml` / `bilan.yml` in CI.

## Package Manager: Swift Package Manager

This project uses **Swift Package Manager** (SPM) exclusively. The `Package.swift` manifest defines all targets and dependencies.

### Commands
| Task | Command |
|------|---------|
| Build | `swift build` |
| Build release | `swift build -c release` |
| Run tests | Two passes — see [Tier 2](#tier-2-pre-commit-before-committing). A bare `swift test` deadlocks. |
| Clean | `swift package clean` |
| Resolve dependencies | `swift package resolve` |

## Rust Workspace: `runner/`

The `runner/` subdirectory holds **mirroir-run**, a Rust binary that replays
mirroir YAML scenarios against web (Playwright), generic process, and HTTP
targets. It exists so mirroir scenarios can run on Linux CI without macOS-only
AppKit dependencies. See the design gists for the complete specification:

- [Complete planned solution](https://gist.github.com/jfarcand/e4cc69eeddde2ec4988aa20104566c17)
- [Brainstorm history](https://gist.github.com/jfarcand/7c30b04801ecfb6ba59c6ca1f62506f7)

### Toolchain

| Task | Command (run from `runner/`) |
|------|------------------------------|
| Format check | `cargo fmt --all -- --check` |
| Lint (zero warnings) | `cargo clippy --all-targets --all-features -- -D warnings` |
| Test | `cargo test --all-targets` |
| Security / license / source audit | `cargo deny check` |
| Build release (static-musl Linux) | `cargo build --release --target=x86_64-unknown-linux-musl` |

`rust-version = "1.96"` (edition 2024) declared in `runner/Cargo.toml` — a
policy floor tracking current stable (the code's technical minimum is 1.88,
where let-chains stabilized).

### Rust Discipline

The runner enforces a zero-tolerance Rust posture. The configuration files
under `runner/` express it mechanically; this section documents the intent.

| File | Purpose |
|------|---------|
| `runner/Cargo.toml` `[lints]` table | clippy `all`/`pedantic`/`nursery` at deny + `unwrap_used` / `expect_used` / `panic` / `todo` / `unimplemented` / `absolute_paths` / `disallowed_methods` / `str_to_string` / `cognitive_complexity` at deny; explicit allows limited to `cast_*`, `missing_const_for_fn`, `struct_excessive_bools`, `too_many_lines`, `significant_drop_tightening`, `module_name_repetitions` |
| `runner/clippy.toml` | `disallowed-methods` — `anyhow::Context::context` and `anyhow::Context::with_context` are forbidden in favor of structured `RunnerError` variants |
| `runner/deny.toml` | cargo-deny: advisories, license allowlist (MIT / Apache-2.0 / ISC / BSD-3-Clause / Unicode-3.0 / etc.), bans (`wildcards = "deny"`), sources (crates.io only) |
| `runner/scripts/ci/pre-push-validate.sh` | Tier 0 fmt → Tier 1 limitation-register gates → Tier 2 clippy → Tier 3 tests; stamps `.git/validation-passed` marker (15-min TTL) |
| `.registre/limitation-gates.sh` + `registre.toml` | The [llm-registre](https://github.com/dravr-ai/llm-registre) gates (submodule): deferral/confession prose ban, `LIMITATION(registre#n)` marker format, dark-launch ledger, 500-line file cap, inline clippy allow-list. Pre-push and CI (`limitation-register.yml`) call it with no directories so both scan the `scan_dirs` declared in `registre.toml` |

### Forbidden Patterns (CI Enforced)

These are **release-blocking** regardless of context. The clippy lints + the
limitation-register gates catch each one independently:

- **`anyhow!()` / `anyhow::anyhow!()` macros** — ABSOLUTELY FORBIDDEN in
  production code (`runner/src/`). Use structured `RunnerError` variants.
- **`anyhow::Result` type alias** — FORBIDDEN. Use `crate::error::Result` or
  the explicit `std::result::Result<T, RunnerError>` form.
- **`anyhow::Context::context` / `with_context`** — FORBIDDEN. Add a new
  `RunnerError` variant with structured fields instead.
- **`.unwrap()` in production code** — FORBIDDEN. Acceptable in tests *only* if
  they're tests (and even then, prefer `Result<()>` + `?`).
- **`.expect()` in production code** — Forbidden. Static / compile-time
  invariants that genuinely cannot fail still surface the error honestly via
  `Result`; do not silence with `.expect()`.
- **`panic!()` / `unimplemented!()` / `todo!()`** — Forbidden. Every code path
  reachable from `main()` must return a typed `Result`.
- **`#[allow(clippy::*)]` outside the declared list** — the lints that may be
  silenced inline are declared ONCE, in `allowed_inline_allows` in
  `registre.toml` (the limitation-register gate fails anything else, `#[expect]`
  included). Do not copy the list here or anywhere — read `registre.toml`.
  `cognitive_complexity` is `deny` with no inline exception; anything outside
  the declared list means fixing the underlying issue.
- **`unsafe`** — DENY level. No FFI in mirroir-run; any `unsafe` usage is a
  hard fail with no exemption.
- **Deferral / confession prose in production code** — phrases like "not yet
  wired", "is the follow-up", "for now, return", "in a real implementation"
  are banned by the limitation-register gates (Swift AND Rust). The ONLY
  exemption is a `LIMITATION(registre#n):` marker on the same line, naming the
  limited item and pointing at an issue in the private register
  (`tracker` in `registre.toml`). Implement the real thing, or register it —
  never a quiet comment. Run the `register-limitation` skill; it walks the
  whole procedure.

### Error Handling

All fallible operations return `crate::error::Result<T>` (alias for
`std::result::Result<T, RunnerError>`). New error categories add a variant to
`RunnerError` (thiserror-derived enum in `runner/src/error.rs`) with structured
fields and a `#[source]` for chaining where applicable. External crate errors
are converted via `#[from]` or `.map_err(|source| RunnerError::Variant { ..., source })`.

When constructing errors:

1. **Return a structured `RunnerError` variant** — never a stringly-typed error.
2. **Let `?` / `#[from]` do the conversion** — don't hand-build `.into()` chains
   the trait impls already cover.
3. **Add a new variant if none fits** — with structured fields and a `#[source]`,
   not a `Message(String)` catch-all that re-introduces stringly errors.
4. **Carry context as fields, not as `.context()`** — `anyhow::Context` is a hard
   clippy fail here (`runner/clippy.toml`); the context lives in the variant's
   fields.

```rust
// GOOD — structured variant, ? handles conversion
let scenario = load_scenario(&path)?;                 // From<io::Error> on RunnerError
return Err(RunnerError::TargetUnreachable {
    target: target.name.clone(),
    source: e,
});

// GOOD — map an external error into a structured variant with fields
serde_yaml::from_str(&raw)
    .map_err(|source| RunnerError::ScenarioParse { path: path.clone(), source })?;

// FORBIDDEN — CI (clippy + the limitation-register gates) fails on detection:
anyhow!("target {target} unreachable")        // anyhow! macro
something().context("loading scenario")?       // anyhow::Context
fallible().unwrap()                            // unwrap in production
```

### Test Code

Tests inline in `#[cfg(test)] mod tests` follow the same rules as production
code. Pattern: each `#[test]` function returns `Result<(), E>` where `E` is
the error variant the test produces; `?` propagates failures; `assert!`,
`assert_eq!`, `assert_matches!` for assertions; no `unwrap()`, no `expect()`,
no `panic!()`. Test functions returning Result have worked in Rust since the
2018 edition; this is the modern idiom.

### File Conventions

- Every `.rs` file starts with a **two-line `// ABOUTME:` header** (same as
  Swift files in `Sources/`).
- Max **500 lines** per file (enforced by the limitation-register gates for
  every scanned language). Past 400 lines, extract a focused helper module.
- No `#![allow(...)]` at crate root. Allows are inline at the smallest scope
  that needs them, from the `allowed_inline_allows` list in `registre.toml` only.
- `use` imports at the top of file (`clippy::absolute_paths = "deny"`).
- Public APIs documented (`missing_docs = "warn"`).

### Workflow

Same as the Swift side: feature branches → squash merge to `main`. Bug fixes
go directly to `main`. No PRs. The `commit-msg` hook applies to both Swift
and Rust commits — conventional commit format, max 2 lines, no `Co-Authored-By:
Claude`.

Before pushing, run `runner/scripts/ci/pre-push-validate.sh` from the runner
directory. The script stamps `.git/validation-passed` (timestamp + commit SHA);
the pre-push hook allows the push only when the marker is fresh (< 15 minutes)
**and** stamped for the exact commit being pushed. Amending or adding a commit
after validation invalidates the marker — re-run the script.

### Idiomatic Rust

Default to idiomatic Rust. The points below are the non-obvious or
project-enforced ones for `runner/`.

**Ownership & collections.** PREFER borrowing (`&T`, `&str`, `&[T]`) over owned
params unless ownership is needed; `Cow<T>` for conditionally owned data;
`AsRef<T>`/`Into<T>` for flexible APIs. Clone the `Arc`, never its contents
(`arc.clone()`, not `(*arc).clone()`) — `Arc`/`Rc` clones need no comment,
JUSTIFY non-obvious value clones. PREFER iterator chains, `filter_map()` over
`filter().map()`, `and_then()` over nested match; pre-size with
`with_capacity()` when the size is known. PREFER format args `format!("{name}")`
over concatenation; `&'static str` for string constants.

**Control flow, types & API design.** PREFER early returns with `?` over nested
matches; `if let` for single patterns, `match` for complex logic; exhaustive
match when every variant needs distinct handling, catch-all `_` only for
genuinely evolving enums. Newtype pattern for domain ids; `enum` over boolean
flags for state; `const fn`/associated consts for type-level values. `impl
Trait` in argument position for flexibility, concrete return types when callers
must name them. DESIGN APIs to be hard to misuse (parse, don't validate);
builder pattern for many-optional-field structs. PREFER small focused functions,
composition over inheritance, `std` over external crates when sufficient.

**Async, concurrency & performance.** PREFER `async fn` over `impl Future`;
`tokio::spawn` for concurrent tasks, `.await` for sequential; structured
concurrency via `join!`/`select!`; always handle `JoinHandle` results (don't
swallow panics). `Arc<RwLock<T>>` over `Arc<Mutex<T>>` for read-heavy; channels
over shared mutable state; atomics for simple counters. DOCUMENT every `Arc<T>`
with its sharing justification. `std::sync::LazyLock` for lazy statics,
`OnceLock` for one-time runtime init. AVOID premature `#[inline]`; `#[cold]` for
error paths; `const fn` for compile-time eval; `Box<T>` for recursive types.

**Modules & imports** (enforced by `clippy::absolute_paths = "deny"`). USE `use`
imports at the top of the file; AVOID inline qualified paths like
`std::collections::HashMap` mid-body. Qualified paths only for name collisions or
single-use clarity. PREFER flat module hierarchies.

### Architectural Discipline

These principles govern `runner/` (and generalize to the Swift side). Default
behavior is to complete the requested task — these override that when they fire.

**No backward compatibility, no legacy.** Pre-1.0, zero external API consumers,
no deprecation window. Every rename, move, or replacement is a single-commit
cutover. If you want to keep "the old path around for now," STOP and ask — the
answer is almost always "finish the migration in this branch."

**Single source of truth.** Before adding a new abstraction: grep for existing
abstractions with a similar purpose; if one exists, USE IT or DELETE it in the
same commit that replaces it. Never leave two systems doing the same job "for
compat."

**When adding, remove.** Every commit that adds a new abstraction must identify
what it replaces and delete that in the same commit.

**Use the dependency you add (no phantom integrations).** Adding a crate, then
hand-rolling a parallel version of what it does, is forbidden. If a crate is in
`runner/Cargo.toml`, its actual API must be used — not its types
imported/re-exported while a bespoke equivalent does the real work. Before
adding or extending a dependency, confirm: it's actually called (an unused
`pub use dep::{...}` is dead weight — `rg` for consumers first); you implement
its traits, not parallel ones with the same shape; you use its domain types, not
raw primitives that mirror them; it arrives as a direct dep only if used
directly. Test: if I deleted this dependency line, what breaks? If "only a
re-export no one reads," the integration is phantom — finish it or remove it.

**Forbidden patterns (junk disguised as discipline).** These freeze
architectural debt by making it *testable* instead of *fixed*. Delete them when
found; do not add them:

- `KNOWN_OFFENDERS` / `PENDING_*` / `EXEMPT_*` const arrays in tests enumerating
  files that violate an invariant — fix offenders in the same branch, or change
  the invariant.
- Adapter/wrapper types bridging an old trait to a new trait
  (`impl NewTrait for X { fn m() { call_old(...) } }`) — port the body directly,
  delete the old function and its types.
- Invariant tests policing drift between two systems ("legacy map X must stay in
  sync with registry Y") — delete X. Tests policing a *single* canonical
  system's internal consistency are fine.
- Fallback dispatch paths ("if not found in new, try legacy").
- Feature flags creating "old mode vs new mode."

Test: am I making a pre-existing parallel system *acceptable*, or replacing it?
If "acceptable," stop — that's junk.

**Complete deletion, not deprecation.** Don't mark code `// DEPRECATED` or
`// TODO remove later`. Delete it. If deletion is blocked, file an issue and link
it from the code.

### Pushback Triggers — When to Stop and Ask

STOP and surface to ChefFamille before proceeding when you find:

1. **Duplication** — two systems/modules doing similar things.
2. **Stale state** — `TODO`, `FIXME`, `for compat`, `temporary`, `v2` comments
   in code you're touching.
3. **Red CI** — workflows failing on `main`.
4. **Version drift** — two versions of the same dep in `runner/Cargo.lock`.
5. **Request conflicts with architecture** — asked to add X but X exists
   differently → surface the existing thing.
6. **Half-finished migrations** — both old and new paths still live.
7. **Adapter/wrapper added without matching deletion** — why does the old path
   still exist?
8. **Invariant test with an exception list** — you're pinning debt.
9. **Phantom dependency integration** — a crate whose API isn't actually called.

## Git Workflow: NO Pull Requests

**CRITICAL: NEVER create Pull Requests. All merges happen locally via squash merge.**

### Rules
- **NEVER use `gh pr create`** or any PR creation command
- **NEVER suggest creating a PR**
- Feature branches are merged via **local squash merge**

### Workflow for Features
1. Create feature branch: `git checkout -b feature/my-feature`
2. Make commits, push to remote: `git push -u origin feature/my-feature`
3. When ready, squash merge locally (from main worktree):
   ```bash
   git checkout main
   git fetch origin
   git merge --squash origin/feature/my-feature
   git commit
   git push
   ```
4. Delete the spent branch, local and remote — this is part of the merge, not a
   separate decision to raise:
   ```bash
   git diff --stat main origin/feature/my-feature   # must be empty
   git branch -D feature/my-feature
   git push origin --delete feature/my-feature
   ```
   A squash merge leaves no merge parent, so `git branch -d` will not recognize
   the branch as merged — verify with the empty diff above, then use `-D`.

The merge itself is a documented procedure, not an approval gate. Whoever is
holding a validated branch performs steps 3 and 4; do not park a green branch
waiting for someone to authorize the merge.

### Bug Fixes
- Bug fixes go directly to `main` branch (no feature branch needed)
- Commit and push directly: `git push origin main`

## Architecture

This project follows established decomposition patterns. When adding new functionality, match these patterns — do not invent new structural idioms.

### File Size Limit

No file should exceed **500 lines** (enforced mechanically by the limitation-register gates, pre-push and in CI). If a type is growing past this threshold, extract a focused helper type or enum. Reference: `LandmarkPicker` and `ActionStepFormatter` were extracted from `SkillMdGenerator` for this reason.

### Pattern Catalog

Apply the pattern whose trigger condition matches your situation:

| Trigger | Pattern | Example |
|---------|---------|---------|
| New MCP tool category | **Extension-Based Tool Registration**: create `XxxTools.swift` with `registerXxxTools()`, wire from `ToolHandlers.registerTools()` | `InputTools.swift`, `ScreenTools.swift` |
| Tool handler needs business logic | **Thin Registration → Delegate**: tool file owns schema + arg parsing only; separate type owns logic | `InputTools.swift` → `InputSimulation.swift` |
| New system boundary (hardware, OS API, network) | **Protocol Abstraction**: define protocol in `Protocols.swift`, implement in concrete type | `WindowBridging`/`MirroringBridge`, `InputProviding`/`InputSimulation` |
| Pure transformation (filter, format, match, compute) | **Enum Namespace**: stateless enum, all `static func`, no stored properties | `LandmarkPicker`, `ActionStepFormatter`, `ElementMatcher` |
| Multi-step stateful workflow (start/accumulate/finalize) | **Session Accumulator**: `final class` with `NSLock`, explicit lifecycle methods | `ExplorationSession` |
| Wrapping a protocol to add observation/caching | **Decorator**: new type conforming to same protocol, forwarding + adding behavior | `RecordingDescriber` wraps `ScreenDescribing` |
| Two input formats producing related models | **Separate Parsers per Format**: one parser per format, each emitting the model that format supports | `SkillParser` (YAML) → `SkillDefinition`/`[SkillStep]`; `SkillMdParser` (SKILL.md) → `SkillHeader` + markdown body |
| Generator building structured output from data | **Pipeline with Composable Stages**: generator delegates filtering/formatting to enum-namespace helpers | `SkillMdGenerator` uses `LandmarkPicker` + `ActionStepFormatter` |
| CLI subcommand | **Command Enum**: `enum XxxCommand` with `static func run(arguments:) -> Int32` | `DoctorCommand`, `MigrateCommand`, `CompileCommand` |
| Types shared across `mirroir-mcp` and test targets | **HelperLib target**: value types, enums, utilities in `Sources/HelperLib/` | `EnvConfig`, `MCPProtocol`, `PermissionPolicy` |

### Decision Sequence for New Code

When creating a new type or file, walk this checklist in order:

1. **Does it cross a system boundary?** → Protocol in `Protocols.swift` + concrete implementation file.
2. **Is it an MCP tool?** → `XxxTools.swift` with `registerXxxTools()`, wired from `ToolHandlers`. Business logic in a separate type.
3. **Is it a pure transformation?** → Enum with `static` methods. No init, no stored properties.
4. **Is it a stateful workflow?** → Session accumulator with explicit lifecycle and `NSLock`.
5. **Is it growing past 400 lines?** → Stop and extract. Identify the secondary concern and move it to its own enum-namespace helper.

### Prohibited Structural Choices

- NEVER put business logic directly inside a tool registration handler. The handler parses args and delegates.
- NEVER define a new protocol outside `Protocols.swift` (system boundaries) or `ExplorationProtocols.swift` (exploration domain: strategy, explorer, navigation graph, backtracking, lifecycle, advising) unless it is internal to a single file.
- NEVER add a new SPM target without discussing with ChefFamille first.
- NEVER put types used only by `mirroir-mcp` into `HelperLib`. HelperLib is for cross-target shared types only.

# Writing code

- CRITICAL: NEVER USE --no-verify WHEN COMMITTING CODE
- We prefer simple, clean, maintainable solutions over clever or complex ones, even if the latter are more concise or performant. Readability and maintainability are primary concerns.
- Make the smallest reasonable changes to get to the desired outcome. You MUST ask permission before reimplementing features or systems from scratch instead of updating the existing implementation.
- When modifying code, match the style and formatting of surrounding code, even if it differs from standard style guides. Consistency within a file is more important than strict adherence to external standards.
- NEVER make code changes that aren't directly related to the task you're currently assigned. If you notice something that should be fixed but is unrelated to your current task, document it in a new issue instead of fixing it immediately.
- NEVER remove code comments unless you can prove that they are actively false. Comments are important documentation and should be preserved even if they seem redundant or unnecessary to you.
- All code files should start with a brief 2 line comment explaining what the file does. Each line of the comment should start with the string "ABOUTME: " to make it easy to grep for.
- When writing comments, avoid referring to temporal context about refactors or recent changes. Comments should be evergreen and describe the code as it is, not how it evolved or was recently changed.
- When you are trying to fix a bug or compilation error or any other issue, YOU MUST NEVER throw away the old implementation and rewrite without explicit permission from the user. If you are going to do this, YOU MUST STOP and get explicit permission from the user.
- NEVER name things as 'improved' or 'new' or 'enhanced', etc. Code naming should be evergreen. What is new today will be "old" someday.
- NEVER add placeholder or dead code or mock or name variable starting with _
- Do not hard code magic values
- Do not leave implementation with "In future versions" or "Implement the code" or "Fall back". Always implement the real thing.
- Commit without AI assistant-related commit messages. Do not reference AI assistance in git commits.
- Do not add AI-generated commit text in commit messages
- **Commit messages MUST use conventional commit format:** `type(scope): description`
  - Types: `feat`, `fix`, `chore`, `docs`, `test`, `refactor`, `ci`, `style`, `perf`, `build`, `revert`
  - Scope is optional. Multi-scope with `|` is permitted: `fix(module|context): description`
  - Examples: `feat: add check_health tool`, `fix(skills): handle YAML block scalars`, `docs: update architecture guide`
  - The `commit-msg` hook in `.githooks/` enforces this — non-conventional commits are rejected.
- Always create a branch when adding new features. Bug fixes go directly to main branch.
- Always run validation after making changes: `swift build`, then BOTH test passes from Tier 2 below. A bare `swift test --skip IntegrationTests` deadlocks.

## Security Engineering Rules

### Logging Hygiene
- NEVER log: access tokens, refresh tokens, API keys, passwords, client secrets
- Redact or hash sensitive fields before logging

## Command Permissions

I can run any command WITHOUT permission EXCEPT:
- Commands that delete or overwrite files (rm, mv with overwrite, etc.)
- Commands that modify system state (chmod, chown, sudo)
- Commands with --force flags
- Commands that write to files using > or >>
- In-place file modifications (sed -i, etc.)

Everything else, including all read-only operations and analysis tools, can be run freely.

## Required Pre-Commit Validation

### Tiered Validation Approach

#### Tier 1: Quick Iteration (during development)
Run after each code change to catch errors fast:
```bash
# 1. Build
swift build

# 2. Run ONLY tests related to your changes
swift test --filter <TestClassName>/<testMethodName>
# Example: swift test --filter HelperLibTests.AppleScriptKeyMapTests

# A swift-testing @Suite (e.g. AppleVisionTextRecognizerTests) needs its own flags.
# Filtering one WITHOUT them reports "Executed 0 tests" — which is a FAILED
# verification, not a pass. Always confirm the test count is greater than zero.
swift test --filter AppleVisionTextRecognizerTests --disable-xctest --no-parallel
```

#### Tier 2: Pre-Commit (before committing)
Run before creating a commit:
```bash
# 1. Full build
swift build

# 2. Run unit tests in TWO passes (integration tests run on CI only).
#    XCTest and swift-testing deadlock when run together in parallel, so each
#    test runner gets its own invocation. This is exactly what every workflow
#    in .github/workflows/ runs — never a bare `swift test`.
swift test --skip IntegrationTests --disable-swift-testing
swift test --skip IntegrationTests --disable-xctest --no-parallel
```

#### Tier 3: Full Validation (before merge only)
Run the full suite when preparing to merge:
```bash
swift build -c release
swift test --skip IntegrationTests --disable-swift-testing
swift test --skip IntegrationTests --disable-xctest --no-parallel
```

#### Tier 4: Real-Device Validation (REQUIRED before squash-merge to main)

**CRITICAL: NEVER squash-merge a feature branch to main without real iPhone testing first.**

This is an iPhone Mirroring tool. Unit tests with mocks prove logic correctness but cannot validate real-world behavior. OCR results, scroll physics, alert timing, and tap reliability all behave differently on a real device.

**For any feature touching DFS exploration, input, OCR, or screen interaction:**
1. Build and run: `swift build`
2. Test with a real app on the connected iPhone using the MCP tools (e.g. `generate_skill(action: "explore", app_name: "Settings")`)
3. Verify the feature works end-to-end: correct taps, correct OCR, correct output
4. Only after real-device confirmation: squash-merge to main

**What real-device testing catches that mocks miss:**
- OCR element positions and text that differ from synthetic test data
- Scroll settling times and scroll-exhaustion thresholds
- Alert dialog appearance timing and dismiss button coordinates
- Tab bar detection on real app layouts
- Backtrack navigation (OCR back-chevron tap) behavior across iOS versions

**Commit to feature branch first, test on device, then merge.** The feature branch is the staging area. Main is the release branch.

### Test Output Verification - MANDATORY

**After running ANY test command, you MUST verify tests actually ran.**

**Red Flags - STOP and investigate if you see:**
- `Executed 0 tests` - Wrong filter or no tests found
- All tests skipped or filtered out

**Verification checklist:**
1. Confirm test count > 0 in the summary
2. Confirm all tests passed
3. If 0 tests ran, the validation FAILED - do not proceed

**Never claim "tests pass" if 0 tests ran - that is a failure, not a success.**

## Error Handling Requirements

### Acceptable Error Handling
- Swift `throws` / `try` / `catch` for error propagation
- `Result<T, Error>` for async or callback-based error handling
- Custom error types conforming to `Error` protocol
- Optional chaining and `guard let` for nil checks

### Prohibited Error Handling
- `try!` except for static data known to be valid at compile time
- `fatalError()` except in unreachable code paths or test assertions
- Force unwrapping (`!`) except for:
  - Static data known to be valid at compile time
  - Test code with clear failure expectations

## Mock Policy

### Real Implementation Preference
- PREFER real implementations over mocks in all production code
- NEVER implement mock modes for production features

### Acceptable Mock Usage (Test Code Only)
Mocks are permitted ONLY in test code for:
- Testing error conditions that are difficult to reproduce consistently
- Simulating network failures or timeout scenarios
- Testing against external APIs with rate limits during CI/CD
- Simulating hardware failures or edge cases

### Mock Requirements
- All mocks MUST be clearly documented with reasoning
- Mock usage MUST be isolated to test modules only
- Mock implementations MUST be realistic and representative of real behavior
- Tests using mocks MUST also have integration tests with real implementations

## Documentation Standards

### Code Documentation
- All public APIs MUST have comprehensive doc comments
- Use `///` for public API documentation
- Use `//` for inline implementation comments
- Document error conditions and thrown errors
- Include usage examples for complex APIs

### Module Documentation
- Each file MUST have the ABOUTME header explaining its purpose
- Document the relationship between modules
- Explain design decisions and trade-offs

### README Requirements
- Keep README.md current with actual functionality
- Include setup instructions that work from a clean environment
- Document all environment variables and configuration options
- Provide troubleshooting section for common issues

## Task Completion Protocol - MANDATORY

### Before Claiming ANY Task Complete:

1. **Run Validation:**
   ```bash
   swift build
   swift test --skip IntegrationTests --disable-swift-testing
   swift test --skip IntegrationTests --disable-xctest --no-parallel
   ```

2. **Manual Pattern Audit:**
   - Search for each banned pattern listed above
   - Justify or eliminate every occurrence
   - Document any exceptions with detailed reasoning

3. **Documentation Review:**
   - All public APIs documented
   - README updated if functionality changed
   - File headers (ABOUTME) present and accurate

4. **Architecture Review:**
   - Error handling follows proper patterns throughout
   - No code paths that bypass real implementations
   - No force unwraps in production code (unless justified)
   - Every new file follows a pattern from the Architecture Pattern Catalog
   - No file exceeds 500 lines
   - Tool registration files contain zero business logic
   - New system boundaries have a protocol in `Protocols.swift`

### Failure Criteria
If ANY of the above checks fail, the task is NOT complete regardless of test passing status.

# Getting help

- ALWAYS ask for clarification rather than making assumptions.
- If you're having trouble with something, it's ok to stop and ask for help. Especially if it's something your human might be better at.

# Testing

- Tests MUST cover the functionality being implemented.
- NEVER ignore the output of the system or the tests - Logs and messages often contain CRITICAL information.
- If the logs are supposed to contain errors, capture and test it.
- NO EXCEPTIONS POLICY: Under no circumstances should you mark any test type as "not applicable". Every project, regardless of size or complexity, MUST have unit tests, integration tests, AND end-to-end tests. If you believe a test type doesn't apply, you need the human to say exactly "I AUTHORIZE YOU TO SKIP WRITING TESTS THIS TIME"

## Test Integrity: No Skipping, No Ignoring

**CRITICAL: All tests must run and pass. No exceptions.**

### Forbidden Patterns
- **Swift**: NEVER use `XCTSkip` or comment out test methods to make tests pass
- **CI Workflows**: NEVER use `continue-on-error: true` on test jobs
- **Any language**: NEVER comment out tests to make CI pass

### If a Test Fails
1. **Fix the code** - not the test
2. **Fix the test** - only if the test itself is wrong
3. **Ask for help** - if you're stuck, don't skip

### Rationale
Skipped/ignored tests become forgotten tech debt. A red CI that gets ignored is worse than no CI at all.
