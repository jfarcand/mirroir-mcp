## Sibling Repositories

This project has companion repos on the same machine. Reference them when needed:

| Repo | Local Path | Purpose |
|------|-----------|---------|
| [mirroir-skills](https://github.com/jfarcand/mirroir-skills) | `../mirroir-skills` | Community skill YAML files (apps/, workflows/, testing/) |

Compiled `.compiled.json` files live alongside their source `.yaml` in the skills repo.

## Package Manager: Swift Package Manager

This project uses **Swift Package Manager** (SPM) exclusively. The `Package.swift` manifest defines all targets and dependencies.

### Commands
| Task | Command |
|------|---------|
| Build | `swift build` |
| Build release | `swift build -c release` |
| Run tests | `swift test` |
| Clean | `swift package clean` |
| Resolve dependencies | `swift package resolve` |

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

### Bug Fixes
- Bug fixes go directly to `main` branch (no feature branch needed)
- Commit and push directly: `git push origin main`

## Architecture

This project follows established decomposition patterns. When adding new functionality, match these patterns — do not invent new structural idioms.

### File Size Limit

No file should exceed **500 lines**. If a type is growing past this threshold, extract a focused helper type or enum. Reference: `LandmarkPicker` and `ActionStepFormatter` were extracted from `SkillMdGenerator` for this reason.

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
| Two input formats producing same output type | **Separate Parsers, Shared Model**: one parser per format, both emit same type | `SkillParser` (YAML) + `SkillMdParser` (Markdown) → `SkillStep` |
| Generator building structured output from data | **Pipeline with Composable Stages**: generator delegates filtering/formatting to enum-namespace helpers | `SkillMdGenerator` uses `LandmarkPicker` + `ActionStepFormatter` |
| CLI subcommand | **Command Enum**: `enum XxxCommand` with `static func run(arguments:) -> Int32` | `DoctorCommand`, `MigrateCommand`, `CompileCommand` |
| Types shared by both `mirroir-mcp` and `mirroir-helper` | **HelperLib target**: value types, enums, utilities in `Sources/HelperLib/` | `TapPoint`, `EnvConfig`, `MCPProtocol` |

### Decision Sequence for New Code

When creating a new type or file, walk this checklist in order:

1. **Does it cross a system boundary?** → Protocol in `Protocols.swift` + concrete implementation file.
2. **Is it an MCP tool?** → `XxxTools.swift` with `registerXxxTools()`, wired from `ToolHandlers`. Business logic in a separate type.
3. **Is it a pure transformation?** → Enum with `static` methods. No init, no stored properties.
4. **Is it a stateful workflow?** → Session accumulator with explicit lifecycle and `NSLock`.
5. **Is it growing past 400 lines?** → Stop and extract. Identify the secondary concern and move it to its own enum-namespace helper.

### Prohibited Structural Choices

- NEVER put business logic directly inside a tool registration handler. The handler parses args and delegates.
- NEVER define a new protocol outside `Protocols.swift` unless it is internal to a single file.
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
  - The pre-commit hook enforces this — non-conventional commits are rejected.
- Always create a branch when adding new features. Bug fixes go directly to main branch.
- Always run validation after making changes: `swift build` then `swift test`

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
```

#### Tier 2: Pre-Commit (before committing)
Run before creating a commit:
```bash
# 1. Full build
swift build

# 2. Run all tests
swift test
```

#### Tier 3: Full Validation (before merge only)
Run the full suite when preparing to merge:
```bash
swift build -c release
swift test
```

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
   swift test
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
