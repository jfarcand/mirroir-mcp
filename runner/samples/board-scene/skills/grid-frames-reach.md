---
version: 1
name: Grid Frames Reach
app: Grid Frames
kind: game
surface: scene
playable: single-control
controls: [board]
decider: required
image_width: 800
budget: { max_frames: 6, max_tokens: 400000, max_seconds: 180 }
success: { visible: "GOAL" }
fail: { visible: "DEFAITE" }
tags: ["scene", "board", "fixture", "ci", "loop-mechanics"]
---

Reach GOAL on the Grid Frames fixture: a move of cells a1 then c3. A fixture
for the `scene:` step's board mechanics in CI (FakeMirroring's
`patterns/apps/test_fixtures/grid_frames` pack, a stub vision model and a stub
move picker), not a game. The model only reads the board; the move picker the
scenario step names chooses every move. A step's own `budget:` narrows the one
above per case.

## Objective

Read the board: list the cells, by name (a1 is bottom-left, c3 top-right), that
hold a piece, or "empty" when none does. Do not choose a move.

## Controls

- board: grid 3x3 from 0.134,0.249 to 0.866,0.572
