---
version: 1
name: Scene Frames Impossible
app: Scene Frames
kind: game
surface: scene
playable: single-control
controls: [move, fire]
budget: { max_frames: 10, max_tokens: 400000, max_seconds: 180 }
success: { visible: "NEVER" }
fail: { visible: "DEFAITE" }
tags: ["scene", "fixture", "ci", "loop-mechanics"]
---

A goal the Scene Frames fixture never shows, so the scene can only run out of budget. A fixture for the `scene:` step's loop mechanics in CI (FakeMirroring's
`patterns/apps/test_fixtures/scene_frames` pack and a stub vision model), not
a game: every touch advances one frame. A step's own `budget:` narrows the one
above per case.

## Objective

Reach the screen that says NEVER. Press MOVE to advance one frame; never press
FIRE on the first frame.

## Controls

- move: tap at 0.244,0.59
- fire: tap at 0.683,0.59
