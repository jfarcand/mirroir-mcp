// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Turns a saved `record` session into the linear screen walk the .mirroir/ emitter renders.
// ABOUTME: Pure transformation — each recorded step becomes the action that reached the next screen.

import Foundation
import HelperLib

/// Maps a `Recording` onto the `[ExploredScreen]` walk `MirroirAppTreeEmitter`
/// renders, so `record` and `generate_skill` share one scenario formatter and
/// one set of refusals.
enum RecordingWalk {

    /// The walk a recording describes: the screen each step acted on, in
    /// order, then the final screen. Screen `i + 1` carries the action of
    /// step `i`; the first screen carries none. A tap or long press recorded
    /// with no label carries no `arrivedVia`, which the formatter refuses.
    static func screens(from recording: Recording) -> [ExploredScreen] {
        let snapshots = recording.steps.map(\.screenBefore) + [recording.finalScreen]
        return snapshots.enumerated().map { index, elements in
            let action = index == 0 ? nil : action(for: recording.steps[index - 1].kind)
            return ExploredScreen(
                index: index, elements: elements, hints: [],
                actionType: action?.type, arrivedVia: action?.value,
                screenshotBase64: "")
        }
    }

    /// The emitter flow a recording renders as: named after the recorded
    /// flow, walking `screens(from:)`.
    static func flow(from recording: Recording) -> MirroirAppTreeEmitter.Flow {
        MirroirAppTreeEmitter.Flow(name: recording.flowName, screens: screens(from: recording))
    }

    /// The scenario action type and value one recorded interaction maps to.
    /// A long press keeps only its label (replay holds for the default
    /// duration); a key press writes its modifiers inline (`return+command`),
    /// the form `SkillParser` reads back.
    static func action(for kind: RecordedEventKind) -> (type: String, value: String?) {
        switch kind {
        case .tap(_, _, let label):
            return ("tap", label)
        case .longPress(_, _, let label, _):
            return ("long_press", label)
        case .swipe(let direction):
            return ("swipe", direction)
        case .type(let text):
            return ("type", text)
        case .pressKey(let keyName, let modifiers):
            return ("press_key", ([keyName] + modifiers).joined(separator: "+"))
        }
    }
}
