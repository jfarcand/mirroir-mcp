# Configuration

All settings live in `settings.json` — project-local (`.mirroir-mcp/settings.json`) or global (`~/.mirroir-mcp/settings.json`). Project-local settings override global ones.

```json
{
  "screenDescriberMode": "auto",
  "agent": "embacle",
  "visionImageWidth": 500,
  "ocrBackend": "auto",
  "keystrokeDelayUs": 20000,
  "clickHoldUs": 100000
}
```

Every setting has a corresponding environment variable (e.g. `MIRROIR_SCREEN_DESCRIBER_MODE`, `MIRROIR_KEYSTROKE_DELAY_US`). Resolution order: project-local `settings.json` → global `settings.json` → environment variable → built-in default.

Env-var names are derived from the camelCase key by inserting `_` before every uppercase letter and screaming-snake-casing the result. This means adjacent capitals in an acronym are each split: `openAITimeoutSeconds` → `MIRROIR_OPEN_A_I_TIMEOUT_SECONDS` and `defaultAIMaxTokens` → `MIRROIR_DEFAULT_A_I_MAX_TOKENS`. A handful of keys override this with a fixed env var (e.g. `keyboardLayout` → `IPHONE_KEYBOARD_LAYOUT`, `mirroringBundleID` → `MIRROIR_BUNDLE_ID`, `mirroringProcessName` → `MIRROIR_PROCESS_NAME`).

## Screen Intelligence

