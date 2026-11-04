# How mirroir sees the screen

The observe, reason, act loop, and the OCR, icon detection and AI vision backends behind `describe_screen`.

## How it works

Every interaction follows the same loop: **observe, reason, act**. `describe_screen` gives the AI every text element with tap coordinates (eyes). The LLM decides what to do next (brain). `tap`, `type_text`, `swipe` execute the action (hands) — then it loops back to observe. No scripts, no coordinates, just intent.

Beyond the basics, the server exposes higher-level navigation and lifecycle tools: `press_back` navigates back by OCR-tapping the "<" chevron (with a canonical-position fallback), `press_home`/`press_app_switcher`/`spotlight` drive system gestures, `scroll_to` scrolls until a target text becomes visible, `reset_app` force-quits an app via the App Switcher, `set_network` toggles connectivity through Settings, and `measure` times how long an action takes to surface a target element. Multi-target setups use `list_targets`/`switch_target` to move between window automation endpoints. Skill authoring is served by `record_step` and `save_compiled` (compiled replay) and `calibrate_component` (test a component definition against the live screen). See the [Tools Reference](tools.md) for all 39 tools.

## Screen Intelligence

`describe_screen` is the AI's eyes. Three backends work together to give the agent a complete picture of what's on screen — text, icons, and semantic UI structure.

### Apple Vision OCR (default)

The default backend uses Apple's Vision framework to detect every text element on screen and return exact tap coordinates. This is fast, local, and requires no API keys or external services.

### Icon Detection (YOLO CoreML)

Text-only OCR misses non-text UI elements — buttons, toggles, tab bar icons, activity rings. Drop a YOLO CoreML model (`.mlmodelc`) in `~/.mirroir-mcp/models/` and the server auto-detects it at startup, merging icon detection results with OCR text. The AI gets tap targets for elements that text-only OCR cannot see.

| Mode | `ocrBackend` setting | Behavior |
|------|---------------------|----------|
| Auto-detect (default) | `"auto"` | Uses Vision + YOLO if a model is installed, Vision only otherwise |
| Vision only | `"vision"` | Apple Vision OCR text only |
| YOLO only | `"yolo"` | CoreML element detection only |
| Both | `"both"` | Always merge both backends (falls back to Vision if no model) |

### AI Vision Mode (embacle)

Instead of local OCR, `describe_screen` can send the screenshot to an AI vision model that identifies UI elements semantically — cards, tabs, buttons, icons, navigation structure — not just raw text. This produces richer context for the agent, especially on screens with complex layouts.

The [embacle](https://github.com/dravr-ai/dravr-embacle) runtime is embedded directly into the mirroir-mcp binary via Rust FFI. `describe_screen` calls the embedded runtime in-process — no separate server, no network round-trip, no additional setup. The FFI layer (`EmbacleFFI.swift` → `libembacle.a`) handles initialization, chat completion requests, and memory management across the Swift/Rust boundary.

embacle routes vision requests through already-authenticated CLI tools (GitHub Copilot, Claude Code) so there is no separate API key to manage. If you have a Copilot or Claude Code subscription, you already have access.

#### Install

```bash
brew tap dravr-ai/tap
brew trust --tap dravr-ai/tap # recent Homebrew refuses to load untrusted taps
brew install embacle          # CLI tools (embacle-server, embacle-mcp)
brew install embacle-ffi      # Rust FFI static library (libembacle.a)
```

Both are optional. Without `embacle-ffi` the build links against Apple Vision
and `describe_screen` uses local OCR.

Then rebuild mirroir-mcp from source (or reinstall via Homebrew) so the binary links against `libembacle.a`:

```bash
# From source
swift build -c release

# Or via Homebrew (rebuilds automatically)
brew reinstall mirroir-mcp
```

#### Zero-config activation

When the embacle FFI is linked into the binary, `screenDescriberMode` defaults to `"auto"` which automatically resolves to vision mode. No settings change required — install embacle-ffi, rebuild, and `describe_screen` starts using AI vision.

To force local OCR even when embacle is available, explicitly set `"ocr"`:

```json
// .mirroir-mcp/settings.json
{
  "screenDescriberMode": "ocr"
}
```

See [Configuration](configuration.md) for all available settings.
