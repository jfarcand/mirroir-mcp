# Games

How mirroir plays games: shell and scene, token costs, and the controls that reach a game through iPhone Mirroring.

## Vision: agents that test — and play

mirroir is growing archetype-aware coverage for **games**. A game splits into two surfaces. The **shell** — menu, shop, loadout, settings, win/lose screens — is ordinary text-labelled UI that today's skills already drive. The **scene** — the playfield — is a vision-driven loop an agent follows one touch at a time. The honest targets are **game QA smoke tests, tutorial walkthroughs, and scripted demos**, not real-time play: iPhone Mirroring exposes a single pointer, so twin-stick and twitch games stay out of reach (see [Games](#games)).

**Token reductions** make the scene loop affordable. Screenshots are ~90% of an agent's cost, so text-rich shell screens read through `describe_screen` with no image at all, and a region/scale capture knob trims the per-frame image cost where a screenshot is unavoidable. On the playfield, `describe_screen` in vision mode sends the frame to an LLM through embacle; measured on a live Brawl Stars match, one frame costs ~24k prompt tokens and 3–14 s, which GitHub Copilot bills as a single premium request on Claude Sonnet 5.5.

The scene loop ships as the [`scene:` step](skills-marketplace.md#scenes): a `kind: game` skill names its objective, its calibrated controls and its win/lose screens, and the vision model picks one control per frame until the game is won, lost, or the step's frame, token or time budget runs out. A run that exhausts its budget is inconclusive (exit 66), never a silent pass. A scene is never compiled: every frame is a fresh decision.

## Games

Games get three controls through iPhone Mirroring: `touch` holds a finger across calls for virtual joysticks and press-and-hold (`begin`, `move`, `end`); `hold_keys` holds keys such as `w` while dragging the right mouse button, for games that switch to keyboard and mouse controls like Roblox; `pinch` and `rotate` drive two-finger zoom and rotation in gesture-recognizer UIs. Mirroring exposes a single pointer touch to apps, so a touch-only game cannot receive two independent fingers — see [Games and Multi-Touch](tools.md#games-and-multi-touch) for what was measured.
