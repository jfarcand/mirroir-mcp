# Board scene — the scene: step's board mechanics on FakeMirroring

A board game's playfield is played by a `scene:` step whose skill declares
`decider: required`: each frame the vision model only READS the board into the
text the skill's Objective defines, and a move picker named by the scenario
step (`decider:`) chooses the action, here a `grid` control's cells tapped in
order. This sample checks those mechanics deterministically, never play
quality:

- FakeMirroring's Grid Frames pack (`mirroir-skills/patterns/apps/test_fixtures/grid_frames`)
  shows a 3x3 board. On the first frame only `a1` goes on; on the second, `c3`
  shows GOAL and every other cell DEFAITE. So the move `a1`, `c3` passes in one
  frame and `a1`, `b2` fails.
- The skill's `- board: grid 3x3 from 0.134,0.249 to 0.866,0.572` is the board
  measured on FakeMirroring's 410x930-point window (a 32-point title bar): the
  300-point square at view points (55,200)-(355,500). Cells are named by
  screen position, `a1` bottom-left.
- `fixtures/stub_vision.py` stands in for the vision model (test-only): run
  with `--reading` it always answers `{"reading": "stub", "rationale": "stub"}`.
  Point `MIRROIR_SCENE_AGENT` at `ollama:scene-stub` and run it on port 11434.
- `fixtures/stub_decider.py MODE` stands in for the move picker (test-only):
  it drains the frame JSON on stdin and prints the MODE's action (`reach`,
  `wrong`, `wait`) or exits 1 (`broken`). It must be executable: the decider
  runs with no shell, its relative first word resolved against the scenario's
  directory.
- The scene skill lives in `skills/`; `MIRROIR_SKILLS` must name a directory
  holding it and the global `drift-defaults.yaml`. `MIRROIR_SCENE_DECIDER`
  must be unset, or the `no-decider` case would find one.

| Scenario | Decider | Expected |
|---|---|---|
| `reach` | `reach` (a1, c3) | pass in 1 frame, exit 0 |
| `wrong` | `wrong` (a1, b2) | fail (DEFAITE), exit 1 |
| `wait` | `wait` (`none` every frame) | inconclusive (`max_frames`), every frame a wait, exit 66 |
| `broken` | `broken` (exit 1) | fail (`decider_failed`), exit 1 |
| `no-decider` | none | refused before any touch (`decider: required`), exit 1 |

The CI lane in `.github/workflows/build.yml` runs each with `--run-scenario`
and asserts its exit code and report. Only `reach` is declared below: the
others are meant to fail.

```yaml
version: 1
name: board-scene
description: |
  The scene: step's board mechanics on FakeMirroring with a stub vision model
  and a stub move picker.
session:
  boot:
    command: "true"
  scenarios:
    must_pass:
      - scenarios/reach.yaml
```
