// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests the notes an agent keeps between sessions: the files, their limits, and the get_notes and save_note tools.
// ABOUTME: Runs against a real temporary directory; nothing is mocked.

import XCTest
import HelperLib
@testable import mirroir_mcp

final class AgentNotesTests: XCTestCase {

    private var directory: String!
    private let day = Date(timeIntervalSince1970: 1_794_182_400) // 2026-11-09 UTC noon

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentNotesTests-\(UUID().uuidString)").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func save(_ topic: String, _ note: String, replaces: String? = nil) -> Result<Int, AgentNotes.SaveError> {
        AgentNotes.save(topic: topic, note: note, replaces: replaces, today: day, in: directory)
    }

    func testTheFirstSaveCreatesTheTopicFileWithItsHeading() throws {
        XCTAssertEqual(save("Clock", "The alarm list is under the second tab."), .success(1))
        let content = try String(contentsOfFile: directory + "/clock.md", encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("# Clock\n\n- The alarm list is under the second tab. (2026-11-"), content)
    }

    func testSavesAppendInOrder() {
        _ = save("Clock", "first")
        XCTAssertEqual(save("Clock", "second"), .success(2))
        XCTAssertEqual(AgentNotes.notes(topic: "Clock", in: directory).map(AgentNotes.text(of:)),
                       ["first", "second"])
    }

    func testTopicNamesFoldToOneFile() {
        _ = save("Clock", "a")
        _ = save(" clock ", "b")
        _ = save("CLOCK", "c")
        XCTAssertEqual(AgentNotes.topics(in: directory).map(\.topic), ["clock"])
        XCTAssertEqual(AgentNotes.notes(topic: "clock", in: directory).count, 3)
    }

    func testATopicCannotEscapeTheNotesDirectory() throws {
        for topic in ["../../x", "a/b", "..", "/etc/passwd"] {
            XCTAssertEqual(save(topic, "n"), .success(1), topic)
            XCTAssertTrue(AgentNotes.path(topic: topic, in: directory).hasPrefix(directory + "/"), topic)
            XCTAssertFalse(AgentNotes.path(topic: topic, in: directory).dropFirst(directory.count + 1).contains("/"))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
        XCTAssertEqual(Set(files), ["x.md", "a-b.md", "app.md", "etc-passwd.md"])
    }

    func testANoteIsOneLine() {
        _ = save("Clock", "line one\nline   two\r\n three")
        XCTAssertEqual(AgentNotes.notes(topic: "Clock", in: directory).map(AgentNotes.text(of:)),
                       ["line one line two three"])
    }

    func testAnOverlongNoteIsRefusedAndNothingIsWritten() {
        let long = String(repeating: "x", count: AgentNotes.maxNoteLength + 1)
        XCTAssertEqual(save("Clock", long), .failure(.noteTooLong(count: AgentNotes.maxNoteLength + 1)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/clock.md"))
        XCTAssertEqual(save("Clock", String(repeating: "x", count: AgentNotes.maxNoteLength)), .success(1))
    }

    func testAnEmptyTopicOrNoteIsRefused() {
        XCTAssertEqual(save("  ", "n"), .failure(.emptyTopic))
        XCTAssertEqual(save("Clock", " \n "), .failure(.emptyNote))
        let long = String(repeating: "t", count: AgentNotes.maxTopicLength + 1)
        XCTAssertEqual(save(long, "n"), .failure(.topicTooLong(count: AgentNotes.maxTopicLength + 1)))
    }

    func testAFullTopicRefusesUntilANoteIsReplaced() {
        for index in 1 ... AgentNotes.maxNotesPerTopic {
            XCTAssertEqual(save("Clock", "note \(index)"), .success(index))
        }
        XCTAssertEqual(save("Clock", "one more"), .failure(.full(topic: "Clock")))
        XCTAssertEqual(save("Clock", "one more", replaces: "note 7"), .success(AgentNotes.maxNotesPerTopic))
        let texts = AgentNotes.notes(topic: "Clock", in: directory).map(AgentNotes.text(of:))
        XCTAssertFalse(texts.contains("note 7"))
        XCTAssertEqual(texts.last, "one more")
    }

    func testReplacingAnUnknownNoteIsRefusedAndWritesNothing() {
        _ = save("Clock", "kept")
        XCTAssertEqual(save("Clock", "new", replaces: "never said"),
                       .failure(.replacedNoteNotFound(topic: "Clock", text: "never said")))
        XCTAssertEqual(AgentNotes.notes(topic: "Clock", in: directory).map(AgentNotes.text(of:)), ["kept"])
    }

    func testTopicsListsEachTopicWithItsCount() {
        _ = save("Weather", "a")
        _ = save("Clock", "a")
        _ = save("Clock", "b")
        let topics = AgentNotes.topics(in: directory)
        XCTAssertEqual(topics.map(\.topic), ["clock", "weather"])
        XCTAssertEqual(topics.map(\.count), [2, 1])
        XCTAssertEqual(AgentNotes.notes(topic: "Maps", in: directory), [])
        XCTAssertTrue(AgentNotes.topics(in: directory + "/absent").isEmpty)
    }

    func testAnUnwritableDirectoryIsReportedWithItsPath() throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentNotesTests-file-\(UUID().uuidString)").path
        try "not a directory".write(toFile: blocker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: blocker) }
        guard case .failure(.unwritable(let path, _)) = AgentNotes.save(
            topic: "Clock", note: "n", replaces: nil, today: day, in: blocker) else {
            return XCTFail("a file where the directory should be must be reported")
        }
        XCTAssertEqual(path, blocker + "/clock.md")
    }

    func testNotesLiveUnderTheUsersConfigDirectory() {
        XCTAssertEqual(AgentNotes.directory, PermissionPolicy.globalConfigDir + "/notes")
    }

    // MARK: - Tools

    private func server() -> MCPServer {
        let server = MCPServer(policy: PermissionPolicy(skipPermissions: true, config: nil), transport: .stdio)
        let directory = self.directory!
        MirroirMCP.registerNotesTools(server: server, directory: { directory })
        return server
    }

    private func call(_ server: MCPServer, _ name: String, _ args: [String: JSONValue]) -> (text: String, isError: Bool) {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1), method: "tools/call",
            params: .object(["name": .string(name), "arguments": .object(args)]))
        guard case .object(let result)? = server.handleRequest(request)?.result,
              case .array(let content)? = result["content"],
              case .object(let first)? = content.first,
              case .string(let text)? = first["text"] else { return ("", true) }
        if case .bool(let isError)? = result["isError"] { return (text, isError) }
        return (text, false)
    }

    func testGetNotesWithNothingSavedSaysSo() {
        let reply = call(server(), "get_notes", [:])
        XCTAssertFalse(reply.isError)
        XCTAssertEqual(reply.text, "No notes yet. save_note keeps what you learn about an app for the next session.")
    }

    func testSaveThenReadBack() {
        let server = server()
        let saved = call(server, "save_note", ["topic": .string("Clock"), "note": .string("Alarms are the second tab.")])
        XCTAssertFalse(saved.isError, saved.text)
        XCTAssertEqual(saved.text, "Saved under 'Clock' (1 note). get_notes reads them back.")

        XCTAssertEqual(call(server, "get_notes", [:]).text, "- clock (1 note)")
        let read = call(server, "get_notes", ["topic": .string("Clock")])
        XCTAssertTrue(read.text.hasPrefix(
            "Notes on 'Clock', saved by an agent in earlier sessions. They say what was true then: "
            + "check the screen before relying on one.\n- Alarms are the second tab. ("), read.text)
    }

    func testAnUnknownTopicIsAnAnswerNotAnError() {
        let server = server()
        _ = call(server, "save_note", ["topic": .string("Clock"), "note": .string("n")])
        let reply = call(server, "get_notes", ["topic": .string("Maps")])
        XCTAssertFalse(reply.isError)
        XCTAssertEqual(reply.text, "No notes on 'Maps'. Topics with notes: clock.")
    }

    func testSaveNoteRequiresTopicAndNote() {
        let server = server()
        XCTAssertEqual(call(server, "save_note", ["note": .string("n")]).text,
                       "Missing required parameter: topic (string)")
        XCTAssertEqual(call(server, "save_note", ["topic": .string("Clock")]).text,
                       "Missing required parameter: note (string)")
        let long = call(server, "save_note", [
            "topic": .string("Clock"), "note": .string(String(repeating: "x", count: 501)),
        ])
        XCTAssertTrue(long.isError)
        XCTAssertEqual(long.text, "A note is one line of at most 500 characters; this one has 501.")
    }

    // MARK: - Permissions and the repeated-sequence advice

    func testReadingIsAlwaysAllowedAndWritingNeedsPermission() {
        let closed = PermissionPolicy(skipPermissions: false, config: nil)
        XCTAssertTrue(closed.isToolVisible("get_notes"))
        XCTAssertFalse(closed.isToolVisible("save_note"))
        XCTAssertEqual(PermissionPolicy.annotations(for: "get_notes")["readOnlyHint"], .bool(true))
        XCTAssertEqual(PermissionPolicy.annotations(for: "save_note")["destructiveHint"], .bool(false))
        XCTAssertEqual(RepeatedSequenceAdvisor.noteTool, "save_note")
        XCTAssertTrue(PermissionPolicy.mutatingTools.contains(RepeatedSequenceAdvisor.noteTool))
    }
}
