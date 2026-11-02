# Game result — the Brawl Stars result screen on FakeMirroring

The end-of-match result screen of a game shell, as ordinary iOS scenarios.
A match produces that screen on a device, so CI opens it from two
FakeMirroring fixtures instead: "Brawl Stars Victoire" and "Brawl Stars
Defaite" (`mirroir-skills/patterns/apps/test_fixtures/brawl_stars_*`) launch
straight onto a synthetic, text-only result screen. Each scenario waits for
the universal QUITTER button, asserts the outcome label, taps QUITTER and
waits for the main menu's JOUER — the steps of mirroir-skills'
`skills/apps/brawl-stars/result-assert.md`, which runs on the device after a
match a person plays.

Those fixtures exist only on FakeMirroring: this sample runs on a macOS host
with FakeMirroring running (`.github/actions/setup-fake-mirroring`) and
`mirroir-mcp` found through `MIRROIR_MCP_BIN`. The device-side shell flows
live in `game-shell`. A run records each scenario's screen baseline next to it
(`<scenario>.ios.compiled.json`, git-ignored).

```yaml
version: 1
name: game-result
description: |
  The Brawl Stars result screen (VICTOIRE, DÉFAITE) on FakeMirroring fixtures.
session:
  boot:
    command: "true"
  scenarios:
    must_pass:
      - scenarios/result-victoire.ios.yaml
      - scenarios/result-defaite.ios.yaml
```
