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

## Spotlight Store Button

The whole label of the button an App Store result shows when the app is not
installed. Spotlight can make that result its top hit, with the field still
saying it opens it ("OpenTable — Ouvrir" over an "Obtenir" card, XR, iOS 26,
2026-11-15); Return then opens the App Store page.

- get
- obtenir

## Navigation

Text a turn-by-turn navigation screen shows, a fragment of it. While driving
mode is on, an input is refused when the phone shows one, since the phone is
then guiding the drive. `.*` stands for any text between two parts. Read on
Waze, iOS 27, 2026-11-16: "Re-center" and "14 min • 8.4 km".

- re-center
- min • .*km
- min • .*mi

## Spotlight Overlay

Other text that shows only while Spotlight covers the screen. The top-hit
headings above count too. The search field's placeholder is the only text
Spotlight adds when it opens as a bare field over the Home Screen (iOS 27,
2026-11-16).

- rechercher ou demander
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

## Settings App

The Settings app's name under its Home Screen icon, which `set_network`
opens; the first that launches is used.

- settings
- réglages

## Settings Airplane Row

The label of the Settings row holding the Airplane Mode switch, which
`set_network` reads and taps for `airplane_on` and `airplane_off`, a fragment
of it. The Settings Row and Switch sections list a label as it reads on a
phone in each language; the first one on screen is used.

- airplane
- mode avion

## Settings Wi-Fi Row

The label of the Settings row that opens the Wi-Fi page for `wifi_on` and
`wifi_off`.

- wi-fi

## Settings Wi-Fi Switch

The label of the row on the Wi-Fi page holding the Wi-Fi switch. The page
title often reads the same; the row whose switch is found is used.

- wi-fi

## Settings Cellular Row

The label of the Settings row that opens the cellular page for
`cellular_on` and `cellular_off`.

- cellular
- mobile service
- réseau cellulaire

## Settings Cellular Switch

The label of the row on the cellular page holding the cellular data switch.
With two SIMs, iOS shows a menu there instead (`Données cellulaires
Principale >`), which `set_network` refuses rather than guesses.

- cellular data
- mobile data
- données cellulaires

## Control Center Airplane Tile

The whole label of Airplane Mode's tile on Control Center's connectivity page
(iOS 27), which `set_network` reads and taps for `airplane_on` and
`airplane_off`. OCR may split a label over two lines; the lines are joined.

- airplane mode
- mode avion

## Control Center Wi-Fi Tile

The whole label of the Wi-Fi tile on Control Center's connectivity page.

- wi-fi

## Control Center Cellular Tile

The whole label of the cellular data tile on Control Center's connectivity
page. With two SIMs the line under it names the line in use (`Principale`).

- cellular data
- mobile data
- données cellulaires

## Control Center Off State

The whole line under a Control Center connectivity tile's label when it is
off. Any other line under the label (a network name, a SIM line, `on`) reads
as on. Control Center never turns the Wi-Fi radio off: its tap drops the
network until the next day and the line says so ("Non connecté", iPhone 16,
iOS 27, 2026-11-24), which is the off that `wifi_off` reaches.

- off
- non
- not connected
- non connecté