| Setting | Default | Description |
|---------|---------|-------------|
| `screenDescriberMode` | `"auto"` | `"auto"` uses vision when embacle FFI is linked, OCR otherwise. `"vision"` forces AI vision, `"ocr"` forces local OCR + YOLO |
| `agent` | `""` | AI agent name for vision mode and diagnosis (e.g. `"embacle"`, `"embacle:claude"`) |
| `agentTransport` | `"auto"` | Agent transport: `"auto"` runs an `embacle` agent whose model is a bare Copilot model id on the embedded Rust FFI when it is linked, HTTP otherwise. A `runner:model` embacle model (e.g. `embacle:claude` → `claude:sonnet`), a bare embacle-server runner name (`claude`, `copilot`, `gemini`, …, meaning that runner's default model) and every Anthropic, OpenAI and Ollama agent always use HTTP. `"http"` forces HTTP for everything |
| `visionImageWidth` | `500` | Target image width in pixels for vision API calls (screenshots are resized before sending) |
| `visionModel` | `""` | Override the model name sent in vision chat completion requests. Empty = the agent's own model. The value also decides the transport under the `agentTransport` rule |
| `ocrBackend` | `"auto"` | OCR backend: `"auto"`, `"vision"` (text only), `"yolo"` (icons only), or `"both"` |
| `ocrRecognitionLevel` | `"accurate"` | Apple Vision OCR quality: `"accurate"` or `"fast"` |
| `ocrLanguageCorrection` | `true` | Enable language correction during OCR text recognition |
| `ocrMinImageWidth` | `600` | Minimum screenshot pixel width before OCR. Images narrower than this are upscaled before text recognition to improve detection on small zoom modes |
| `ocrLanguages` | `["en-US"]` | BCP-47 language codes for `VNRecognizeTextRequest.recognitionLanguages`. Add languages to recognise non-Latin scripts (e.g. `["ja-JP","en-US"]`). Also configurable via `MIRROIR_OCR_LANGUAGES` env var (comma-separated) |
| `describeScreenOmitScreenshot` | `false` | Omit the screenshot image from `describe_screen` responses to save context window space in long automation sessions |
| `yoloModelURL` | `""` | URL to download a YOLO `.mlmodel` on first use |
| `yoloModelPath` | `""` | Local path to a pre-compiled `.mlmodelc` directory (overrides download) |
| `yoloConfidenceThreshold` | `0.3` | Minimum confidence for YOLO element detections (0.0–1.0) |

## Input Timing

| Setting | Default | Description |
|---------|---------|-------------|
| `keystrokeDelayUs` | `15000` | Delay between keystrokes in microseconds |
| `pasteboardSyncUs` | `1500000` | Wait after writing the Mac pasteboard before `type_text` presses Cmd+V, so Universal Clipboard can carry it to the iPhone (microseconds) |
| `pasteVerifyTimeoutUs` | `2000000` | Longest wait after Cmd+V for a pasted run to appear on screen; past it `type_text` fails instead of reporting success (microseconds) |
| `pasteVerifyPollUs` | `250000` | Gap between OCR reads while waiting for a pasted run (microseconds) |
| `pasteVerifyWindowChars` | `6` | Trailing OCR-readable characters of the entered line, ending with the pasted run, that must appear on screen to count a paste as delivered |
| `clickHoldUs` | `80000` | Click hold duration in microseconds |
| `doubleTapHoldUs` | `40000` | Hold duration per tap in a double-tap gesture (microseconds) |
| `doubleTapGapUs` | `50000` | Gap between taps in a double-tap (microseconds) |
| `dragModeHoldUs` | `150000` | Initial hold before drag movement for iOS drag recognition (microseconds) |
| `focusSettleUs` | `200000` | Delay after focus click for keyboard focus to settle (microseconds) |
| `deadKeyDelayUs` | `30000` | Delay between dead-key trigger and base character for accented input (microseconds) |
| `defaultDragDurationMs` | `1000` | Default drag gesture duration in milliseconds |
| `defaultLongPressDurationMs` | `500` | Default long press duration in milliseconds |
| `defaultSwipeDurationMs` | `300` | Default swipe duration in milliseconds |

## Scroll & Swipe

| Setting | Default | Description |
|---------|---------|-------------|
| `swipeDistanceFraction` | `0.3` | Swipe distance as a fraction of window height |
| `scrollSwipeFromYFraction` | `0.56` | Scroll start Y as a fraction of window height |
| `scrollSwipeToYFraction` | `0.11` | Scroll end Y as a fraction of window height |
| `defaultScrollMaxAttempts` | `10` | Maximum scroll attempts for `scroll_to` before giving up |
| `scrollDedupStrategy` | `"exact"` | Dedup strategy for scroll-collected elements: `"exact"`, `"levenshtein"`, `"proximity"` |
| `scrollDedupLevenshteinMax` | `3` | Maximum Levenshtein edit distance for fuzzy text dedup (used by `"levenshtein"` strategy) |
| `scrollDedupProximityPt` | `15.0` | Maximum Euclidean distance in points for coordinate proximity dedup (used by `"proximity"` strategy) |

## Exploration

| Setting | Default | Description |
|---------|---------|-------------|
| `explorationMaxDepth` | `6` | Maximum BFS/DFS depth before forcing backtrack |
| `explorationMaxScreens` | `30` | Maximum distinct screens before stopping exploration |
| `explorationMaxTimeSeconds` | `300` | Maximum wall-clock seconds before stopping exploration |
| `componentDetection` | `"llm_first_screen"` | Component detection mode: `"heuristic"`, `"llm_first_screen"`, `"llm_every_screen"`, `"llm_fallback"` |
| `calibrationStrict` | `false` | Fail exploration if too many elements are unclassified after calibration |
| `calibrationUnclassifiedThreshold` | `0.5` | Maximum fraction of unclassified content elements (0.0–1.0) before calibration fails |
| `compiledTapArrivalMinTexts` | `3` | Fewest multi-character structural texts the screen a coordinate-only (icon) tap leads to must hold. `record_step` refuses a barer destination and replay fails it, since such a screen cannot prove the tap worked |
| `compiledTapPositionTolerance` | `5.0` | Points (per axis) a labeled compiled tap's element may sit from its recorded position and still be tapped there; farther away, replay taps the element where OCR finds it now. An element OCR cannot find fails the step |

## Keyboard Layout

| Setting | Default | Description |
|---------|---------|-------------|
| `keyboardLayout` | `""` | iPhone hardware-keyboard layout; `type_text` presses the key that types each character on it (e.g. `"Canadian-CSA"`, `"French"`). Empty or `"US"` = US QWERTY |

## App Identity

| Setting | Default | Env Var | Description |
|---------|---------|---------|-------------|
| `mirroringBundleID` | `"com.apple.ScreenContinuity"` | `MIRROIR_BUNDLE_ID` | Bundle ID of the window to target. Override to point at a stand-in app (e.g. FakeMirroring) for local/CI runs |
| `mirroringProcessName` | `"iPhone Mirroring"` | `MIRROIR_PROCESS_NAME` | Process name of the target window, used alongside the bundle ID for window lookup |
| `cursorFreeInput` | `false` | `MIRROIR_CURSOR_FREE` | Post mouse events directly to the target PID via `postToPid` instead of global HID posting. Works for regular macOS apps (e.g. FakeMirroring) for local integration tests without cursor interference, but NOT for iPhone Mirroring — per-process injection does not register taps there |

## AI Provider Timeouts

| Setting | Default | Description |
|---------|---------|-------------|
| `openAITimeoutSeconds` | `30` | Timeout for OpenAI API requests |
| `anthropicTimeoutSeconds` | derived (`450`) | Timeout for one Anthropic API request. Requests are non-streaming, so the deadline must cover a reply that uses the request's whole `max_tokens` budget. Unset, it is derived from the `max_tokens` the request sends (`anthropicMaxTokens` for the built-in agents, a profile's own `max_tokens` otherwise) at the Anthropic SDKs' planning rate of 128000 output tokens per hour: 16000 tokens -> 450 s, never below 30 s and never above 600 s. 600 s is the SDKs' ~10-minute non-streaming limit, past which an idle connection is dropped, so a budget above ~21000 tokens is unsupported: it needs streaming, which mirroir does not use. Set it only to pin a fixed deadline for every Anthropic request |
| `ollamaTimeoutSeconds` | `120` | Timeout for Ollama API requests |
| `embacleTimeoutSeconds` | `60` | Timeout for embacle FFI/API requests |
| `commandTimeoutSeconds` | `60` | Timeout for command-based AI agent processes |
| `defaultAIMaxTokens` | `1024` | Maximum tokens for AI model responses |
| `anthropicMaxTokens` | `16000` | Maximum tokens for the built-in Anthropic agents (and Anthropic YAML profiles without `max_tokens`). Higher than `defaultAIMaxTokens` because current Claude models always think, and thinking tokens count toward the limit |
| `anthropicEffort` | `"low"` | `output_config.effort` sent on Anthropic diagnosis calls (`low`, `medium`, `high`, `xhigh`, `max`, case-insensitive); controls how much the model thinks. Any other value falls back to `low` and prints one warning on stderr |
| `visionMaxTokens` | `8192` | Maximum tokens for vision chat-completion responses. Higher than `defaultAIMaxTokens` because home screens with 20+ elements need more output room |

