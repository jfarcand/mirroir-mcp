---
version: 1
name: system-phrases
platform: ios
---

# System Phrases

Words iOS itself draws on its system screens, which mirroir reads to tell that
the phone left the app it was driving, that Spotlight is still in front, or
that a system alert covers the app. The iPhone's language is not known to the
Mac, so each section is a union across languages: add a phrase the way it
reads on a phone in that language, lower-cased, one per bullet. Unless a
section says the whole label, a fragment is enough, as long as no ordinary app
screen would contain it. A straight apostrophe matches the curly one iOS draws.

This file is data, not a component: it has no match rules.

## Lock Screen

Text of the lock screen and the passcode prompt.

- slide to unlock
- enter passcode
- face id
- swipe up to open
- press home to open
- emergency

## Spotlight Top Hit

The heading above Spotlight's top result. A query with nothing installed
behind it shows none.

- top hit
- meilleur résultat

## Spotlight Open

The word the search field adds after the query when Return would open an app
("Notes — Open"). The whole word, not a fragment.

- open
- ouvrir
- abrir
- öffnen

## Spotlight Overlay

Other text that shows only while Spotlight covers the screen. The top-hit
headings above count too.

- search in app
- rechercher dans l'app
- rechercher dans les apps
- siri suggestions
- suggestions de siri
- siri-vorschläge
- sugerencias de siri

## Home Search Pill

The label of the Home Screen's search pill, read after its magnifier glyph.
The whole label, not a fragment.

- search
- rechercher
- buscar
- suchen

## Alert Dismiss

Button labels of iOS system alerts, the whole label, most conservative first:
the explorer taps the first one it finds on a dialog.

- don't allow
- ask app not to track
- not now
- cancel
- dismiss
- no thanks
- later
- close
- ok
- allow

## Alert Title

Fragments of a system alert's title or message. `.*` stands for any text
between two parts.

- would like to
- wants to access
- would like to send
- would like to use
- allow tracking
- rate
- enjoying
- allow.*to track
