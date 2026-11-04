// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: The operating manual an agent reads before driving the iPhone: working method, tool choice, consent rules.
// ABOUTME: One source: its essentials are the MCP server instructions, and `mirroir-mcp skill` prints the whole manual as a SKILL.md.

import Foundation

/// How an agent should drive the phone through mirroir. The essentials go to
/// every MCP client in the `initialize` instructions; the full manual is
/// printed by `mirroir-mcp skill`, in SKILL.md form, so agent hosts that load
/// skills (Claude Code, Codex) can install it.
enum OperatingManual {

    /// The skill name the manual is installed under.
    static let skillName = "mirroir"

    /// One line saying when the skill applies, for the SKILL.md front matter.
    static let skillDescription =
        "Drive a real iPhone through macOS iPhone Mirroring with the mirroir MCP tools: "
        + "read the screen, tap, type, swipe, open apps, and replay skills. Use whenever "
        + "a task needs the user's phone."

    /// The working method in brief: what every client receives as server instructions.
    static let essentials = """
        mirroir drives the user's real iPhone through macOS iPhone Mirroring. Work in small, checked steps:
        1. Look first: describe_screen lists visible text with tap points. Pass omit_screenshot, \
        and query/text_only to read one value. Never estimate coordinates from a screenshot.
        2. Before each action, name the change you expect. Act once, then check that it happened.
        3. If the screen did not change, do not repeat the same action: read the screen again and \
        choose differently.
        4. Prefer tap(text:) when the target has text, launch_app to open apps, press_back to go \
        back (a "<" chevron tap; Cmd+[ does nothing on iOS), press_home for the Home Screen.
        5. Once a sequence has worked, run it again with run_steps: one call instead of one per step.
        6. Errors that name something the user must do (unlock, approve on the Mac, grant a \
        permission) mean stop: tell the user, and retry once only after they say it is done.
        Consent: ask before sending, posting, buying, deleting or changing a setting. Never type a \
        password, PIN or one-time code, and never open the iOS Settings app unless the user asks.
        Run `mirroir-mcp skill` for the full manual.
        """

    /// The whole manual, as a SKILL.md: front matter, then the guide.
    static var skillMarkdown: String {
        """
        ---
        name: \(skillName)
        description: "\(skillDescription)"
        ---

        # Driving an iPhone with mirroir

        mirroir drives the user's own iPhone through macOS iPhone Mirroring: you see the screen \
        as text with tap points, and you tap, type and swipe on the real device. The phone is \
        the user's, with their accounts and data on it, so every action is real.

        ## Working method

        \(essentials)

        The harness reports what it saw and did; you decide what it means. A tool that \
        succeeds only says the input was delivered: the screen after it says whether it worked.

        ## Reading the screen

        - `describe_screen` returns every text element with its tap point, in the same points \
        `tap` takes. Use `omit_screenshot: true` unless you need to see an image.
        - `query` lists only elements containing a text (for example `°` for temperatures), \
        and `text_only: true` drops coordinates when you only read.
        - The mirrored frame lags the phone. describe_screen waits for the screen to settle; \
        on a constantly animated screen pass `settle_ms: 0`.
        - Text that is not on screen yet: `scroll_to` with its label scrolls until it shows.
        - `screenshot` is for what text cannot tell: images, colors, layout.

        ## Acting

        - `tap(text:)` finds text that describe_screen listed and taps it; a miss lists the text \
        that is on screen. `tap(x:, y:)` takes a point from describe_screen.
        - `launch_app(name:)` opens an app through Spotlight. `open_url` opens a link in Safari.
        - `press_back` taps the back chevron; `press_home` goes to the Home Screen; \
        `press_app_switcher` shows open apps; `reset_app` force-quits one.
        - Scrolling: content follows the finger. `swipe` from bottom to top shows what is \
        below. Fast swipes fling; a long `duration_ms` scrolls precisely.
        - `long_press` opens context menus; `double_tap` zooms or selects; `drag` moves \
        icons and sliders.
        - `run_steps` runs a list of steps you have already seen work, such as \
        `["tap: @324,113", "type: calculator", "press_key: return"]`. A control \
        with no readable text is named by its point: `"tap: @324,113"`. Text must be what the \
        screen shows, in the iPhone's language. Every \
        step is checked against the permissions before any runs, and the run stops at the \
        first failure. The reply ends with the text on screen.

        ## Typing

        - Tap the field first so the iPhone keyboard is up, then `type_text`.
        - The iPhone may autocorrect what you type, and it capitalizes the start of a \
        sentence. When the screen does not show the text that was sent, type_text says \
        so. Accept a capital iOS added unless the user asked for exact case.
        - Characters with no key on the Mac keyboard (emoji, CJK) are pasted through \
        Universal Clipboard, which needs Handoff on the Mac and the iPhone.
        - `press_key` sends return, escape, tab, delete and arrows. Only shortcuts iOS itself \
        implements work: Cmd+A, Cmd+C and Cmd+V in text fields, Cmd+L in Safari.

        ## The user's Mac

        Taps and typing go to the iPhone Mirroring window without bringing it to the front, \
        so the user can keep working. Swipes, drags and other gestures bring it to the front \
        for their duration. If another window covers the mirror, a gesture is refused rather \
        than sent to the wrong app.

        ## When the session is blocked

        iPhone Mirroring stops when the iPhone is unlocked and in use, when the Mac locks, or \
        when the connection times out. The error quotes the window's own text and names what \
        the user must do (usually: lock the iPhone, or approve on the Mac). Relay it, wait for \
        the user, then retry once. Never loop, and never press a sheet that asks for a \
        password or Touch ID: that approval belongs to the user.

        ## Consent

        - Ask the user before anything that sends, posts, buys, books, deletes or changes a \
        setting, even when the task seems to imply it. Show what you are about to do.
        - Never type a password, PIN or one-time code. Ask the user to enter it.
        - Never open the iOS Settings app unless the user asked for a setting.
        - Tools the user has not allowed are not listed. Do not try to work around a \
        permission refusal; tell the user which tool it needs.

        ## Skills

        - `list_skills` and `get_skill` read saved skills: Markdown step lists for a task.
        - While you follow a skill, `record_step` after each step and `save_compiled` at \
        the end record a compiled replay; `mirroir test` then runs it without a model.
        - `status` and `check_health` diagnose the connection when tools start failing.
        """
    }
}
