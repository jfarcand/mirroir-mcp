# Judge profile registry

The `judge:` step scores a captured response against an "expected signal"
using an LLM. Source of truth: `JudgeProfile` and `builtin_profiles()` live in
`runner/src/oracle/judge_profiles.rs` (`runner/src/oracle/judge.rs` re-exports
them); the scoring call itself is `runner/src/oracle/judge.rs`. CI uses
**Ollama** exclusively — no remote LLM, no secret keys.

## Built-in profiles

| Name | Base URL | Model | API key env | Timeout |
|---|---|---|---|---|
| `fast-ci` | `https://api.openai.com/v1/chat/completions` | `gpt-4o-mini` | `OPENAI_API_KEY` | 30 s |
| `byte-stable` | `http://127.0.0.1:11434/v1/chat/completions` | `qwen2.5:0.5b` | *(none — local)* | 60 s |
| `cheap-local` | `http://127.0.0.1:11434/v1/chat/completions` | `qwen2.5:0.5b` | *(none — local)* | 30 s |

CI (`runner-e2e` lane) installs Ollama, starts the daemon, pulls
`qwen2.5:0.5b`, and points scenarios at the `byte-stable` profile. The
`fast-ci` profile is provided for users who want hosted scoring locally;
it is not exercised by CI to keep runs free of remote-LLM dependencies.

## Wire format

All profiles speak the **OpenAI chat-completions** API. Anthropic's API can be
adapted via a base-URL override; Ollama natively exposes a compatible endpoint
at `/v1/chat/completions`.

Request shape the runner sends:

```json
{
  "model": "qwen2.5:0.5b",
  "messages": [{"role": "user", "content": "<prompt>"}],
  "temperature": 0.0
}
```

`temperature: 0.0` keeps scoring deterministic across runs.

## Prompt template

The runner builds the prompt verbatim from this template
(`runner/src/oracle/judge.rs::build_prompt`):

```
You are a deterministic test oracle. Given an AI agent's response,
score how well it matches the expected outcome. Return ONLY a single
decimal number between 0.0 (total failure) and 1.0 (perfect match),
with at most three decimal places. Do not include any other text,
justification, or punctuation.

Expected outcome: <expected_signal | default fallback>

Agent response:
```
<response_text>
```

Score:
```

The `user_prompt_template_hash` field on the YAML `judge:` step pins the
SHA-256 of the canonical prompt template (formatted `sha256:<hex>`). The runner
verifies it on **every** invocation: `verify_template_hash` runs first thing in
`run_judge` (`runner/src/oracle/judge.rs::run_judge`), and a mismatch hard-fails
the step with `RunnerError::JudgeTemplateMismatch` — the scenario must be
re-pinned. This keeps a score calibrated against one prompt from silently
running against a changed prompt.

## Score parsing

The runner is tolerant of typical model formatting:

- leading/trailing whitespace
- a leading `Score:` / `score:` prefix
- a trailing period

Anything that doesn't parse as a finite `f64` in `[0, 1]` is rejected
with `RunnerError::JudgeDecode`. Out-of-range values (e.g., `1.5`) also
reject — protects against hallucinated scores.

## Threshold logic

```yaml
- judge:
    profile: byte-stable
    pass_threshold: 0.8
    pass_threshold_tolerance: 0.05    # optional
    ...
```

Effective threshold = `pass_threshold - tolerance`. If `pass_threshold = 0.8`
and `tolerance = 0.05`, scores ≥ 0.75 pass. The tolerance band absorbs
hosted-model stochasticity (less relevant for local Ollama at temperature=0,
but kept for consistency).

`RunnerError::JudgeBelowThreshold` is raised when `score < effective`.

## Adding a custom profile

The built-in registry covers the common cases. The canonical way to add your
own is an `oracles/profiles.yaml` overlay:

1. Create `~/.mirroir/oracles/profiles.yaml` with a required `version: 1`
   and a `profiles:` list (versioning rules:
   [scenario-grammar.md](scenario-grammar.md#versioning)).
2. Add an entry with `name`, `base_url`, `model`, `api_key_env`
   (omit for local providers), and optionally `timeout_s` (default 30 s).
3. Scenarios reference the new name via `judge.profile: <name>`.

```yaml
version: 1
profiles:
  - name: my-judge
    base_url: https://example.test/v1/chat/completions
    model: my-model
    api_key_env: MY_KEY
    timeout_s: 45
```

To change a built-in's endpoint or credential binding, redeclare its `name`
in the same file. (Built-ins can also be added directly in
`runner/src/oracle/judge_profiles.rs::builtin_profiles()`.)

## Profile trust model

Overlay files are loaded by trust level (`JudgeRegistry::load` in
`runner/src/oracle/judge_profiles.rs`), so a checked-out repository cannot
redirect judge prompts and API keys to an attacker-controlled host:

- **Trusted** — built-in profiles and `~/.mirroir/oracles/profiles.yaml` (the
  user's own machine config). May set every field — `base_url`, `api_key_env`,
  `model`, `timeout_s` — override a built-in's endpoint, and define brand-new
  profiles.
- **Untrusted** — `<repo>/oracles/profiles.yaml` and
  `<repo>/.mirroir/oracles/profiles.yaml` (repo-local config). May only tune
  `model` / `timeout_s` of an **existing** profile. A repo-local `base_url` /
  `api_key_env` change or a brand-new profile name is ignored with a warning,
  keeping the trusted endpoint and credential binding intact.

The repo-local `.mirroir/oracles/profiles.yaml` here is the runner's consumer
dotfile (`.mirroir/`), distinct from the Swift MCP's home directory
(`.mirroir-mcp/`).

## Local development setup (matches CI)

```bash
# 1. Install Ollama (macOS) — the cask bundles llama-server; the
#    Homebrew formula bottle omits it, which makes the judge return HTTP 500.
brew install --cask ollama-app

# 1. Install Ollama (Linux)
curl -fsSL https://ollama.com/install.sh | sh

# 2. Start the daemon
ollama serve &

# 3. Pull the CI-pinned model
ollama pull qwen2.5:0.5b

# 4. Sanity probe
curl -sf http://127.0.0.1:11434/api/version | jq .
```

Once Ollama is up, scenarios using `profile: byte-stable` (or `cheap-local`)
work without any additional flags.

## Drift detection alongside `judge:`

Every judge step feeds the scenario's drift session, so drift detection runs
**after** the judge passes — a second gate on top of LLM scoring. By default
the comparison is against `.harness/last-green.json`; `drift_baseline_file`
names an explicit file to compare against instead, and
`response_drift.max_levenshtein_pct` overrides the resolved ceiling for that one
step. Implementation lives in
`runner/src/oracle/drift.rs` (Jaccard fingerprint + normalized Levenshtein
distance, pure functions, no I/O).

Drift verdict:

- `Match` when `levenshtein_pct ≤ max_levenshtein_pct`.
- `Drift` otherwise; the runner returns `RunnerError::DriftDetected`.

See [scenario-grammar.md](scenario-grammar.md) for the `response_drift`
field shape.
