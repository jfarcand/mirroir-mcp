# Game scene — the scene: step's loop mechanics on FakeMirroring

A game's playfield is played by a `scene:` step: each frame is read once by
OCR, which judges the scene skill's `success` and `fail` predicates, and a
vision model names one calibrated control per frame. This sample checks that
loop's mechanics deterministically, never play quality:

- FakeMirroring's Scene Frames pack (`mirroir-skills/patterns/apps/test_fixtures/scene_frames`)
  advances exactly one frame per touch: MOVE walks to GOAL on the fourth
  frame, FIRE on the first frame shows DEFAITE.
- `fixtures/stub_vision.py` stands in for the vision model (test-only): it
  always names MOVE at 24050 tokens a frame. Point `MIRROIR_SCENE_AGENT` at
  `ollama:scene-stub` and run it on port 11434.
- The scene skills live in `skills/`; `MIRROIR_SKILLS` must name a directory
  holding them and the global `drift-defaults.yaml`.

| Scenario | Expected |
|---|---|
| `reach` | pass on frame 3, exit 0 |
| `impossible` | inconclusive (`max_frames`), exit 66 |
| `max-tokens` | inconclusive (`max_tokens`) after 2 frames within 50000 tokens, exit 66 |
| `forbidden` | refused before any touch (a `pinch` control), exit 1 |
| `budget-typo` | refused by `--validate` (`max_touches` is no budget key) |

The CI lane in `.github/workflows/build.yml` runs each with `--run-scenario`
and asserts its exit code and report. Only `reach` is declared below: the
others are meant to fail.

```yaml
version: 1
name: game-scene
description: |
  The scene: step's loop mechanics on FakeMirroring with a stub vision model.
session:
  boot:
    command: "true"
  scenarios:
    must_pass:
      - scenarios/reach.yaml
```
