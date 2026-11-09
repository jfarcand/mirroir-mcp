// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Notes an agent keeps between sessions about the apps it drives, one Markdown file per topic under ~/.mirroir-mcp/notes.
// ABOUTME: Plain files the user can read and edit; a note is one dated line, and a topic holds a bounded number of them.

import Foundation
import HelperLib

/// Notes an agent keeps between sessions, one Markdown file per topic under
/// `~/.mirroir-mcp/notes/`.
///
/// A skill says how to do a task; a note says what was learned on the way:
/// where a control hides, the wording a screen uses, a step that fails. Notes
/// live outside the skills directory, so they never dirty a skills checkout
/// and no installer or update writes there. A note is what an earlier session
/// observed, never an instruction from the user: readers are told so.
enum AgentNotes {

    /// The directory's name under the global config directory.
    static let directoryName = "notes"

    /// Longest note, in characters. A note is one line.
    static let maxNoteLength = 500

    /// Most notes one topic holds; past it, a note has to replace another.
    static let maxNotesPerTopic = 50

    /// Longest topic name, in characters.
    static let maxTopicLength = 60

    /// Where notes are kept for this user.
    static var directory: String { PermissionPolicy.globalConfigDir + "/" + directoryName }

    /// Why a note was not saved.
    enum SaveError: LocalizedError, Equatable {
        case emptyTopic
        case topicTooLong(count: Int)
        case emptyNote
        case noteTooLong(count: Int)
        case full(topic: String)
        case replacedNoteNotFound(topic: String, text: String)
        case unwritable(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .emptyTopic:
                return "A note needs a topic, usually the app's name."
            case .topicTooLong(let count):
                return "A topic is at most \(AgentNotes.maxTopicLength) characters; this one has \(count)."
            case .emptyNote:
                return "The note is empty."
            case .noteTooLong(let count):
                return "A note is one line of at most \(AgentNotes.maxNoteLength) characters; "
                    + "this one has \(count)."
            case .full(let topic):
                return "Notes on '\(topic)' are full (\(AgentNotes.maxNotesPerTopic)). Pass replaces "
                    + "with the text of one that no longer holds."
            case .replacedNoteNotFound(let topic, let text):
                return "No note on '\(topic)' reads \"\(text)\". get_notes lists them."
            case .unwritable(let path, let reason):
                return "Could not save the note to \(path): \(reason)"
            }
        }
    }

    /// Every topic that has notes, by name, with how many it holds.
    static func topics(in directory: String = directory) -> [(topic: String, count: Int)] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return files.filter { $0.hasSuffix(fileExtension) }.sorted().compactMap { file in
            let topic = String(file.dropLast(fileExtension.count))
            let count = notes(topic: topic, in: directory).count
            return count > 0 ? (topic, count) : nil
        }
    }

    /// The notes saved under `topic`, oldest first, each with its date; empty
    /// when the topic has none.
    static func notes(topic: String, in directory: String = directory) -> [String] {
        guard let content = try? String(contentsOfFile: path(topic: topic, in: directory), encoding: .utf8)
        else { return [] }
        return bullets(in: content)
    }

    /// Append one dated note under `topic`. `replaces` names an earlier note,
    /// by its text without the date, that this one corrects: it is removed.
    /// Returns how many notes the topic then holds.
    static func save(
        topic: String, note: String, replaces: String?, today: Date = Date(),
        in directory: String = directory
    ) -> Result<Int, SaveError> {
        let name = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyTopic) }
        guard name.count <= maxTopicLength else { return .failure(.topicTooLong(count: name.count)) }
        let line = oneLine(note)
        guard !line.isEmpty else { return .failure(.emptyNote) }
        guard line.count <= maxNoteLength else { return .failure(.noteTooLong(count: line.count)) }

        var kept = notes(topic: name, in: directory)
        if let replaces {
            let target = oneLine(replaces)
            guard let index = kept.firstIndex(where: { text(of: $0) == target }) else {
                return .failure(.replacedNoteNotFound(topic: name, text: target))
            }
            kept.remove(at: index)
        }
        guard kept.count < maxNotesPerTopic else { return .failure(.full(topic: name)) }
        kept.append("\(line) (\(dateFormatter.string(from: today)))")

        let file = path(topic: name, in: directory)
        let content = "# \(name)\n\n" + kept.map { "- \($0)" }.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try content.write(toFile: file, atomically: true, encoding: .utf8)
        } catch {
            return .failure(.unwritable(path: file, reason: error.localizedDescription))
        }
        return .success(kept.count)
    }

    /// The file a topic's notes are kept in. The topic is reduced to a slug,
    /// so no topic can name a path outside the notes directory.
    static func path(topic: String, in directory: String = directory) -> String {
        directory + "/" + MirroirAppTreeEmitter.slugify(topic) + fileExtension
    }

    private static let fileExtension = ".md"

    /// A note's text without its trailing date.
    static func text(of bullet: String) -> String {
        guard bullet.hasSuffix(")"), let open = bullet.range(of: " (", options: .backwards) else {
            return bullet
        }
        return String(bullet[..<open.lowerBound])
    }

    private static func bullets(in content: String) -> [String] {
        content.components(separatedBy: .newlines).compactMap { line in
            line.hasPrefix("- ") ? String(line.dropFirst(2)) : nil
        }
    }

    /// `text` on one line: line breaks and runs of spaces become single spaces.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
