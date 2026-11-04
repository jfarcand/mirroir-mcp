# YOLO Icon Detection

Text-only OCR misses non-text UI elements — buttons, toggles, tab bar icons, activity rings. mirroir-mcp integrates YOLO CoreML models to detect these elements and merge them with Vision OCR results.

## Recommended Model: OmniParser v2.0

We recommend [Microsoft OmniParser v2.0](https://huggingface.co/microsoft/OmniParser-v2.0), a YOLOv8 model trained on UI screenshots to detect interactive elements. It outputs a single `icon` class with bounding boxes for clickable regions.

### Install via Hugging Face

```bash
pip install huggingface_hub
huggingface-cli download microsoft/OmniParser-v2.0 \
  --include "icon_detect/*" \
  --local-dir ~/.mirroir-mcp/models/icon_detect_download
```

### Convert to CoreML

Use [coremltools](https://github.com/apple/coremltools) to convert the PyTorch weights, or [Ultralytics](https://docs.ultralytics.com/modes/export/) which has built-in CoreML export:

```bash
pip install ultralytics coremltools
```

```python
from ultralytics import YOLO

model = YOLO("~/.mirroir-mcp/models/icon_detect_download/icon_detect/model.pt")
model.export(format="coreml", imgsz=640)
```

This produces a `.mlpackage`. Compile it to `.mlmodelc`:

```bash
xcrun coremlcompiler compile model.mlpackage ~/.mirroir-mcp/models/icon_detect.mlmodelc
```

### Verify

Restart mirroir-mcp and check the debug log:

```bash
grep -iE "YOLO|startup" ~/.mirroir-mcp/debug.log
# On a successful auto-detect: OCR: auto-detected YOLO model, using Vision + YOLO
# When no model is found:      OCR: no YOLO model found, using Vision OCR only ...
# When the model loads:        YOLO: Model loaded: <model>.mlmodelc
```

`mirroir doctor` checks macOS version, iPhone Mirroring availability/connection, screen-capture and accessibility permissions, and configured targets — it does **not** report YOLO model status. Use the debug log above to confirm a model is loaded.

## Configuration

```json
// .mirroir-mcp/settings.json
{
  "ocrBackend": "auto",
  "yoloConfidenceThreshold": 0.3
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `ocrBackend` | `"auto"` | `"auto"` merges Vision + YOLO when a model is present, Vision only otherwise. `"vision"` for Apple Vision OCR only, `"yolo"` for YOLO only (falls back to Vision if no model), `"both"` to always merge both |
| `yoloModelURL` | `""` | URL to download a `.mlmodel` or `.mlmodelc` on first use (auto-compiles `.mlmodel`) |
| `yoloModelPath` | `""` | Local path to a pre-compiled `.mlmodelc` directory (overrides auto-detect and download) |
| `yoloConfidenceThreshold` | `0.3` | Minimum confidence for detections (0.0–1.0). Lower catches more elements but increases false positives |

Each setting also has a `MIRROIR_`-prefixed environment-variable form (e.g. `MIRROIR_OCR_BACKEND`, `MIRROIR_YOLO_MODEL_PATH`, `MIRROIR_YOLO_MODEL_URL`).

### Model Resolution Order

When YOLO is enabled (`"auto"`, `"yolo"`, or `"both"`), `ModelDownloadManager.resolveModelURL()` resolves a compiled `.mlmodelc` in this order:

1. `yoloModelPath` — an explicit local path, if set and it exists.
2. A cached `.mlmodelc` in `~/.mirroir-mcp/models/` — e.g. one produced by the [Convert to CoreML](#convert-to-coreml) steps above.
3. `yoloModelURL` — downloaded, compiled if needed, and cached for subsequent runs.

If none resolve, the recognizer falls back to Apple Vision OCR only.

## How It Works

The `CoreMLElementDetector` runs `VNCoreMLRequest` on each screenshot. Detected bounding boxes become `RawTextElement` values with the class label as the `text` field (e.g. `"icon"`). `CompositeTextRecognizer` runs each configured backend and concatenates their `RawTextElement` arrays into a single list — it does not deduplicate; both Vision and YOLO outputs flow through together.

Downstream, `TapPointCalculator.computeTapPoints` groups the merged `RawTextElement` list into rows and converts them into the final `TapPoint` elements. That tap-point list is what `describe_screen` returns — the AI sees both text and icons as tap targets.

## Model Compatibility

Any YOLO CoreML model that outputs bounding boxes with class labels works. The detector uses the standard `VNCoreMLRequest` pipeline, so the requirements are:

- CoreML format (`.mlmodelc` compiled directory)
- Object detection output type (bounding boxes + class labels + confidence scores)
- Input: image (any resolution — Vision handles resizing)

Single-class models (like OmniParser's `icon`) work well for UI detection. Multi-class models (e.g. detecting "button", "toggle", "text_field" separately) also work — each class label becomes the element's text.

## Alternative: AI Vision Mode

For most use cases, [AI vision mode](screen-intelligence.md#ai-vision-mode-embacle) produces richer results than YOLO without any model management. It identifies elements semantically (cards, tabs, buttons, navigation structure) rather than just bounding boxes.

YOLO is best when:
- You need fully local detection with no API calls
- You want to detect specific UI element types (toggles, switches, activity rings)
- You're running in CI where API latency matters