## System Prompts

The AI system prompts are built into the binary. To replace one, drop a same-named Markdown file into a prompt directory. The file is read on every call, so an override takes effect immediately:

| File | Replaces |
|------|----------|
| `diagnosis.md` | The failure-diagnosis prompt sent with `mirroir test --agent` |
| `screen-describe.md` | The vision prompt used by AI vision mode (`describe_screen` via embacle). Keep its output contract: a JSON array of objects with `label`, `x`, `y`, and `type` |

Prompt directories are searched in order, and the first non-empty file wins:

1. `<cwd>/.mirroir-mcp/prompts/` (project-local)
2. `~/.mirroir-mcp/prompts/` (global)
3. The built-in prompt

An agent profile's `system_prompt` key takes precedence over `diagnosis.md` for that agent.

An override replaces the built-in prompt completely, so it also hides every later improvement to it. Older `mirroir.sh` installs copied both `diagnosis.md` and `screen-describe.md` into `~/.mirroir-mcp/prompts/`; unless you edited a copy yourself, delete it so the built-in prompt takes effect. `mirroir doctor` lists each active override file by path.

## Patterns

Patterns are not configured via `settings.json` — they are file-based. See [Patterns & Skills](components.md) for:

- **Element patterns** (`patterns/elements/`) — row-level UI recognition definitions
- **Screen patterns** (`patterns/screens/`) — archetype recipes matching element compositions to navigation models
- **App patterns** (`patterns/apps/`) — APP.md files with `archetype`, obstacles, skip lists, and credentials

Element patterns are discovered from both the project-local `.mirroir-mcp/skills/patterns/elements/` and the home `~/.mirroir-mcp/skills/patterns/elements/` directories, so a `git clone … ~/.mirroir-mcp/skills` install is picked up automatically. The MCP home directory `.mirroir-mcp/` is distinct from the runner consumer dotfile `.mirroir/`.

## Advanced Tuning

Additional low-level tuning constants (icon detection, scroll deduplication, tap point calculation, grid overlay) are available in [`TimingConstants.swift`](../Sources/HelperLib/TimingConstants.swift) and [`EnvConfigFeatures.swift`](../Sources/HelperLib/EnvConfigFeatures.swift).
