# Game shell — Brawl Stars' menus as ordinary iOS scenarios

A game's shell (main menu, shop, brawler collection) is ordinary text UI, so
it runs on the same rails as any app: these two scenarios were emitted by
`generate_skill` (start, capture, finish with `emit: true`) from a session on
a real iPhone, and replay unchanged on both the device and FakeMirroring. Each
opens with a reset and launch of Brawl Stars, taps a main-menu label, and
waits for the screen it reached. The waits follow mirroir-skills'
`patterns/apps/brawl-stars/APP.md`: its `## Landmarks` (RESSOURCES) win over
the shop's seasonal paid offer.

In CI, FakeMirroring stands in for the phone with the synthetic, text-only
Brawl Stars pack from the same APP.md (`## Simulator …`). On a device, a
returning player is assumed: a fresh account opens on the onboarding match
instead of the menu. No scenario taps JOUER or anything in the APP.md's Skip
list, so no match or purchase is ever started.

The first run records each scenario's screen baseline next to it
(`<scenario>.ios.compiled.json`, git-ignored). It belongs to the host that ran:
the device and FakeMirroring show different screens, so delete it before
running the sample on the other one.

```yaml
version: 1
name: game-shell
description: |
  Brawl Stars' main menu, shop and brawler collection, emitted from a device session.
session:
  boot:
    command: "true"
  scenarios:
    must_pass:
      - scenarios/open-the-brawlers.ios.yaml
      - scenarios/open-the-shop.ios.yaml
```
